"""Patient registration and the patient overview, at the acting centre.

A person has one master row (clinical.patients, no identifiers) and one
registration per centre holding that centre's demographics (decision D1).
Everything here reads and writes the acting centre's registration only;
row-level security hides other centres.  Cross-centre matching (HMAC keys,
link requests) is not part of this router."""
from __future__ import annotations

import re
import uuid
from datetime import date
from typing import Literal

from fastapi import APIRouter, Depends, Header, Query, Response
from fastapi.responses import JSONResponse
from psycopg import sql
from pydantic import BaseModel, ConfigDict, Field, model_validator

from ..context import Ctx, Idempotency, etag, require_change_reason, roles
from ..errors import Problem
from .enrolment import _jsonable, _replay, _versioned_update

router = APIRouter(tags=["Patients"])
FRONT_DESK = ("assistant", "nurse", "clinician", "research_coordinator", "principal_investigator")
READERS = roles(*FRONT_DESK)
REGISTRARS = roles(*FRONT_DESK)
REGISTRY_READERS = {"clinician", "research_coordinator", "principal_investigator"}
SUGGESTION_READERS = REGISTRY_READERS | {"nurse"}

MOBILE = r"^\+?[0-9]{10,15}$"
EMAIL = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"
STATES = ("AN AP AR AS BR CH CT DD DL DN GA GJ HP HR JH JK KA KL LA LD MH ML MN MP MZ NL OR PB PY RJ SK TG TN "
          "TR UP UT WB").split()

LIST_COLUMNS = ("patient_id", "registration_id", "local_patient_code", "first_name", "middle_name", "last_name",
                "date_of_birth", "dob_precision", "sex", "mobile", "city", "registration_date", "status",
                "row_version")
DETAIL_COLUMNS = LIST_COLUMNS + ("alternate_mobile", "email", "address_line", "district", "state_code", "pincode",
                                 "abha_number", "abha_address", "emergency_contact_name", "emergency_contact_relation",
                                 "emergency_contact_phone", "occupation", "referral_source", "referral_detail",
                                 "linkage_status", "created_at", "updated_at")


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Demographics(Strict):
    first_name: str = Field(min_length=1, max_length=100)
    middle_name: str | None = Field(None, max_length=100)
    last_name: str | None = Field(None, max_length=100)
    date_of_birth: date | None = None
    dob_precision: Literal["day", "month", "year", "estimated_from_age"] = "day"
    sex: Literal["male", "female", "other", "unknown"]
    mobile: str | None = Field(None, pattern=MOBILE)
    alternate_mobile: str | None = Field(None, pattern=MOBILE)
    email: str | None = Field(None, max_length=254, pattern=EMAIL)
    address_line: str | None = Field(None, max_length=500)
    city: str | None = Field(None, max_length=100)
    district: str | None = Field(None, max_length=100)
    state_code: Literal[tuple(STATES)] | None = None        # type: ignore[valid-type]
    pincode: str | None = Field(None, pattern=r"^[1-9][0-9]{5}$")
    abha_number: str | None = Field(None, pattern=r"^[0-9]{14}$")
    abha_address: str | None = Field(None, max_length=100)
    emergency_contact_name: str | None = Field(None, max_length=200)
    emergency_contact_relation: str | None = Field(None, max_length=50)
    emergency_contact_phone: str | None = Field(None, pattern=MOBILE)
    occupation: str | None = Field(None, max_length=200)
    referral_source: Literal["self", "physician", "cardiologist", "hospital", "camp", "insurer", "other"] | None = None
    referral_detail: str | None = Field(None, max_length=500)

    @model_validator(mode="after")
    def _dob(self):
        if self.date_of_birth is not None and not date(1900, 1, 1) <= self.date_of_birth <= date.today():
            raise ValueError("date_of_birth must be between 1900-01-01 and today")
        return self


class NewPatient(Demographics):
    date_of_birth: date | None = None
    age_years: int | None = Field(None, ge=0, le=120, description="When the date of birth is not known")
    local_patient_code: str | None = Field(None, pattern=r"^[A-Za-z0-9/_-]{1,30}$",
                                           description="Centre's own MRN/UHID; generated when omitted")
    confirm_not_duplicate: bool = False

    @model_validator(mode="after")
    def _age(self):
        if self.date_of_birth is None and self.age_years is None:
            raise ValueError("give date_of_birth or age_years")
        if self.date_of_birth is not None and self.age_years is not None:
            raise ValueError("give date_of_birth or age_years, not both")
        if self.age_years is not None:
            today = date.today()
            self.date_of_birth = date(today.year - self.age_years, 1, 1)
            self.dob_precision = "estimated_from_age"
        return self


class PatientUpdate(Strict):
    """Fields to change; omitted fields keep their value, null clears an optional field."""
    first_name: str | None = Field(None, min_length=1, max_length=100)
    middle_name: str | None = Field(None, max_length=100)
    last_name: str | None = Field(None, max_length=100)
    date_of_birth: date | None = None
    dob_precision: Literal["day", "month", "year", "estimated_from_age"] | None = None
    sex: Literal["male", "female", "other", "unknown"] | None = None
    mobile: str | None = Field(None, pattern=MOBILE)
    alternate_mobile: str | None = Field(None, pattern=MOBILE)
    email: str | None = Field(None, max_length=254, pattern=EMAIL)
    address_line: str | None = Field(None, max_length=500)
    city: str | None = Field(None, max_length=100)
    district: str | None = Field(None, max_length=100)
    state_code: Literal[tuple(STATES)] | None = None        # type: ignore[valid-type]
    pincode: str | None = Field(None, pattern=r"^[1-9][0-9]{5}$")
    abha_number: str | None = Field(None, pattern=r"^[0-9]{14}$")
    abha_address: str | None = Field(None, max_length=100)
    emergency_contact_name: str | None = Field(None, max_length=200)
    emergency_contact_relation: str | None = Field(None, max_length=50)
    emergency_contact_phone: str | None = Field(None, pattern=MOBILE)
    occupation: str | None = Field(None, max_length=200)
    referral_source: Literal["self", "physician", "cardiologist", "hospital", "camp", "insurer", "other"] | None = None
    referral_detail: str | None = Field(None, max_length=500)
    status: Literal["active", "inactive", "transferred_out", "deceased"] | None = None

    @model_validator(mode="after")
    def _required_stay(self):
        for f in ("first_name", "sex", "dob_precision", "status"):
            if f in self.model_fields_set and getattr(self, f) is None:
                raise ValueError(f"{f} cannot be cleared")
        return self


def age_on(dob: date | None, today: date) -> int | None:
    if dob is None:
        return None
    return today.year - dob.year - ((today.month, today.day) < (dob.month, dob.day))


def patient_out(row: dict, today: date | None = None) -> dict:
    out = {k: _jsonable(row[k]) for k in row if k in DETAIL_COLUMNS}
    out["age_years"] = age_on(row.get("date_of_birth"), today or date.today())
    out["display_name"] = " ".join(p for p in (row.get("first_name"), row.get("middle_name"), row.get("last_name")) if p)
    return out


def search_condition(q: str) -> tuple[sql.Composable, list]:
    """Match by local code prefix, mobile digits or name."""
    q = q.strip()
    digits = re.sub(r"\D", "", q)
    parts: list[sql.Composable] = [sql.SQL("local_patient_code ILIKE %s")]
    params: list = [q.replace("%", r"\%").replace("_", r"\_") + "%"]
    if len(digits) >= 4 and len(digits) >= len(q.replace(" ", "").replace("+", "")) - 1:
        parts.append(sql.SQL("mobile LIKE %s"))
        params.append(f"%{digits}%")
    name = q.lower().replace("%", r"\%").replace("_", r"\_")
    parts.append(sql.SQL("lower(first_name || ' ' || coalesce(last_name, '')) LIKE %s"))
    params.append(f"%{name}%")
    parts.append(sql.SQL("lower(first_name || ' ' || coalesce(middle_name || ' ', '') || coalesce(last_name, '')) LIKE %s"))
    params.append(f"%{name}%")
    return sql.SQL("(") + sql.SQL(" OR ").join(parts) + sql.SQL(")"), params


@router.get("/patients")
def list_patients(q: str | None = Query(None, min_length=1, max_length=100), limit: int = Query(25, ge=1, le=100),
                  offset: int = Query(0, ge=0, le=100_000), include_inactive: bool = False,
                  ctx: Ctx = Depends(READERS)):
    conds: list[sql.Composable] = []
    params: list = []
    if not include_inactive:
        conds.append(sql.SQL("status NOT IN ('entered_in_error', 'inactive')"))
    if q:
        c, p = search_condition(q)
        conds.append(c)
        params += p
    where = sql.SQL(" WHERE ") + sql.SQL(" AND ").join(conds) if conds else sql.SQL("")
    order = (sql.SQL(" ORDER BY lower(first_name), lower(coalesce(last_name, '')), local_patient_code")
             if q else sql.SQL(" ORDER BY registration_date DESC, created_at DESC, local_patient_code DESC"))
    query = (sql.SQL("SELECT {} FROM clinical.patient_registrations").format(
        sql.SQL(", ").join(map(sql.Identifier, LIST_COLUMNS))) + where + order + sql.SQL(" LIMIT %s OFFSET %s"))
    rows = ctx.all(query, [*params, limit + 1, offset])
    ctx.log_access("search", None, "clinical.patient_registrations", ctx.centre_id)
    today = date.today()
    return {"items": [patient_out(r, today) for r in rows[:limit]], "has_more": len(rows) > limit,
            "limit": limit, "offset": offset}


def _possible_duplicates(ctx: Ctx, body: NewPatient) -> list[dict]:
    rows = ctx.all(
        "SELECT patient_id, local_patient_code, first_name, middle_name, last_name, date_of_birth, sex, mobile "
        "FROM clinical.patient_registrations WHERE status <> 'entered_in_error' AND ("
        " (%(mobile)s::text IS NOT NULL AND mobile = %(mobile)s)"
        " OR (%(abha)s::text IS NOT NULL AND abha_number = %(abha)s)"
        " OR (date_of_birth = %(dob)s AND lower(first_name) = lower(%(first)s)"
        "     AND lower(coalesce(last_name, '')) = lower(coalesce(%(last)s, ''))))"
        " ORDER BY local_patient_code LIMIT 10",
        {"mobile": body.mobile, "abha": body.abha_number, "dob": body.date_of_birth, "first": body.first_name,
         "last": body.last_name})
    return [{**{k: _jsonable(v) for k, v in r.items()},
             "display_name": " ".join(p for p in (r["first_name"], r["middle_name"], r["last_name"]) if p)}
            for r in rows]


@router.post("/patients", status_code=201)
def register_patient(body: NewPatient, idempotency_key: str = Header(...), ctx: Ctx = Depends(REGISTRARS)):
    idem = Idempotency(ctx, idempotency_key, body.model_dump(mode="json"))
    if (prev := idem.previous()) is not None:
        return _replay(prev)
    if not body.confirm_not_duplicate and (dups := _possible_duplicates(ctx, body)):
        raise Problem(409, "POSSIBLE_DUPLICATE", "A patient with the same mobile, ABHA number or name and date of "
                      "birth is already registered at this centre", current=dups)
    patient_id = uuid.uuid4()                      # no RETURNING: the master row is invisible until registered here
    ctx.conn.execute("INSERT INTO clinical.patients (patient_id) VALUES (%s)", (patient_id,))
    code = body.local_patient_code or ctx.one("SELECT clinical.next_local_patient_code() AS c")["c"]
    values = body.model_dump(exclude={"age_years", "local_patient_code", "confirm_not_duplicate"})
    cols = ["patient_id", "centre_id", "local_patient_code", *values]
    row = ctx.one(sql.SQL("INSERT INTO clinical.patient_registrations ({}) VALUES ({}) RETURNING *").format(
        sql.SQL(", ").join(map(sql.Identifier, cols)), sql.SQL(", ").join(sql.Placeholder() * len(cols))),
        [patient_id, ctx.centre_id, code, *values.values()])
    out = patient_out(row)
    idem.store(201, out)
    return JSONResponse(out, status_code=201, headers={"ETag": etag(row["row_version"]),
                                                      "Location": f"/api/v1/patients/{patient_id}"})


@router.get("/patients/{patient_id}")
def get_patient(patient_id: uuid.UUID, response: Response, ctx: Ctx = Depends(READERS)):
    row = ctx.one("SELECT * FROM clinical.patient_registrations WHERE patient_id = %s", (patient_id,))
    if row is None:
        raise Problem(404, "NOT_FOUND", "Patient not found at this centre")
    ctx.log_access("patient_record_view", patient_id, "clinical.patient_registrations", row["registration_id"])
    response.headers["ETag"] = etag(row["row_version"])
    return {"patient": patient_out(row), **_overview(ctx, patient_id)}


def _overview(ctx: Ctx, patient_id: uuid.UUID) -> dict:
    """What the patient header and overview show, limited to what the acting role may read."""
    consents = ctx.all(
        "SELECT c.consent_id, c.consent_type, c.consent_status, c.consent_date, c.consent_form_version, "
        "c.withdrawal_date, p.protocol_code FROM clinical.patient_consents c "
        "LEFT JOIN registry.registry_protocols p USING (protocol_id) WHERE c.patient_id = %s "
        "ORDER BY c.consent_date DESC, c.created_at DESC", (patient_id,)) if ctx.role in REGISTRY_READERS else ctx.all(
        "SELECT consent_id, consent_type, consent_status, consent_date, consent_form_version, withdrawal_date, "
        "NULL::text AS protocol_code FROM clinical.patient_consents WHERE patient_id = %s "
        "ORDER BY consent_date DESC, created_at DESC", (patient_id,))
    allergies = ctx.all(
        "SELECT allergy_id, allergen_type, allergen_text, reaction, severity FROM clinical.allergies "
        "WHERE patient_id = %s AND status = 'active' ORDER BY created_at", (patient_id,))
    encounters = ctx.all(
        "SELECT e.encounter_id, e.encounter_type, e.encounter_start, e.status, e.follow_up_date, "
        "u.full_name AS clinician_name FROM clinical.encounters e LEFT JOIN iam.users u ON u.user_id = e.clinician_id "
        "WHERE e.patient_id = %s AND e.status <> 'entered_in_error' ORDER BY e.encounter_start DESC LIMIT 10",
        (patient_id,))
    out = {"consents": consents, "allergies": allergies, "recent_encounters": encounters,
           "enrolments": None, "registry_suggestions": None}
    if ctx.role in REGISTRY_READERS:
        out["enrolments"] = ctx.all(
            "SELECT e.enrolment_id, t.registry_code, t.registry_name, p.protocol_code, e.enrolment_status, "
            "e.eligibility_status, e.screening_date, e.enrolment_date, e.index_date FROM registry.enrolments e "
            "JOIN registry.registry_types t USING (registry_type_id) "
            "JOIN registry.registry_protocols p USING (protocol_id) "
            "WHERE e.patient_id = %s ORDER BY e.screening_date DESC", (patient_id,))
    if ctx.role in SUGGESTION_READERS:
        out["registry_suggestions"] = ctx.all(
            "SELECT suggestion_id, registry_code, suggested_at, status FROM registry.registry_suggestions "
            "WHERE patient_id = %s AND status = 'open' ORDER BY suggested_at", (patient_id,))
    return _jsonable(out)


@router.patch("/patients/{patient_id}")
def update_patient(patient_id: uuid.UUID, body: PatientUpdate, if_match: str = Header(...),
                   ctx: Ctx = Depends(REGISTRARS)):
    require_change_reason(ctx)
    changes = body.model_dump(exclude_unset=True)
    if not changes:
        raise Problem(400, "VALIDATION_FAILED", "Nothing to change")
    reg = ctx.one("SELECT registration_id FROM clinical.patient_registrations WHERE patient_id = %s", (patient_id,))
    if reg is None:
        raise Problem(404, "NOT_FOUND", "Patient not found at this centre")
    row = _versioned_update(ctx, "clinical.patient_registrations", "registration_id", reg["registration_id"], if_match,
                            changes, sql.SQL("status <> 'entered_in_error'"))
    return JSONResponse(patient_out(row), headers={"ETag": etag(row["row_version"])})
