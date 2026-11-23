"""Research exports: request, four-eyes decision, generation, download.

Flow: a research coordinator or PI requests an export (status requested).
Another PI approves or rejects it.  An approved export is generated after the
decision commits, in its own transactions, running as the requester with the
requester's role, so the file can never contain more than the requester's own
study access allows (research views, migration 0006).  The finished file is
kept for CEMR_EXPORT_RETENTION_DAYS; only the requester can download it,
through a signed link valid for 15 minutes, and every download is logged."""
from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import os
import secrets
import time
import traceback
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, Depends, Header, Query, Request, Response
from fastapi.responses import JSONResponse
from psycopg import sql
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from pydantic import BaseModel, ConfigDict, Field, field_validator

from .. import export_writer
from ..context import Ctx, Idempotency, etag, roles
from ..errors import Problem
from .enrolment import _jsonable, _replay, _versioned_update

log = logging.getLogger("cardioemr.exports")
router = APIRouter(tags=["Exports"])
REQUESTERS = roles("research_coordinator", "principal_investigator")
DECIDERS = roles("principal_investigator")

JOB_FIELDS = ("export_id", "protocol_id", "purpose", "centre_ids", "cohort_filter", "visit_codes", "variable_codes",
              "deidentification", "file_format", "include_data_dictionary", "missing_value_codes", "requested_by",
              "requested_role", "requested_at", "status", "approved_by", "approved_at", "decision_note", "started_at",
              "completed_at", "failure_reason", "row_count", "file_sha256", "expires_at", "manifest", "row_version")
COHORT_KEYS = {"enrolment_status", "index_year_from", "index_year_to"}
ENROLMENT_STATUSES = {"enrolled", "completed", "withdrawn", "lost_to_follow_up", "deceased"}


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CohortFilter(Strict):
    enrolment_status: list[str] | None = None
    index_year_from: int | None = Field(None, ge=2000, le=2100)
    index_year_to: int | None = Field(None, ge=2000, le=2100)

    @field_validator("enrolment_status")
    @classmethod
    def _statuses(cls, v):
        if v is not None and (not v or set(v) - ENROLMENT_STATUSES):
            raise ValueError(f"enrolment_status values must be among {sorted(ENROLMENT_STATUSES)}")
        return v


class ExportRequest(Strict):
    protocol_id: uuid.UUID
    purpose: str = Field(min_length=10, max_length=2000)
    centre_ids: list[uuid.UUID] | None = Field(None, min_length=1)
    cohort_filter: CohortFilter = Field(default_factory=CohortFilter)
    visit_codes: list[str] | None = Field(None, min_length=1)
    variable_codes: list[str] = Field(min_length=1, max_length=500)
    deidentification: Literal["pseudonymised_relative_days", "pseudonymised_year_only", "aggregate_only"]
    file_format: Literal["csv", "xlsx", "spss_csv", "r_csv", "stata_csv"]
    include_data_dictionary: bool = True


def job_out(request: Request, ctx: Ctx, row: dict) -> dict:
    out = {k: row.get(k) for k in JOB_FIELDS}
    out["file_sha256"] = bytes(row["file_sha256"]).hex() if row.get("file_sha256") else None
    out["download_url"] = None
    if (row["status"] == "completed" and row["requested_by"] == ctx.user_id and row["expires_at"]
            and row["expires_at"] > datetime.now(timezone.utc)):
        out["download_url"] = _signed_url(request, row["export_id"], ctx.user_id)
    return _jsonable(out)


@router.post("/exports", status_code=201)
def request_export(body: ExportRequest, request: Request, idempotency_key: str = Header(...),
                   ctx: Ctx = Depends(REQUESTERS)):
    idem = Idempotency(ctx, idempotency_key, body.model_dump(mode="json"))
    if (prev := idem.previous()) is not None:
        return _replay(prev)
    if ctx.one("SELECT 1 FROM registry.registry_protocols WHERE protocol_id = %s", (body.protocol_id,)) is None:
        raise Problem(404, "NOT_FOUND", "Protocol not found")
    allowed = ctx.one("SELECT app.study_centres(%s) AS c", (body.protocol_id,))["c"]
    can_export = ctx.one("""SELECT 1 FROM registry.study_memberships WHERE user_id = %s AND protocol_id = %s
                             AND can_export AND status = 'active'""", (ctx.user_id, body.protocol_id))
    if not allowed or can_export is None:
        raise Problem(403, "FORBIDDEN", "You need an active study membership with export rights for this protocol")
    errors = []
    for c in body.centre_ids or []:
        if c not in allowed:
            errors.append({"field": "centre_ids", "rule": "study_access", "message": str(c)})
    known = {r["variable_code"] for r in ctx.all(
        "SELECT d.variable_code FROM registry.protocol_variables pv JOIN registry.variable_definitions d "
        "USING (variable_id) WHERE pv.protocol_id = %s", (body.protocol_id,))}
    errors += [{"variable_code": v, "rule": "UNKNOWN_VARIABLE", "message": "Not a variable of this protocol"}
               for v in body.variable_codes if v not in known]
    if len(set(body.variable_codes)) != len(body.variable_codes):
        errors.append({"field": "variable_codes", "rule": "unique", "message": "listed more than once"})
    if body.visit_codes:
        visits = {r["visit_code"] for r in ctx.all(
            "SELECT visit_code FROM registry.visit_schedule WHERE protocol_id = %s", (body.protocol_id,))} | {"UNSCHED"}
        errors += [{"field": "visit_codes", "rule": "in_schedule", "message": v}
                   for v in body.visit_codes if v not in visits]
    if errors:
        raise Problem(422, "VALIDATION_FAILED", "The export request is not valid", errors=errors)
    row = ctx.one("""
        INSERT INTO research.export_jobs (protocol_id, purpose, centre_ids, cohort_filter, visit_codes, variable_codes,
          deidentification, file_format, include_data_dictionary)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING *""",
        (body.protocol_id, body.purpose, body.centre_ids, Jsonb(body.cohort_filter.model_dump(exclude_none=True)),
         body.visit_codes, body.variable_codes, body.deidentification, body.file_format,
         body.include_data_dictionary))
    out = job_out(request, ctx, row)
    idem.store(201, out)
    return JSONResponse(out, status_code=201, headers={"ETag": etag(row["row_version"]),
                                                      "Location": f"/api/v1/exports/{row['export_id']}"})


@router.get("/exports")
def list_exports(request: Request, protocol_id: uuid.UUID | None = None,
                 status: Literal["requested", "approved", "rejected", "running", "completed", "failed",
                                 "expired"] | None = None,
                 limit: int = Query(50, ge=1, le=200), ctx: Ctx = Depends(REQUESTERS)):
    rows = ctx.all("""SELECT * FROM research.export_jobs
                       WHERE (%s::uuid IS NULL OR protocol_id = %s) AND (%s::text IS NULL OR status = %s)
                       ORDER BY requested_at DESC LIMIT %s""", (protocol_id, protocol_id, status, status, limit))
    return {"items": [job_out(request, ctx, r) for r in rows]}


@router.get("/exports/{export_id}")
def get_export(export_id: uuid.UUID, request: Request, response: Response, ctx: Ctx = Depends(REQUESTERS)):
    row = ctx.one("SELECT * FROM research.export_jobs WHERE export_id = %s", (export_id,))
    if row is None:
        raise Problem(404, "NOT_FOUND", "Export not found")
    if row["status"] == "completed" and row["expires_at"] <= datetime.now(timezone.utc):
        row = _expire(request, ctx, row)
    response.headers["ETag"] = etag(row["row_version"])
    return job_out(request, ctx, row)


class Decision(Strict):
    decision: Literal["approved", "rejected"]
    note: str | None = Field(None, max_length=2000)


@router.post("/exports/{export_id}/decision")
def decide_export(export_id: uuid.UUID, body: Decision, request: Request, response: Response,
                  if_match: str = Header(...), ctx: Ctx = Depends(DECIDERS)):
    cur = ctx.one("SELECT requested_by FROM research.export_jobs WHERE export_id = %s", (export_id,))
    if cur is None:
        raise Problem(404, "NOT_FOUND", "Export not found")
    if cur["requested_by"] == ctx.user_id:
        raise Problem(422, "FOUR_EYES", "An export must be approved by someone other than the requester")
    row = _versioned_update(ctx, "research.export_jobs", "export_id", export_id, if_match,
                            {"status": body.decision, "decision_note": body.note},
                            where_extra=sql.SQL("status = 'requested'"))
    if body.decision == "approved":
        app, by, role = request.app, row["requested_by"], row["requested_role"]
        ctx.after_commit.append(lambda: run_export(app, export_id, by, role))
    response.headers["ETag"] = etag(row["row_version"])
    return job_out(request, ctx, row)


@router.get("/exports/{export_id}/file")
def download_export(export_id: uuid.UUID, request: Request, expires: int, sig: str,
                    ctx: Ctx = Depends(REQUESTERS)):
    if not _signature_ok(request, export_id, ctx.user_id, expires, sig):
        raise Problem(403, "FORBIDDEN", "Download link is not valid or has expired; ask for the export again")
    row = ctx.one("SELECT * FROM research.export_jobs WHERE export_id = %s", (export_id,))
    if row is None:
        raise Problem(404, "NOT_FOUND", "Export not found")
    if row["requested_by"] != ctx.user_id:
        raise Problem(403, "FORBIDDEN", "Only the requester can download an export")
    if row["status"] != "completed" or row["expires_at"] <= datetime.now(timezone.utc):
        raise Problem(409, "CONFLICT", "Export is not available for download", detail=row["status"])
    path = _store(request.app) / row["file_storage_key"]
    data = path.read_bytes() if path.is_file() else None
    if data is None or hashlib.sha256(data).digest() != bytes(row["file_sha256"]):
        raise Problem(409, "CONFLICT", "Export file is missing or does not match its recorded hash")
    ctx.log_access("export_download", None, "research.export_jobs", export_id)
    media = ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" if row["file_format"] == "xlsx"
             else "application/zip")
    name = f"{row['manifest']['protocol_code']}-export-{str(export_id)[:8]}.{row['file_storage_key'].rsplit('.', 1)[1]}"
    return Response(data, media_type=media, headers={"Content-Disposition": f'attachment; filename="{name}"',
                                                     "X-Content-SHA256": bytes(row["file_sha256"]).hex()})


# --- generation -------------------------------------------------------------

def _store(app) -> Path:
    d = app.state.settings.export_dir
    if not d:
        raise export_writer.ExportError("CEMR_EXPORT_DIR is not set on the server")
    p = Path(d)
    p.mkdir(parents=True, exist_ok=True)
    return p


def _as_requester(conn, user_id, role: str) -> None:
    conn.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier("r_" + role)))
    conn.execute("SELECT set_config('app.user_id', %s, true), set_config('app.centre_id', '', true)", (str(user_id),))


def run_export(app, export_id: uuid.UUID, requested_by: uuid.UUID, requested_role: str) -> None:
    """Generate one approved export.  Safe to call again: only an approved or failed job is picked up."""
    pool = app.state.pool
    with pool.connection() as conn:
        with conn.transaction():
            _as_requester(conn, requested_by, requested_role)
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute("UPDATE research.export_jobs SET status = 'running' WHERE export_id = %s "
                            "AND status IN ('approved','failed') RETURNING *", (export_id,))
                job = cur.fetchone()
        if job is None:
            return
        try:
            with conn.transaction():
                _as_requester(conn, requested_by, requested_role)

                def all_rows(q, p=None):
                    with conn.cursor(row_factory=dict_row) as c:
                        c.execute(q, p)
                        return c.fetchall()

                def one_row(q, p=None):
                    rows = all_rows(q, p)
                    return rows[0] if rows else None

                data = export_writer.collect(all_rows, one_row, job)
            content, ext, row_count, manifest = export_writer.render(job, data)
            key = f"{export_id}.{ext}"
            target = _store(app) / key
            tmp = target.with_suffix(".part")
            tmp.write_bytes(content)
            os.replace(tmp, target)
            with conn.transaction():
                _as_requester(conn, requested_by, requested_role)
                conn.execute("""UPDATE research.export_jobs SET status = 'completed', row_count = %s,
                                  file_storage_key = %s, file_sha256 = %s, manifest = %s,
                                  expires_at = now() + make_interval(days => %s)
                                WHERE export_id = %s""",
                             (row_count, key, export_writer.sha256(content), Jsonb(manifest),
                              app.state.settings.export_retention_days, export_id))
        except Exception as ex:   # the job records why; the API process keeps running
            reason = str(ex) if isinstance(ex, export_writer.ExportError) else "Export generation failed"
            log.error("export %s failed: %s", export_id, traceback.format_exc())
            with conn.transaction():
                _as_requester(conn, requested_by, requested_role)
                conn.execute("UPDATE research.export_jobs SET status = 'failed', failure_reason = %s "
                             "WHERE export_id = %s AND status = 'running'", (reason, export_id))


def _expire(request: Request, ctx: Ctx, row: dict) -> dict:
    """Mark a completed export past its expiry as expired and remove its file."""
    try:
        with ctx.conn.transaction():
            updated = ctx.one("UPDATE research.export_jobs SET status = 'expired' WHERE export_id = %s "
                              "AND status = 'completed' RETURNING *", (row["export_id"],))
    except Exception:          # a viewer without export rights cannot write; show it as expired anyway
        return {**row, "status": "expired"}
    if updated and updated["file_storage_key"]:
        try:
            (_store(request.app) / updated["file_storage_key"]).unlink(missing_ok=True)
        except export_writer.ExportError:
            pass
    return updated or row


# --- signed links -----------------------------------------------------------

def _url_key(app) -> bytes:
    key = getattr(app.state, "export_url_key", None)
    if key is None:
        configured = app.state.settings.export_url_key
        key = configured.encode() if configured else secrets.token_bytes(32)
        app.state.export_url_key = key
    return key


def _sign(app, export_id, user_id, expires: int) -> str:
    msg = f"{export_id}|{user_id}|{expires}".encode()
    return base64.urlsafe_b64encode(hmac.new(_url_key(app), msg, "sha256").digest()).decode().rstrip("=")


def _signed_url(request: Request, export_id, user_id) -> str:
    expires = int(time.time()) + 60 * request.app.state.settings.export_link_minutes
    return (f"{request.url_for('download_export', export_id=str(export_id))}"
            f"?expires={expires}&sig={_sign(request.app, export_id, user_id, expires)}")


def _signature_ok(request: Request, export_id, user_id, expires: int, sig: str) -> bool:
    if expires < time.time():
        return False
    return hmac.compare_digest(_sign(request.app, export_id, user_id, expires), sig)
