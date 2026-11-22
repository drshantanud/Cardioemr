"""One request = one database transaction, opened as the acting role at the
acting centre.  This is the only code that talks to the pool.

Order of checks, all before any patient data is read:
  1. bearer token is valid (401)
  2. acting role is one this endpoint allows (403 FORBIDDEN)
  3. SET LOCAL ROLE r_<role>; token subject maps to an active user (401)
  4. the user holds that role at that centre (403 ROLE_NOT_HELD)
Row-level security then limits every query to the acting centre."""
from __future__ import annotations

import hashlib
import ipaddress
import json
import uuid
from dataclasses import dataclass, field
from typing import Any, Iterator

from fastapi import Depends, Header, Request
from psycopg import Connection, sql
from psycopg.rows import dict_row

from .auth import bearer_subject
from .errors import Problem

APP_ROLES = ("assistant", "nurse", "clinician", "research_coordinator", "principal_investigator",
             "centre_admin", "platform_admin", "audit_reader")


@dataclass
class Ctx:
    conn: Connection
    user_id: uuid.UUID
    centre_id: uuid.UUID
    role: str
    change_reason: str | None
    request: Request
    extras: dict[str, Any] = field(default_factory=dict)

    def one(self, query, params=None) -> dict | None:
        with self.conn.cursor(row_factory=dict_row) as cur:
            cur.execute(query, params)
            return cur.fetchone()

    def all(self, query, params=None) -> list[dict]:
        with self.conn.cursor(row_factory=dict_row) as cur:
            cur.execute(query, params)
            return cur.fetchall()

    def log_access(self, access_type: str, patient_id, entity_name: str, entity_id) -> None:
        self.conn.execute(
            "INSERT INTO audit.access_log (access_type, patient_id, entity_name, entity_id, client_ip, user_agent) "
            "VALUES (%s, %s, %s, %s, %s, %s)",
            (access_type, patient_id, entity_name, str(entity_id), _client_ip(self.request),
             self.request.headers.get("user-agent")))


def _client_ip(request: Request) -> str | None:
    host = request.client.host if request.client else None
    try:
        return str(ipaddress.ip_address(host)) if host else None
    except ValueError:
        return None


def roles(*allowed: str):
    """Dependency factory: a transaction-scoped Ctx for one of the allowed acting roles."""
    for r in allowed:
        assert r in APP_ROLES, r

    def dependency(request: Request,
                   x_centre_id: uuid.UUID = Header(...),
                   x_acting_role: str = Header(...),
                   x_change_reason: str | None = Header(None, min_length=3, max_length=500),
                   subject: str = Depends(bearer_subject)) -> Iterator[Ctx]:
        if x_acting_role not in APP_ROLES:
            raise Problem(400, "VALIDATION_FAILED", "Unknown acting role", detail=x_acting_role)
        if x_acting_role not in allowed:
            raise Problem(403, "FORBIDDEN", "This role may not perform this action",
                          detail=f"{x_acting_role} is not one of {', '.join(allowed)}")
        pool = request.app.state.pool
        with pool.connection() as conn:
            with conn.transaction():
                conn.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier("r_" + x_acting_role)))
                row = conn.execute("SELECT app.resolve_subject(%s, %s)",
                                   (request.app.state.settings.auth_provider, subject)).fetchone()
                if row is None or row[0] is None:
                    raise Problem(401, "UNAUTHENTICATED", "No active CardioEMR user for this token")
                user_id = row[0]
                conn.execute("SELECT set_config('app.user_id', %s, true), set_config('app.centre_id', %s, true),"
                             " set_config('app.change_reason', %s, true)",
                             (str(user_id), str(x_centre_id), x_change_reason or ""))
                held = conn.execute("SELECT app.user_has_role_at(%s, %s)", (x_centre_id, x_acting_role)).fetchone()[0]
                if not held:
                    raise Problem(403, "ROLE_NOT_HELD", "You do not hold this role at this centre")
                yield Ctx(conn, user_id, x_centre_id, x_acting_role, x_change_reason, request)

    return dependency


# --- helpers shared by routers ----------------------------------------------

def parse_if_match(value: str) -> int:
    v = value.strip().removeprefix("W/").strip('"')
    if not v.isdigit():
        raise Problem(400, "VALIDATION_FAILED", "If-Match must be the resource ETag", detail=value)
    return int(v)


def etag(row_version: int) -> str:
    return f'"{row_version}"'


def require_change_reason(ctx: Ctx) -> None:
    if not ctx.change_reason:
        raise Problem(428, "CHANGE_REASON_REQUIRED", "X-Change-Reason is required to change saved data")


class Idempotency:
    """Replays the stored response for a repeated POST with the same key and body."""

    def __init__(self, ctx: Ctx, key: str, body: Any):
        if not 16 <= len(key) <= 64:
            raise Problem(400, "VALIDATION_FAILED", "Idempotency-Key must be 16 to 64 characters")
        self.ctx, self.key = ctx, key
        self.path = ctx.request.url.path
        self.digest = hashlib.sha256(json.dumps(body, sort_keys=True, default=str).encode()).digest()

    def previous(self) -> tuple[int, Any] | None:
        row = self.ctx.one("SELECT method, path, request_sha256, response_status, response_body "
                           "FROM api.idempotency_keys WHERE user_id = %s AND idempotency_key = %s",
                           (self.ctx.user_id, self.key))
        if row is None:
            return None
        if row["path"] != self.path or bytes(row["request_sha256"]) != self.digest:
            raise Problem(422, "IDEMPOTENCY_MISMATCH", "Idempotency-Key was used with a different request")
        return row["response_status"], row["response_body"]

    def store(self, status: int, body: Any) -> None:
        self.ctx.conn.execute(
            "INSERT INTO api.idempotency_keys (idempotency_key, method, path, request_sha256, response_status, "
            "response_body) VALUES (%s, 'POST', %s, %s, %s, %s)",
            (self.key, self.path, self.digest, status, json.dumps(body, default=str)))
