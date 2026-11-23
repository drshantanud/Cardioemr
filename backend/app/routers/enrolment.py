"""Registry suggestions, screening, eligibility, enrolment and visit schedule."""
from __future__ import annotations

import uuid
from datetime import date, timedelta
from typing import Annotated, Any, Literal, Union

from fastapi import APIRouter, Depends, Header, Query, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from psycopg import sql

from ..context import Ctx, Idempotency, etag, parse_if_match, require_change_reason, roles
from ..errors import Problem

router = APIRouter(tags=["Enrolment"])
REGISTRY_STAFF = ("clinician", "research_coordinator", "principal_investigator")
SUGGESTION_READERS = roles(*REGISTRY_STAFF, "nurse")
STAFF = roles(*REGISTRY_STAFF)
ENROLLERS = roles("clinician", "principal_investigator")
SCHEDULE_READERS = roles(*REGISTRY_STAFF, "nurse")


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


# --- suggestions --------------------------------------------------------------

@router.get("/registry-suggestions", tags=["Suggestions"])
def list_suggestions(status: Literal["open", "screening_started", "dismissed", "not_eligible"] = "open",
                     registry_code: str | None = None, patient_id: uuid.UUID | None = None,
                     limit: int = Query(50, ge=1, le=200), cursor: str | None = None,
                     ctx: Ctx = Depends(SUGGESTION_READERS)):
    after = _decode_cursor(cursor)
    rows = ctx.all("""
        SELECT suggestion_id, patient_id, registry_code, trigger_diagnosis_id, suggested_at, status, dismiss_reason,
               row_version
          FROM registry.registry_suggestions
         WHERE status = %s AND (%s::text IS NULL OR registry_code = %s) AND (%s::uuid IS NULL OR patient_id = %s)
           AND (%s::timestamptz IS NULL OR (suggested_at, suggestion_id) > (%s, %s))
         ORDER BY suggested_at, suggestion_id LIMIT %s""",
        (status, registry_code, registry_code, patient_id, patient_id, after[0], after[0], after[1], limit + 1))
    return _page(rows, limit, lambda r: f"{r['suggested_at'].isoformat()}|{r['suggestion_id']}")


class SuggestionAction(Strict):
    status: Literal["dismissed", "not_eligible"]
    dismiss_reason: str = Field(min_length=3)


@router.patch("/registry-suggestions/{suggestion_id}", tags=["Suggestions"])
def action_suggestion(suggestion_id: uuid.UUID, body: SuggestionAction, response: Response,
                      if_match: str = Header(...), ctx: Ctx = Depends(STAFF)):
    row = _versioned_update(ctx, "registry.registry_suggestions", "suggestion_id", suggestion_id, if_match,
                            {"status": body.status, "dismiss_reason": body.dismiss_reason,
                             "actioned_by": ctx.user_id, "actioned_at": sql.SQL("now()")},
                            where_extra=sql.SQL("status = 'open'"))
    response.headers["ETag"] = etag(row["row_version"])
    return _suggestion_out(row)


# --- enrolment ----------------------------------------------------------------

class ScreeningRequest(Strict):
    patient_id: uuid.UUID
    protocol_id: uuid.UUID
    suggestion_id: uuid.UUID | None = None
    screening_date: date | None = None


@router.post("/enrolments", status_code=201)
def start_screening(body: ScreeningRequest, idempotency_key: str = Header(...), ctx: Ctx = Depends(STAFF)):
    idem = Idempotency(ctx, idempotency_key, body.model_dump(mode="json"))
    if (prev := idem.previous()) is not None:
        return _replay(prev)
    proto = ctx.one("SELECT registry_type_id FROM registry.registry_protocols WHERE protocol_id = %s",
                    (body.protocol_id,))
    if proto is None:
        raise Problem(404, "NOT_FOUND", "Protocol not found")
    row = ctx.one("""INSERT INTO registry.enrolments (patient_id, centre_id, registry_type_id, protocol_id, screening_date)
                     VALUES (%s, %s, %s, %s, coalesce(%s, current_date)) RETURNING enrolment_id""",
                  (body.patient_id, ctx.centre_id, proto["registry_type_id"], body.protocol_id, body.screening_date))
    if body.suggestion_id:
        updated = ctx.one("""UPDATE registry.registry_suggestions SET status = 'screening_started', actioned_by = %s,
                                    actioned_at = now()
                              WHERE suggestion_id = %s AND patient_id = %s AND status = 'open'
                              RETURNING suggestion_id""", (ctx.user_id, body.suggestion_id, body.patient_id))
        if updated is None:
            raise Problem(409, "CONFLICT", "Suggestion is not open for this patient")
    out = enrolment_out(ctx, row["enrolment_id"])
    idem.store(201, out)
    return JSONResponse(out, status_code=201, headers={"ETag": etag(out["row_version"]),
                                                      "Location": f"/api/v1/enrolments/{out['enrolment_id']}"})


@router.get("/enrolments")
def list_enrolments(protocol_id: uuid.UUID | None = None, patient_id: uuid.UUID | None = None,
                    enrolment_status: str | None = None, limit: int = Query(50, ge=1, le=200),
                    cursor: str | None = None, ctx: Ctx = Depends(STAFF)):
    after = _decode_cursor(cursor)
    rows = ctx.all("""
        SELECT enrolment_id, created_at FROM registry.enrolments
         WHERE (%s::uuid IS NULL OR protocol_id = %s) AND (%s::uuid IS NULL OR patient_id = %s)
           AND (%s::text IS NULL OR enrolment_status = %s)
           AND (%s::timestamptz IS NULL OR (created_at, enrolment_id) > (%s, %s))
         ORDER BY created_at, enrolment_id LIMIT %s""",
        (protocol_id, protocol_id, patient_id, patient_id, enrolment_status, enrolment_status,
         after[0], after[0], after[1], limit + 1))
    page = _page(rows, limit, lambda r: f"{r['created_at'].isoformat()}|{r['enrolment_id']}")
    page["items"] = [enrolment_out(ctx, r["enrolment_id"], with_schedule=False) for r in page["items"]]
    return page


@router.get("/enrolments/{enrolment_id}")
def get_enrolment(enrolment_id: uuid.UUID, response: Response, ctx: Ctx = Depends(STAFF)):
    out = enrolment_out(ctx, enrolment_id)
    ctx.log_access("patient_record_view", out["patient_id"], "registry.enrolments", enrolment_id)
    response.headers["ETag"] = etag(out["row_version"])
    return out


class ChecklistAnswer(Strict):
    criterion_code: str
    answer: Literal["yes", "no", "unknown"]


class EligibilityRequest(Strict):
    eligibility_status: Literal["eligible", "ineligible"]
    checklist: list[ChecklistAnswer]


@router.put("/enrolments/{enrolment_id}/eligibility")
def record_eligibility(enrolment_id: uuid.UUID, body: EligibilityRequest, response: Response,
                       if_match: str = Header(...), ctx: Ctx = Depends(ENROLLERS)):
    changes: dict[str, Any] = {
        "eligibility_status": body.eligibility_status,
        "eligibility_checklist": _json([a.model_dump() for a in body.checklist]),
        "eligibility_confirmed_by": ctx.user_id, "eligibility_confirmed_at": sql.SQL("now()")}
    if body.eligibility_status == "ineligible":
        changes.update(enrolment_status="screen_failed", status_changed_on=sql.SQL("current_date"))
    _versioned_update(ctx, "registry.enrolments", "enrolment_id", enrolment_id, if_match, changes,
                      where_extra=sql.SQL("enrolment_status = 'screening'"))
    out = enrolment_out(ctx, enrolment_id)
    response.headers["ETag"] = etag(out["row_version"])
    return out


class HfDetails(Strict):
    registry_code: Literal["HF"]
    hf_status_at_enrolment: str
    hf_diagnosis_date: date | None = None
    hf_diagnosis_date_precision: str | None = None
    index_admission_date: date | None = None
    index_discharge_date: date | None = None
    primary_aetiology: str
    secondary_aetiologies: list[str] | None = None
    baseline_lvef: float | None = None
    baseline_lvef_investigation_id: uuid.UUID | None = None
    prior_lowest_lvef: float | None = None
    baseline_phenotype: str


class LipidDetails(Strict):
    registry_code: Literal["LIPID"]
    prevention_type: str
    categories: list[str]
    fh_diagnosis_basis: str | None = None
    dlcn_score: int | None = None
    statin_intolerance_type: str | None = None
    baseline_ldl_kind: str
    baseline_ldl_mg_dl: float | None = None
    baseline_ldl_result_id: uuid.UUID | None = None
    baseline_on_llt: bool
    baseline_statin_intensity: str | None = None
    lpa_value: float | None = None
    lpa_unit: str | None = None
    lpa_result_id: uuid.UUID | None = None


class CadDetails(Strict):
    registry_code: Literal["CAD"]
    presentation: str
    categories: list[str]
    index_event_date: date
    killip_class_at_presentation: str | None = None
    ccs_class_at_enrolment: str | None = None
    initial_strategy: str | None = None


DETAIL_TABLES = {"HF": "hf_enrolment_details", "LIPID": "lipid_enrolment_details", "CAD": "cad_enrolment_details"}


class EnrolRequest(Strict):
    enrolment_date: date | None = None
    index_date: date
    consent_id: uuid.UUID
    details: Annotated[Union[HfDetails, LipidDetails, CadDetails], Field(discriminator="registry_code")]


@router.post("/enrolments/{enrolment_id}/enrol")
def enrol(enrolment_id: uuid.UUID, body: EnrolRequest, response: Response, if_match: str = Header(...),
          ctx: Ctx = Depends(ENROLLERS)):
    e = _enrolment_row(ctx, enrolment_id)
    if body.details.registry_code != e["registry_code"]:
        raise Problem(422, "PROTOCOL_MISMATCH", "Details are for a different registry",
                      detail=f"protocol is {e['registry_code']}")
    _versioned_update(ctx, "registry.enrolments", "enrolment_id", enrolment_id, if_match, {
        "enrolment_status": "enrolled", "enrolment_date": body.enrolment_date or date.today(),
        "index_date": body.index_date, "consent_id": body.consent_id, "enrolled_by": ctx.user_id},
        where_extra=sql.SQL("enrolment_status = 'screening'"))
    details = body.details.model_dump(exclude={"registry_code"}, exclude_none=True)
    if body.details.registry_code == "HF":
        details["phenotype_confirmed_by"] = ctx.user_id
    cols = ["enrolment_id", "patient_id", "centre_id", *details]
    vals = [enrolment_id, e["patient_id"], ctx.centre_id, *details.values()]
    ctx.conn.execute(sql.SQL("INSERT INTO registry.{} ({}) VALUES ({})").format(
        sql.Identifier(DETAIL_TABLES[body.details.registry_code]),
        sql.SQL(", ").join(map(sql.Identifier, cols)), sql.SQL(", ").join(sql.Placeholder() * len(cols))), vals)
    out = enrolment_out(ctx, enrolment_id)
    response.headers["ETag"] = etag(out["row_version"])
    return out


class StatusChange(Strict):
    enrolment_status: Literal["withdrawn", "lost_to_follow_up", "deceased", "completed"]
    status_changed_on: date
    withdrawal_reason: str | None = None


@router.post("/enrolments/{enrolment_id}/status")
def change_status(enrolment_id: uuid.UUID, body: StatusChange, response: Response, if_match: str = Header(...),
                  ctx: Ctx = Depends(ENROLLERS)):
    require_change_reason(ctx)
    _versioned_update(ctx, "registry.enrolments", "enrolment_id", enrolment_id, if_match, body.model_dump(),
                      where_extra=sql.SQL("enrolment_status = 'enrolled'"))
    out = enrolment_out(ctx, enrolment_id)
    response.headers["ETag"] = etag(out["row_version"])
    return out


@router.get("/enrolments/{enrolment_id}/schedule")
def get_schedule(enrolment_id: uuid.UUID, through: date | None = None, ctx: Ctx = Depends(SCHEDULE_READERS)):
    return {"items": schedule(ctx, enrolment_id, through)}


# --- shared -------------------------------------------------------------------

def schedule(ctx: Ctx, enrolment_id: uuid.UUID, through: date | None = None, today: date | None = None) -> list[dict]:
    facts = ctx.one("SELECT registry.schedule_facts(%s) AS f", (enrolment_id,))["f"]
    if facts is None:
        raise Problem(404, "NOT_FOUND", "Enrolment not found")
    return build_schedule(facts["index_date"], facts["visits"], facts["assessments"], through, today)


def build_schedule(index_date: str | date | None, visits: list[dict], assessments: list[dict],
                   through: date | None = None, today: date | None = None) -> list[dict]:
    """Expected visits with their windows and status, from the protocol's visit schedule and the
    baseline/scheduled assessments already opened (matched in date order per visit code)."""
    if index_date is None:
        return []
    if isinstance(index_date, str):
        index_date = date.fromisoformat(index_date)
    today = today or date.today()
    through = through or index_date + timedelta(days=5 * 365)
    done: dict[str, list] = {}
    for a in assessments:
        done.setdefault(a["visit_code"], []).append(a)
    out = []
    for v in visits:
        n, day = 1, v["target_day"]
        taken = list(done.get(v["visit_code"], []))
        while True:
            target = index_date + timedelta(days=day)
            if target > through:
                break
            opens, closes = target - timedelta(days=v["window_before_days"]), target + timedelta(days=v["window_after_days"])
            a = taken.pop(0) if taken else None
            if a is not None:
                status = {"missed": "missed", "not_applicable": "not_applicable"}.get(a["completion_status"], "done")
            else:
                status = "not_due" if today < opens else ("due" if today <= closes else "overdue")
            out.append({"visit_code": v["visit_code"], "occurrence": n, "target_date": target.isoformat(),
                        "window_opens": opens.isoformat(), "window_closes": closes.isoformat(), "status": status,
                        "assessment_id": a["assessment_id"] if a else None})
            if not v["repeats_every_days"]:
                break
            n, day = n + 1, day + v["repeats_every_days"]
    return sorted(out, key=lambda x: (x["target_date"], x["visit_code"]))


def _enrolment_row(ctx: Ctx, enrolment_id) -> dict:
    e = ctx.one("""SELECT e.*, rt.registry_code FROM registry.enrolments e
                    JOIN registry.registry_types rt USING (registry_type_id) WHERE e.enrolment_id = %s""",
                (enrolment_id,))
    if e is None:
        raise Problem(404, "NOT_FOUND", "Enrolment not found")
    return e


def enrolment_out(ctx: Ctx, enrolment_id, with_schedule: bool = True) -> dict:
    e = _enrolment_row(ctx, enrolment_id)
    details = ctx.one(sql.SQL("SELECT * FROM registry.{} WHERE enrolment_id = %s").format(
        sql.Identifier(DETAIL_TABLES[e["registry_code"]])), (enrolment_id,))
    if details:
        for k in ("enrolment_id", "patient_id", "organisation_id", "centre_id", "created_at", "created_by",
                  "updated_at", "updated_by", "row_version"):
            details.pop(k, None)
        details["registry_code"] = e["registry_code"]
    code = None
    if ctx.role in ("research_coordinator", "principal_investigator"):
        s = ctx.one("SELECT study_subject_code FROM research.study_subjects WHERE enrolment_id = %s", (enrolment_id,))
        code = s and s["study_subject_code"]
    out = {k: e[k] for k in ("enrolment_id", "patient_id", "protocol_id", "registry_code", "screening_date",
                             "enrolment_date", "index_date", "eligibility_status", "consent_id", "enrolment_status",
                             "status_changed_on", "row_version")}
    out.update(study_subject_code=code, details=details)
    if with_schedule:
        out["schedule"] = schedule(ctx, enrolment_id)
    return _jsonable(out)


def _versioned_update(ctx: Ctx, table: str, pk: str, pk_value, if_match: str, changes: dict,
                      where_extra: sql.Composable | None = None) -> dict:
    """UPDATE ... WHERE pk = ? AND row_version = If-Match.  404 if hidden or absent, 412 if stale,
    409 if the row is not in a state that allows the change."""
    version = parse_if_match(if_match)
    schema, name = table.split(".")
    sets = sql.SQL(", ").join(
        sql.SQL("{} = {}").format(sql.Identifier(k), v if isinstance(v, sql.Composable) else sql.Literal(v))
        for k, v in changes.items())
    cond = sql.SQL("{} = %s AND row_version = %s").format(sql.Identifier(pk))
    if where_extra is not None:
        cond = cond + sql.SQL(" AND ") + where_extra
    row = ctx.one(sql.SQL("UPDATE {}.{} SET {} WHERE {} RETURNING *").format(
        sql.Identifier(schema), sql.Identifier(name), sets, cond), (pk_value, version))
    if row is not None:
        return row
    current = ctx.one(sql.SQL("SELECT * FROM {}.{} WHERE {} = %s").format(
        sql.Identifier(schema), sql.Identifier(name), sql.Identifier(pk)), (pk_value,))
    if current is None:
        raise Problem(404, "NOT_FOUND", "Not found")
    if current["row_version"] != version:
        raise Problem(412, "STALE_VERSION", "The resource changed since you read it", current=_jsonable(current))
    raise Problem(409, "CONFLICT", "The resource is not in a state that allows this change",
                  current=_jsonable(current))


def _suggestion_out(r: dict) -> dict:
    return _jsonable({k: r[k] for k in ("suggestion_id", "patient_id", "registry_code", "trigger_diagnosis_id",
                                        "suggested_at", "status", "dismiss_reason", "row_version")})


def _json(v):
    from psycopg.types.json import Jsonb
    return Jsonb(v)


def _jsonable(v):
    from decimal import Decimal
    from datetime import datetime
    if isinstance(v, dict):
        return {k: _jsonable(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_jsonable(x) for x in v]
    if isinstance(v, Decimal):
        return float(v)
    if isinstance(v, (uuid.UUID,)):
        return str(v)
    if isinstance(v, (date, datetime)):
        return v.isoformat()
    if isinstance(v, (bytes, memoryview)):
        return bytes(v).hex()
    return v


def _decode_cursor(cursor: str | None):
    if not cursor:
        return (None, None)
    ts, _, key = cursor.partition("|")
    try:
        return (ts, uuid.UUID(key))
    except ValueError:
        raise Problem(400, "VALIDATION_FAILED", "Invalid cursor") from None


def _page(rows: list[dict], limit: int, cursor_of) -> dict:
    more = len(rows) > limit
    rows = rows[:limit]
    return {"items": [_jsonable(r) for r in rows], "next_cursor": cursor_of(rows[-1]) if more and rows else None}


def _replay(prev):
    status, body = prev
    return JSONResponse(body, status_code=status, headers={"ETag": etag(body.get("row_version", 0))})
