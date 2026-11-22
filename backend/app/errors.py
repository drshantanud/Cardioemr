"""RFC 9457 problem responses, and translation of database errors.

Database rules raise a stable tag in HINT ('cemr:<CODE>') or violate a
constraint with a stable name (migration 0003).  ref.api_error_map lists
both; it is loaded once at start-up and is the only place codes are mapped."""
from __future__ import annotations

from typing import Any

import psycopg
from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

PROBLEM_TYPE = "https://cardioemr.example.org/problems/"


class Problem(Exception):
    def __init__(self, status: int, code: str, title: str, detail: str | None = None,
                 errors: list[dict[str, Any]] | None = None, current: Any = None, sqlstate: str | None = None):
        super().__init__(title)
        self.status, self.code, self.title, self.detail = status, code, title, detail
        self.errors, self.current, self.sqlstate = errors, current, sqlstate

    def body(self) -> dict[str, Any]:
        b: dict[str, Any] = {"type": PROBLEM_TYPE + self.code.lower().replace("_", "-"), "title": self.title,
                             "status": self.status, "code": self.code}
        if self.detail:
            b["detail"] = self.detail
        if self.errors:
            b["errors"] = self.errors
        if self.current is not None:
            b["current"] = self.current
        if self.sqlstate:
            b["sqlstate"] = self.sqlstate
        return b


def problem_response(p: Problem) -> JSONResponse:
    return JSONResponse(p.body(), status_code=p.status, media_type="application/problem+json")


class ErrorMap:
    """(kind, name) -> (code, http_status, title), from ref.api_error_map."""

    def __init__(self, rows: list[tuple[str, str, str, int, str]]):
        self._m = {(k, n): (c, s, t) for k, n, c, s, t in rows}

    def lookup(self, kind: str, name: str | None):
        return self._m.get((kind, name)) if name else None


def from_db_error(e: psycopg.Error, emap: ErrorMap) -> Problem:
    """Translate one database error into a Problem."""
    diag = e.diag
    state = e.sqlstate or ""
    hint, constraint, message = diag.message_hint, diag.constraint_name, diag.message_primary
    hit = emap.lookup("hint", hint) or emap.lookup("constraint", constraint)
    if hit:
        code, status, title = hit
        return Problem(status, code, title, detail=message, sqlstate=state)
    if state == "42501":
        return Problem(403, "FORBIDDEN", "Not permitted", detail=message, sqlstate=state)
    if state in ("40001", "40P01"):
        return Problem(503, "RETRY_LATER", "Please retry", sqlstate=state)
    if state.startswith("23"):
        status = 409 if state in ("23505", "23503") else 422
        return Problem(status, "CONFLICT" if status == 409 else "VALIDATION_FAILED",
                       "Request conflicts with stored data" if status == 409 else "Validation failed",
                       detail=message, sqlstate=state)
    if state.startswith("22"):
        return Problem(422, "VALIDATION_FAILED", "Invalid value", detail=message, sqlstate=state)
    return Problem(500, "INTERNAL", "Internal error", sqlstate=state)


def install_handlers(app) -> None:
    @app.exception_handler(Problem)
    async def _problem(_: Request, p: Problem):
        return problem_response(p)

    @app.exception_handler(psycopg.Error)
    async def _db(request: Request, e: psycopg.Error):
        return problem_response(from_db_error(e, request.app.state.error_map))

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, e: RequestValidationError):
        errors = [{"field": ".".join(str(x) for x in err.get("loc", ()) if x != "body"), "rule": err.get("type"),
                   "message": err.get("msg")} for err in e.errors()]
        return problem_response(Problem(400, "VALIDATION_FAILED", "Request is not valid", errors=errors))
