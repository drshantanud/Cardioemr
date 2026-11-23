"""Who the signed-in user is, and where they may act.

Called right after sign-in, before a centre is chosen, so it takes only the
bearer token.  It returns the centres and roles the user holds today; every
other request then names one centre and one role in X-Centre-Id and
X-Acting-Role, and row-level security limits it to that centre."""
from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from psycopg.rows import dict_row

from ..auth import bearer_subject
from ..errors import Problem

router = APIRouter(tags=["Session"])


@router.get("/me")
def me(request: Request, subject: str = Depends(bearer_subject)):
    pool = request.app.state.pool
    provider = request.app.state.settings.auth_provider
    with pool.connection() as conn, conn.transaction():
        conn.execute("SET LOCAL ROLE r_assistant")       # least-privileged role; the function is a narrow definer
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute("SELECT * FROM app.subject_memberships(%s, %s)", (provider, subject))
            rows = cur.fetchall()
    if not rows:
        raise Problem(401, "UNAUTHENTICATED", "No active CardioEMR user for this token")
    first = rows[0]
    centres: dict[str, dict] = {}
    for r in rows:
        if r["centre_id"] is None:
            continue
        c = centres.setdefault(str(r["centre_id"]), {
            "centre_id": str(r["centre_id"]), "centre_name": r["centre_name"], "centre_code": r["centre_code"],
            "timezone": r["centre_timezone"], "organisation_id": str(r["organisation_id"]),
            "organisation_name": r["organisation_name"], "roles": []})
        c["roles"].append(r["role"])
    return {"user_id": str(first["user_id"]), "full_name": first["full_name"], "email": first["email"],
            "platform_role": first["platform_role"], "centres": list(centres.values())}
