"""Assessments: open a visit, save and verify values, complete, lock and unlock."""
from __future__ import annotations

import uuid
from datetime import date
from typing import Any, Literal

import psycopg
from fastapi import APIRouter, Depends, Header, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from psycopg import sql

from ..context import Ctx, Idempotency, etag, require_change_reason, roles
from ..errors import Problem, from_db_error
from ..prefill import Chart, NotAutomated, derive
from .enrolment import _jsonable, _replay, _versioned_update

router = APIRouter(tags=["Assessments"])
STAFF = roles("clinician", "research_coordinator", "principal_investigator")
LOCKERS = roles("research_coordinator", "principal_investigator")
UNLOCKERS = roles("principal_investigator")

ASSESSMENT_COLS = ("assessment_id", "enrolment_id", "visit_code", "assessment_type", "contact_mode",
                   "assessment_date", "days_from_index", "within_window", "completion_status", "missed_reason",
                   "locked_at", "row_version")
VALUE_COLUMN = {"numeric": "numeric_value", "integer": "numeric_value", "text": "text_value", "date": "date_value",
                "boolean": "boolean_value", "coded": "coded_value", "multi_coded": "coded_values"}
ALL_VALUE_COLUMNS = ("numeric_value", "text_value", "date_value", "boolean_value", "coded_value", "coded_values")
WRITE_COLUMNS = (*ALL_VALUE_COLUMNS, "entered_value", "entered_unit")


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class NewAssessment(Strict):
    visit_code: str = Field(pattern=r"^[A-Z0-9_]{1,12}$")
    assessment_type: Literal["baseline", "scheduled", "unscheduled", "event_triggered", "end_of_study"]
    contact_mode: Literal["in_person", "telephone", "video", "records_review", "proxy"] = "in_person"
    assessment_date: date
    encounter_id: uuid.UUID | None = None
    prefill: bool = False   # true: fill chart-derived variables straight away (see POST .../prefill)


@router.post("/enrolments/{enrolment_id}/assessments", status_code=201)
def create_assessment(enrolment_id: uuid.UUID, body: NewAssessment, idempotency_key: str = Header(...),
                      ctx: Ctx = Depends(STAFF)):
    idem = Idempotency(ctx, idempotency_key, body.model_dump(mode="json"))
    if (prev := idem.previous()) is not None:
        return _replay(prev)
    e = ctx.one("SELECT patient_id, protocol_id, enrolment_status FROM registry.enrolments WHERE enrolment_id = %s",
                (enrolment_id,))
    if e is None:
        raise Problem(404, "NOT_FOUND", "Enrolment not found")
    if e["enrolment_status"] != "enrolled":
        raise Problem(409, "CONFLICT", "Assessments can be opened only for enrolled patients",
                      detail=e["enrolment_status"])
    if body.assessment_type in ("baseline", "scheduled") and ctx.one(
            "SELECT 1 FROM registry.visit_schedule WHERE protocol_id = %s AND visit_code = %s",
            (e["protocol_id"], body.visit_code)) is None:
        raise Problem(422, "VALIDATION_FAILED", "Visit code is not in this protocol's schedule",
                      errors=[{"field": "visit_code", "rule": "in_schedule", "message": body.visit_code}])
    row = ctx.one("""INSERT INTO registry.assessments (enrolment_id, patient_id, centre_id, encounter_id, visit_code,
                       assessment_type, contact_mode, assessment_date)
                     VALUES (%s, %s, %s, %s, %s, %s, %s, %s) RETURNING assessment_id""",
                  (enrolment_id, e["patient_id"], ctx.centre_id, body.encounter_id, body.visit_code,
                   body.assessment_type, body.contact_mode, body.assessment_date))
    out = _assessment(ctx, row["assessment_id"])
    if body.prefill:
        out["prefill"] = run_prefill(ctx, row["assessment_id"])
    idem.store(201, out)
    return JSONResponse(out, status_code=201, headers={"ETag": etag(out["row_version"]),
                                                      "Location": f"/api/v1/assessments/{out['assessment_id']}"})


@router.get("/enrolments/{enrolment_id}/assessments")
def list_assessments(enrolment_id: uuid.UUID, ctx: Ctx = Depends(STAFF)):
    rows = ctx.all(f"SELECT {', '.join(ASSESSMENT_COLS)} FROM registry.assessments WHERE enrolment_id = %s "
                   "ORDER BY assessment_date, created_at", (enrolment_id,))
    return {"items": _jsonable(rows)}


@router.get("/assessments/{assessment_id}")
def get_assessment(assessment_id: uuid.UUID, response: Response, ctx: Ctx = Depends(STAFF)):
    a = _assessment_row(ctx, assessment_id)
    variables = ctx.all("""
        SELECT d.variable_id, d.variable_code, d.definition_version, d.category, d.variable_label, d.data_type,
               d.unit, d.allowed_values, d.min_value, d.max_value, d.source_kind, d.emr_source,
               pv.visit_code, pv.requirement, pv.condition_text,
               v.value_status, v.numeric_value, v.text_value, v.date_value, v.boolean_value, v.coded_value,
               v.coded_values, v.source_kind AS value_source_kind, v.source_table, v.source_row_id,
               v.verification_status, v.updated_at AS value_updated_at, v.row_version AS value_row_version,
               v.entered_value AS value_entered_value, v.entered_unit AS value_entered_unit,
               registry.accepted_units(d.variable_id) AS accepted_units
          FROM registry.protocol_variables pv
          JOIN registry.enrolments e ON e.protocol_id = pv.protocol_id
          JOIN registry.variable_definitions d USING (variable_id)
          LEFT JOIN registry.variable_values v ON v.assessment_id = %s AND v.variable_id = d.variable_id
         WHERE e.enrolment_id = %s AND pv.visit_code IN (%s, '*')
         ORDER BY pv.sort_order, d.variable_code""", (assessment_id, a["enrolment_id"], a["visit_code"]))
    items, missing = [], []
    for r in variables:
        definition = {k: r[k] for k in ("variable_code", "definition_version", "category", "variable_label",
                                        "data_type", "unit", "allowed_values", "min_value", "max_value",
                                        "source_kind", "emr_source", "visit_code", "requirement", "condition_text",
                                        "accepted_units")}
        value = None if r["value_status"] is None else _value_out(r)
        if value is None and r["requirement"] == "mandatory":
            missing.append(r["variable_code"])
        items.append({"definition": definition, "value": value})
    ctx.log_access("patient_record_view", a["patient_id"], "registry.assessments", assessment_id)
    out = _jsonable({k: a[k] for k in ASSESSMENT_COLS})
    out.update(variables=_jsonable(items), mandatory_missing=missing)
    response.headers["ETag"] = etag(a["row_version"])
    return out


@router.post("/assessments/{assessment_id}/prefill")
def prefill_assessment(assessment_id: uuid.UUID, ctx: Ctx = Depends(STAFF)):
    return run_prefill(ctx, assessment_id)


def run_prefill(ctx: Ctx, assessment_id) -> dict:
    """Fill every emr_derived and calculated variable of this visit that has no value yet.
    Never overwrites a stored value; each filled value is unverified and points at its chart row."""
    a = _assessment_row(ctx, assessment_id)
    if a["locked_at"] is not None:
        raise Problem(422, "ASSESSMENT_LOCKED", "Assessment is locked")
    defs = ctx.all("""
        SELECT DISTINCT ON (d.variable_id) d.variable_id, d.variable_code, d.data_type, d.unit, d.source_kind,
               d.derivation_key, d.emr_source, pv.sort_order
          FROM registry.protocol_variables pv JOIN registry.variable_definitions d USING (variable_id)
          JOIN registry.enrolments e ON e.protocol_id = pv.protocol_id
         WHERE e.enrolment_id = %s AND pv.visit_code IN (%s, '*') AND d.source_kind <> 'entered'
         ORDER BY d.variable_id, pv.sort_order""", (a["enrolment_id"], a["visit_code"]))
    defs.sort(key=lambda d: (d["sort_order"], d["variable_code"]))
    existing = {r["variable_id"]: r["source_kind"] for r in ctx.all(
        "SELECT variable_id, source_kind FROM registry.variable_values WHERE assessment_id = %s", (assessment_id,))}
    chart = Chart(ctx, a)
    emap = ctx.request.app.state.error_map
    filled, skipped = [], []
    for d in defs:
        code = d["variable_code"]
        if d["variable_id"] in existing:
            skipped.append({"variable_code": code, "reason": "already_entered" if existing[d["variable_id"]] == "entered"
                            else "already_filled"})
            continue
        try:
            found = derive(chart, d)
        except NotAutomated:
            skipped.append({"variable_code": code, "reason": "not_automated_yet"})
            continue
        if found is None or found.value is None:
            skipped.append({"variable_code": code, "reason": "no_source_in_window"})
            continue
        column = VALUE_COLUMN[d["data_type"]]
        value = int(found.value) if d["data_type"] == "integer" else found.value
        try:
            with ctx.conn.transaction():
                row = ctx.one(sql.SQL(
                    "INSERT INTO registry.variable_values (assessment_id, patient_id, centre_id, variable_id, "
                    "value_status, source_kind, source_table, source_row_id, {}) "
                    "VALUES (%s, %s, %s, %s, 'present', %s, %s, %s, %s) RETURNING *").format(sql.Identifier(column)),
                    (assessment_id, a["patient_id"], ctx.centre_id, d["variable_id"], d["source_kind"],
                     found.table, found.row_id, value))
        except psycopg.Error as ex:
            p = from_db_error(ex, emap)
            skipped.append({"variable_code": code, "reason": "rejected_by_validation", "detail": p.detail or p.title})
            continue
        row.update(variable_code=code, data_type=d["data_type"])
        filled.append(_value_out(row))
    return {"filled": filled, "skipped": skipped}


class ValueInput(Strict):
    variable_code: str = Field(pattern=r"^[a-z][a-z0-9_]{1,62}$")
    value_status: Literal["present", "not_done", "unknown", "not_applicable", "declined"] = "present"
    value: Any = None
    unit: str | None = None
    row_version: int | None = None


class SaveValues(Strict):
    values: list[ValueInput] = Field(min_length=1, max_length=200)


@router.put("/assessments/{assessment_id}/values")
def save_values(assessment_id: uuid.UUID, body: SaveValues, ctx: Ctx = Depends(STAFF)):
    a = _assessment_row(ctx, assessment_id)
    if a["locked_at"] is not None:
        raise Problem(422, "ASSESSMENT_LOCKED", "Assessment is locked")
    codes = [v.variable_code for v in body.values]
    if len(set(codes)) != len(codes):
        raise Problem(400, "VALIDATION_FAILED", "Each variable may appear once per call")
    defs = {r["variable_code"]: r for r in ctx.all("""
        SELECT DISTINCT d.variable_id, d.variable_code, d.data_type, d.unit
          FROM registry.protocol_variables pv JOIN registry.variable_definitions d USING (variable_id)
          JOIN registry.enrolments e ON e.protocol_id = pv.protocol_id
         WHERE e.enrolment_id = %s AND d.variable_code = ANY(%s)""", (a["enrolment_id"], codes))}
    existing = {r["variable_id"]: r for r in ctx.all(
        "SELECT value_id, variable_id, row_version FROM registry.variable_values WHERE assessment_id = %s",
        (assessment_id,))}
    errors, stale, saved = [], [], []
    emap = ctx.request.app.state.error_map
    for v in body.values:
        d = defs.get(v.variable_code)
        if d is None:
            errors.append(_err(v.variable_code, "UNKNOWN_VARIABLE", "Not a variable of this protocol"))
            continue
        try:
            columns = _value_columns(d["data_type"], v)
        except ValueError as ex:
            errors.append(_err(v.variable_code, "WRONG_VALUE_TYPE", str(ex)))
            continue
        if v.unit is not None and v.unit != d["unit"]:
            # Entered in another unit: the database converts it (registry.variable_value_convert)
            # and keeps the typed value and unit beside the converted one.
            if "numeric_value" not in columns:
                errors.append(_err(v.variable_code, "UNIT_NOT_CONVERTIBLE", "Only a numeric value can take a unit"))
                continue
            columns = {"entered_value": columns.pop("numeric_value"), "entered_unit": v.unit}
        prior = existing.get(d["variable_id"])
        if prior is not None:
            if v.row_version is None or v.row_version != prior["row_version"]:
                stale.append(v.variable_code)
                continue
            if not ctx.change_reason:
                raise Problem(428, "CHANGE_REASON_REQUIRED",
                              "X-Change-Reason is required to change a saved value", detail=v.variable_code)
        try:
            with ctx.conn.transaction():   # savepoint: one bad value does not hide the others
                if prior is None:
                    row = ctx.one(sql.SQL(
                        "INSERT INTO registry.variable_values (assessment_id, patient_id, centre_id, variable_id, "
                        "value_status, source_kind, {}) VALUES (%s, %s, %s, %s, %s, 'entered', {}) RETURNING *").format(
                        sql.SQL(", ").join(map(sql.Identifier, WRITE_COLUMNS)),
                        sql.SQL(", ").join(sql.Placeholder() * len(WRITE_COLUMNS))),
                        (assessment_id, a["patient_id"], ctx.centre_id, d["variable_id"], v.value_status,
                         *[columns.get(c) for c in WRITE_COLUMNS]))
                else:
                    row = ctx.one(sql.SQL(
                        "UPDATE registry.variable_values SET value_status = %s, source_kind = 'entered', "
                        "source_table = NULL, source_row_id = NULL, verification_status = 'unverified', {} "
                        "WHERE value_id = %s RETURNING *").format(
                        sql.SQL(", ").join(sql.SQL("{} = %s").format(sql.Identifier(c)) for c in WRITE_COLUMNS)),
                        (v.value_status, *[columns.get(c) for c in WRITE_COLUMNS], prior["value_id"]))
                row["variable_code"] = v.variable_code
                saved.append(row)
        except psycopg.Error as ex:
            p = from_db_error(ex, emap)
            errors.append(_err(v.variable_code, p.code, p.detail or p.title))
    if stale:
        raise Problem(412, "STALE_VERSION", "Some values changed since you read them, or need their row_version",
                      errors=[_err(c, "STALE_VERSION", "row_version missing or out of date") for c in stale])
    if errors:
        raise Problem(422, "VALIDATION_FAILED", "Some values were not accepted; nothing was saved", errors=errors)
    defs_by_id = {d["variable_id"]: d for d in defs.values()}
    return {"items": [_value_out({**r, "data_type": defs_by_id[r["variable_id"]]["data_type"]}) for r in saved]}


class Verification(Strict):
    verification_status: Literal["verified", "queried"]
    query_text: str | None = None


@router.put("/assessments/{assessment_id}/values/{variable_code}/verification")
def verify_value(assessment_id: uuid.UUID, variable_code: str, body: Verification, response: Response,
                 if_match: str = Header(...), ctx: Ctx = Depends(STAFF)):
    v = ctx.one("""SELECT v.value_id FROM registry.variable_values v JOIN registry.variable_definitions d
                     USING (variable_id) WHERE v.assessment_id = %s AND d.variable_code = %s""",
                (assessment_id, variable_code))
    if v is None:
        raise Problem(404, "NOT_FOUND", "No value for this variable")
    row = _versioned_update(ctx, "registry.variable_values", "value_id", v["value_id"], if_match,
                            {"verification_status": body.verification_status})
    if body.verification_status == "queried" and body.query_text:
        ctx.log_access("patient_record_view", row["patient_id"], "registry.variable_values.query",
                       f"{v['value_id']}: {body.query_text[:200]}")
    response.headers["ETag"] = etag(row["row_version"])
    row["variable_code"] = variable_code
    return _value_out(row)


class Completion(Strict):
    completion_status: Literal["complete", "missed", "not_applicable"]
    missed_reason: str | None = None


@router.post("/assessments/{assessment_id}/complete")
def complete_assessment(assessment_id: uuid.UUID, body: Completion, response: Response,
                        if_match: str = Header(...), ctx: Ctx = Depends(STAFF)):
    a = _assessment_row(ctx, assessment_id)
    if body.completion_status == "complete":
        missing = [r["variable_code"] for r in ctx.all("""
            SELECT d.variable_code FROM registry.protocol_variables pv
              JOIN registry.enrolments e ON e.protocol_id = pv.protocol_id
              JOIN registry.variable_definitions d USING (variable_id)
             WHERE e.enrolment_id = %s AND pv.visit_code IN (%s, '*') AND pv.requirement = 'mandatory'
               AND NOT EXISTS (SELECT 1 FROM registry.variable_values v
                               WHERE v.assessment_id = %s AND v.variable_id = d.variable_id)
             ORDER BY pv.sort_order, d.variable_code""", (a["enrolment_id"], a["visit_code"], assessment_id))]
        if missing:
            raise Problem(422, "MANDATORY_MISSING", f"{len(missing)} mandatory variables have no value",
                          errors=[_err(c, "MANDATORY_MISSING", "Enter a value or a reason it is missing")
                                  for c in missing])
    row = _versioned_update(ctx, "registry.assessments", "assessment_id", assessment_id, if_match,
                            {"completion_status": body.completion_status, "missed_reason": body.missed_reason,
                             "completed_by": ctx.user_id})
    response.headers["ETag"] = etag(row["row_version"])
    return _jsonable({k: row[k] for k in ASSESSMENT_COLS})


@router.post("/assessments/{assessment_id}/lock")
def lock_assessment(assessment_id: uuid.UUID, response: Response, if_match: str = Header(...),
                    ctx: Ctx = Depends(LOCKERS)):
    row = _versioned_update(ctx, "registry.assessments", "assessment_id", assessment_id, if_match,
                            {"locked_at": sql.SQL("now()")}, where_extra=sql.SQL("locked_at IS NULL"))
    response.headers["ETag"] = etag(row["row_version"])
    return _jsonable({k: row[k] for k in ASSESSMENT_COLS})


@router.delete("/assessments/{assessment_id}/lock")
def unlock_assessment(assessment_id: uuid.UUID, response: Response, if_match: str = Header(...),
                      ctx: Ctx = Depends(UNLOCKERS)):
    require_change_reason(ctx)
    row = _versioned_update(ctx, "registry.assessments", "assessment_id", assessment_id, if_match,
                            {"locked_at": None}, where_extra=sql.SQL("locked_at IS NOT NULL"))
    response.headers["ETag"] = etag(row["row_version"])
    return _jsonable({k: row[k] for k in ASSESSMENT_COLS})


# --- helpers -----------------------------------------------------------------

def _assessment_row(ctx: Ctx, assessment_id) -> dict:
    a = ctx.one("SELECT * FROM registry.assessments WHERE assessment_id = %s", (assessment_id,))
    if a is None:
        raise Problem(404, "NOT_FOUND", "Assessment not found")
    return a


def _assessment(ctx: Ctx, assessment_id) -> dict:
    a = _assessment_row(ctx, assessment_id)
    return _jsonable({k: a[k] for k in ASSESSMENT_COLS})


def _err(code: str, rule: str, message: str) -> dict:
    return {"variable_code": code, "rule": rule, "message": message}


def _value_columns(data_type: str, v: ValueInput) -> dict:
    if v.value_status != "present":
        if v.value is not None:
            raise ValueError("value must be empty when value_status is not 'present'")
        return {}
    x = v.value
    if x is None:
        raise ValueError("value is required")
    col = VALUE_COLUMN[data_type]
    if data_type in ("numeric", "integer"):
        if isinstance(x, bool) or not isinstance(x, (int, float)):
            raise ValueError(f"expects a number, got {type(x).__name__}")
        return {col: x}
    if data_type == "boolean":
        if not isinstance(x, bool):
            raise ValueError("expects true or false")
        return {col: x}
    if data_type == "date":
        try:
            return {col: date.fromisoformat(x)}
        except (TypeError, ValueError):
            raise ValueError("expects a date as YYYY-MM-DD") from None
    if data_type == "multi_coded":
        if not isinstance(x, list) or not all(isinstance(i, str) for i in x):
            raise ValueError("expects a list of codes")
        return {col: x}
    if not isinstance(x, str):
        raise ValueError("expects text")
    return {col: x}


def _value_out(r: dict) -> dict:
    present = r.get("value_status") == "present"
    value = None
    if present:
        value = next((r[c] for c in ALL_VALUE_COLUMNS if r.get(c) is not None), None)
        if r.get("data_type") == "integer" and value is not None:
            value = int(value)
    return _jsonable({
        "variable_code": r.get("variable_code"), "value_status": r.get("value_status"), "value": value,
        "source_kind": r.get("value_source_kind", r.get("source_kind")), "source_table": r.get("source_table"),
        "source_row_id": r.get("source_row_id"), "verification_status": r.get("verification_status"),
        "entered_value": r.get("value_entered_value", r.get("entered_value")),
        "entered_unit": r.get("value_entered_unit", r.get("entered_unit")),
        "updated_at": r.get("value_updated_at", r.get("updated_at")),
        "row_version": r.get("value_row_version", r.get("row_version"))})
