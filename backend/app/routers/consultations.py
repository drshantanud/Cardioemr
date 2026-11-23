"""Consultations (clinical.encounters) and what is recorded with them:
presenting complaints, structured assessment, vitals, diagnoses, allergies,
and the clinical summary shown beside a new consultation.

A consultation is a draft until the responsible clinician signs it.  A signed
consultation is frozen by the database (encounter_signed_guard); corrections
are amendments that keep the original text."""
from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Literal

from fastapi import APIRouter, Depends, Header, Query, Response
from fastapi.responses import JSONResponse
from psycopg import sql
from pydantic import BaseModel, ConfigDict, Field, model_validator

from ..context import Ctx, Idempotency, etag, parse_if_match, require_change_reason, roles
from ..errors import Problem
from .enrolment import _jsonable, _replay, _versioned_update

router = APIRouter(tags=["Consultations"])
FRONT_DESK = ("assistant", "nurse", "clinician", "research_coordinator", "principal_investigator")
READERS = roles(*FRONT_DESK)
CLINICIAN = roles("clinician")
NOTE_WRITERS = roles("clinician", "nurse")
VITALS_WRITERS = roles("assistant", "nurse", "clinician")
DIAGNOSIS_WRITERS = roles("clinician", "nurse")
ALLERGY_WRITERS = roles("assistant", "nurse", "clinician")

NOTE_FIELDS = ("presenting_complaint", "history_present_illness", "clinical_history", "examination_cvs",
               "examination_resp", "examination_other", "assessment", "plan", "lifestyle_advice", "patient_education",
               "referral_to")
ENCOUNTER_COLS = ("encounter_id", "patient_id", "clinician_id", "encounter_type", "setting", "encounter_start",
                  "encounter_end", *NOTE_FIELDS, "follow_up_date", "status", "signed_at", "signed_by", "error_reason",
                  "row_version", "created_at", "updated_at")
ASSESSMENT_FIELDS = ("nyha_class", "ccs_class", "killip_class", "jvp", "jvp_cm", "peripheral_oedema", "pulmonary_rales",
                     "s3_gallop", "orthopnoea", "pnd", "congestion_status", "hf_phenotype", "cv_risk_category")
VITAL_FIELDS = ("height_cm", "weight_kg", "waist_cm", "systolic_bp", "diastolic_bp", "bp_position", "heart_rate",
                "pulse_rhythm", "respiratory_rate", "spo2", "temperature_c")
SUMMARY_ANALYTES = ("LDL_C", "NON_HDL_C", "TC", "HDL_C", "TG", "APOB", "LPA_NMOL_L", "LPA_MG_DL", "NT_PROBNP", "HS_TNI",
                    "HS_TNT", "CREATININE", "EGFR", "K", "NA", "HBA1C", "FBS", "HB", "HS_CRP", "ALT", "CK", "TSH")

EncounterType = Literal["new_consultation", "follow_up", "registry_visit", "teleconsultation", "telephone",
                        "inpatient_review", "emergency", "procedure", "retrospective_entry"]


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


Text = Field(None, max_length=20000)


class NoteFields(Strict):
    encounter_type: EncounterType | None = None
    setting: Literal["outpatient", "inpatient", "emergency", "remote"] | None = None
    presenting_complaint: str | None = Text
    history_present_illness: str | None = Text
    clinical_history: str | None = Text
    examination_cvs: str | None = Text
    examination_resp: str | None = Text
    examination_other: str | None = Text
    assessment: str | None = Text
    plan: str | None = Text
    lifestyle_advice: str | None = Text
    patient_education: str | None = Text
    referral_to: str | None = Field(None, max_length=500)
    follow_up_date: date | None = None


class Complaint(Strict):
    concept_code: str = Field(pattern=r"^CX_[A-Z_]+$")
    duration_value: float | None = Field(None, ge=0, le=1000)
    duration_unit: Literal["hours", "days", "weeks", "months", "years"] | None = None
    detail: str | None = Field(None, max_length=1000)

    @model_validator(mode="after")
    def _pair(self):
        if (self.duration_value is None) != (self.duration_unit is None):
            raise ValueError("duration needs both a value and a unit")
        return self


class Assessment(Strict):
    nyha_class: Literal["I", "II", "III", "IV"] | None = None
    ccs_class: Literal["0", "I", "II", "III", "IV"] | None = None
    killip_class: Literal["I", "II", "III", "IV"] | None = None
    jvp: Literal["normal", "raised", "not_assessable"] | None = None
    jvp_cm: float | None = Field(None, ge=0, le=30)
    peripheral_oedema: Literal["none", "ankle", "below_knee", "above_knee", "sacral", "anasarca"] | None = None
    pulmonary_rales: bool | None = None
    s3_gallop: bool | None = None
    orthopnoea: bool | None = None
    pnd: bool | None = None
    congestion_status: Literal["euvolaemic", "mild", "moderate", "severe"] | None = None
    hf_phenotype: Literal["HFrEF", "HFmrEF", "HFpEF", "HFimpEF"] | None = None
    cv_risk_category: Literal["low", "moderate", "high", "very_high", "extreme"] | None = None


class NewEncounter(Strict):
    encounter_type: EncounterType = "follow_up"
    setting: Literal["outpatient", "inpatient", "emergency", "remote"] = "outpatient"
    encounter_start: datetime | None = None


class SaveEncounter(Strict):
    note: NoteFields = NoteFields()
    complaints: list[Complaint] | None = Field(None, max_length=20, description="Replaces the list when given")
    assessment: Assessment | None = Field(None, description="Replaces the structured assessment when given")


class Amendment(Strict):
    field_name: Literal[NOTE_FIELDS]  # type: ignore[valid-type]
    amended_value: str = Field(max_length=20000)
    reason: str = Field(min_length=5, max_length=500)


class Vitals(Strict):
    encounter_id: uuid.UUID | None = None
    measured_at: datetime | None = None
    height_cm: float | None = Field(None, ge=50, le=250)
    weight_kg: float | None = Field(None, ge=2, le=350)
    waist_cm: float | None = Field(None, ge=30, le=250)
    systolic_bp: int | None = Field(None, ge=50, le=300)
    diastolic_bp: int | None = Field(None, ge=20, le=200)
    bp_position: Literal["sitting", "supine", "standing"] | None = None
    heart_rate: int | None = Field(None, ge=20, le=300)
    pulse_rhythm: Literal["regular", "irregular"] | None = None
    respiratory_rate: int | None = Field(None, ge=4, le=80)
    spo2: int | None = Field(None, ge=40, le=100)
    temperature_c: float | None = Field(None, ge=30, le=45)

    @model_validator(mode="after")
    def _some(self):
        if all(getattr(self, f) is None for f in VITAL_FIELDS):
            raise ValueError("record at least one measurement")
        if self.systolic_bp and self.diastolic_bp and self.diastolic_bp >= self.systolic_bp:
            raise ValueError("diastolic must be below systolic")
        return self


class NewDiagnosis(Strict):
    concept_code: str | None = Field(None, pattern=r"^DX_[A-Z0-9_]+$")
    diagnosis_text: str | None = Field(None, min_length=2, max_length=500)
    icd10_code: str | None = Field(None, pattern=r"^[A-Z][0-9]{2}(\.[0-9A-Z]{1,4})?$")
    diagnosis_role: Literal["working", "final", "comorbidity", "past_history", "complication"]
    certainty: Literal["suspected", "confirmed"] = "confirmed"
    is_principal: bool = False
    onset_date: date | None = None
    onset_precision: Literal["day", "month", "year"] | None = None
    encounter_id: uuid.UUID | None = None

    @model_validator(mode="after")
    def _check(self):
        if not self.concept_code and not self.diagnosis_text:
            raise ValueError("choose a diagnosis or type one")
        if self.onset_date and not self.onset_precision:
            self.onset_precision = "day"
        if self.onset_precision and not self.onset_date:
            raise ValueError("onset precision needs an onset date")
        if self.onset_date and self.onset_date > date.today():
            raise ValueError("onset date is in the future")
        return self


class DiagnosisUpdate(Strict):
    diagnosis_role: Literal["working", "final", "comorbidity", "past_history", "complication"] | None = None
    certainty: Literal["suspected", "confirmed", "refuted"] | None = None
    is_principal: bool | None = None
    status: Literal["active", "resolved", "entered_in_error"] | None = None
    resolved_date: date | None = None


class NewAllergy(Strict):
    allergen_type: Literal["drug", "drug_class", "contrast", "food", "other"]
    drug_code: str | None = Field(None, pattern=r"^[A-Z0-9_]+$")
    drug_class_code: str | None = Field(None, pattern=r"^[A-Z0-9_]+$")
    allergen_text: str = Field(min_length=2, max_length=200)
    reaction: str | None = Field(None, max_length=500)
    severity: Literal["mild", "moderate", "severe", "anaphylaxis"] | None = None


class AllergyUpdate(Strict):
    status: Literal["active", "inactive", "entered_in_error"]


# --- helpers ------------------------------------------------------------------

def _patient_here(ctx: Ctx, patient_id: uuid.UUID) -> None:
    if ctx.one("SELECT 1 FROM clinical.patient_registrations WHERE patient_id = %s AND status <> 'entered_in_error'",
               (patient_id,)) is None:
        raise Problem(404, "NOT_FOUND", "Patient not found at this centre")


def _encounter_row(ctx: Ctx, encounter_id: uuid.UUID, for_update: bool = False) -> dict:
    row = ctx.one("SELECT * FROM clinical.encounters WHERE encounter_id = %s" + (" FOR UPDATE" if for_update else ""),
                  (encounter_id,))
    if row is None:
        raise Problem(404, "NOT_FOUND", "Consultation not found at this centre")
    return row


def _require_draft(row: dict) -> None:
    if row["status"] != "draft":
        raise Problem(409, "ENCOUNTER_SIGNED", "The consultation is signed; record an amendment instead")


def _check_version(row: dict, if_match: str) -> None:
    if row["row_version"] != parse_if_match(if_match):
        raise Problem(412, "STALE_VERSION", "The consultation changed since you read it",
                      current={"row_version": row["row_version"]})


def encounter_out(ctx: Ctx, encounter_id: uuid.UUID) -> dict:
    e = ctx.one(
        "SELECT e.*, u.full_name AS clinician_name, s.full_name AS signed_by_name FROM clinical.encounters e "
        "LEFT JOIN iam.users u ON u.user_id = e.clinician_id LEFT JOIN iam.users s ON s.user_id = e.signed_by "
        "WHERE e.encounter_id = %s", (encounter_id,))
    if e is None:
        raise Problem(404, "NOT_FOUND", "Consultation not found at this centre")
    out = {k: e[k] for k in ENCOUNTER_COLS}
    out["clinician_name"], out["signed_by_name"] = e["clinician_name"], e["signed_by_name"]
    out["complaints"] = ctx.all(
        "SELECT c.concept_code, c.display_name, ec.duration_value, ec.duration_unit, ec.detail "
        "FROM clinical.encounter_complaints ec JOIN ref.concepts c ON c.concept_id = ec.complaint_concept_id "
        "WHERE ec.encounter_id = %s ORDER BY ec.created_at, c.display_name", (encounter_id,))
    a = ctx.one("SELECT * FROM clinical.clinical_assessments WHERE encounter_id = %s", (encounter_id,))
    out["clinical_assessment"] = {k: a[k] for k in ASSESSMENT_FIELDS} if a else None
    out["vitals"] = ctx.all(
        "SELECT vital_id, measured_at, bmi, " + ", ".join(VITAL_FIELDS) + " FROM clinical.vital_signs "
        "WHERE encounter_id = %s AND status = 'final' ORDER BY measured_at DESC", (encounter_id,))
    out["diagnoses"] = ctx.all(
        "SELECT d.diagnosis_id, c.concept_code, d.diagnosis_text, d.icd10_code, d.diagnosis_role, d.certainty, "
        "d.is_principal, d.status FROM clinical.diagnoses d LEFT JOIN ref.concepts c USING (concept_id) "
        "WHERE d.encounter_id = %s AND d.status <> 'entered_in_error' ORDER BY d.is_principal DESC, d.created_at",
        (encounter_id,))
    out["medication_events"] = ctx.all(
        "SELECT m.medication_event_id, m.course_id, m.event_type, m.effective_date, dr.generic_name, m.strength_label, "
        "m.dose_quantity, m.dose_unit, m.frequency_code, m.daily_dose, dr.reference_unit, m.route, m.instructions, "
        "m.reason_text, m.brand_name_text, (SELECT true FROM clinical.medication_events v "
        " WHERE v.voids_event_id = m.medication_event_id LIMIT 1) IS NOT NULL AS voided "
        "FROM clinical.medication_events m JOIN ref.drugs dr USING (drug_id) "
        "WHERE m.encounter_id = %s AND m.event_type <> 'void' ORDER BY m.recorded_at", (encounter_id,))
    out["amendments"] = ctx.all(
        "SELECT a.amendment_id, a.field_name, a.previous_value, a.amended_value, a.reason, a.amended_at, "
        "u.full_name AS amended_by_name FROM clinical.encounter_amendments a "
        "LEFT JOIN iam.users u ON u.user_id = a.amended_by WHERE a.encounter_id = %s ORDER BY a.amended_at",
        (encounter_id,))
    return _jsonable(out)


def _respond(ctx: Ctx, encounter_id: uuid.UUID, status: int = 200) -> JSONResponse:
    body = encounter_out(ctx, encounter_id)
    headers = {"ETag": etag(body["row_version"])}
    if status == 201:
        headers["Location"] = f"/api/v1/encounters/{encounter_id}"
    return JSONResponse(body, status_code=status, headers=headers)


# --- consultations --------------------------------------------------------------

@router.get("/patients/{patient_id}/encounters")
def list_encounters(patient_id: uuid.UUID, limit: int = Query(20, ge=1, le=100), ctx: Ctx = Depends(READERS)):
    _patient_here(ctx, patient_id)
    rows = ctx.all(
        "SELECT e.encounter_id, e.encounter_type, e.setting, e.encounter_start, e.status, e.signed_at, "
        "e.follow_up_date, left(e.assessment, 300) AS assessment_preview, u.full_name AS clinician_name, "
        "(SELECT string_agg(c.display_name, ', ' ORDER BY c.display_name) FROM clinical.encounter_complaints ec "
        " JOIN ref.concepts c ON c.concept_id = ec.complaint_concept_id WHERE ec.encounter_id = e.encounter_id) "
        " AS complaints FROM clinical.encounters e LEFT JOIN iam.users u ON u.user_id = e.clinician_id "
        "WHERE e.patient_id = %s AND e.status <> 'entered_in_error' ORDER BY e.encounter_start DESC LIMIT %s",
        (patient_id, limit))
    ctx.log_access("patient_record_view", patient_id, "clinical.encounters", patient_id)
    return {"items": _jsonable(rows)}


@router.post("/patients/{patient_id}/encounters", status_code=201)
def start_encounter(patient_id: uuid.UUID, body: NewEncounter, idempotency_key: str = Header(...),
                    ctx: Ctx = Depends(CLINICIAN)):
    idem = Idempotency(ctx, idempotency_key, body.model_dump(mode="json"))
    if (prev := idem.previous()) is not None:
        return _replay(prev)
    _patient_here(ctx, patient_id)
    encounter_id = uuid.uuid4()
    ctx.conn.execute(
        "INSERT INTO clinical.encounters (encounter_id, patient_id, centre_id, clinician_id, encounter_type, setting, "
        "encounter_start) VALUES (%s, %s, %s, %s, %s, %s, coalesce(%s, now()))",
        (encounter_id, patient_id, ctx.centre_id, ctx.user_id, body.encounter_type, body.setting, body.encounter_start))
    resp = _respond(ctx, encounter_id, 201)
    idem.store(201, encounter_out(ctx, encounter_id))
    return resp


@router.get("/encounters/{encounter_id}")
def get_encounter(encounter_id: uuid.UUID, ctx: Ctx = Depends(READERS)):
    row = _encounter_row(ctx, encounter_id)
    ctx.log_access("patient_record_view", row["patient_id"], "clinical.encounters", encounter_id)
    return _respond(ctx, encounter_id)


@router.put("/encounters/{encounter_id}")
def save_encounter(encounter_id: uuid.UUID, body: SaveEncounter, if_match: str = Header(...),
                   ctx: Ctx = Depends(NOTE_WRITERS)):
    row = _encounter_row(ctx, encounter_id, for_update=True)
    _require_draft(row)
    _check_version(row, if_match)
    note = body.note.model_dump(exclude_unset=True)
    for f in ("encounter_type", "setting"):
        if f in note and note[f] is None:
            del note[f]
    # Always touch the row so its version moves with every save, including child-only saves.
    changes = {**note, "updated_at": sql.SQL("now()")}
    sets = sql.SQL(", ").join(sql.SQL("{} = {}").format(sql.Identifier(k), v if isinstance(v, sql.Composable)
                                                         else sql.Literal(v)) for k, v in changes.items())
    ctx.conn.execute(sql.SQL("UPDATE clinical.encounters SET {} WHERE encounter_id = %s").format(sets), (encounter_id,))
    pid = row["patient_id"]
    if body.complaints is not None:
        codes = [c.concept_code for c in body.complaints]
        if len(set(codes)) != len(codes):
            raise Problem(400, "VALIDATION_FAILED", "A complaint is listed twice")
        found = {r["concept_code"]: r["concept_id"] for r in ctx.all(
            "SELECT concept_code, concept_id FROM ref.concepts WHERE domain = 'complaint' AND status = 'active' "
            "AND concept_code = ANY(%s)", (codes,))}
        if missing := [c for c in codes if c not in found]:
            raise Problem(422, "VALIDATION_FAILED", "Unknown presenting complaint", detail=", ".join(missing))
        ctx.conn.execute("DELETE FROM clinical.encounter_complaints WHERE encounter_id = %s", (encounter_id,))
        for c in body.complaints:
            ctx.conn.execute(
                "INSERT INTO clinical.encounter_complaints (encounter_id, patient_id, centre_id, complaint_concept_id, "
                "duration_value, duration_unit, detail) VALUES (%s, %s, %s, %s, %s, %s, %s)",
                (encounter_id, pid, ctx.centre_id, found[c.concept_code], c.duration_value, c.duration_unit, c.detail))
    if body.assessment is not None:
        a = body.assessment.model_dump()
        cols = list(a)
        ctx.conn.execute(
            sql.SQL("INSERT INTO clinical.clinical_assessments (encounter_id, patient_id, centre_id, {cols}) "
                    "VALUES (%s, %s, %s, {vals}) ON CONFLICT (encounter_id) DO UPDATE SET {upd}").format(
                cols=sql.SQL(", ").join(map(sql.Identifier, cols)),
                vals=sql.SQL(", ").join(sql.Placeholder() * len(cols)),
                upd=sql.SQL(", ").join(sql.SQL("{0} = EXCLUDED.{0}").format(sql.Identifier(c)) for c in cols)),
            [encounter_id, pid, ctx.centre_id, *a.values()])
    return _respond(ctx, encounter_id)


@router.post("/encounters/{encounter_id}/sign")
def sign_encounter(encounter_id: uuid.UUID, if_match: str = Header(...), ctx: Ctx = Depends(CLINICIAN)):
    row = _encounter_row(ctx, encounter_id, for_update=True)
    _require_draft(row)
    _check_version(row, if_match)
    has_content = any(row[f] for f in NOTE_FIELDS) or ctx.one(
        "SELECT 1 FROM clinical.encounter_complaints WHERE encounter_id = %s UNION ALL "
        "SELECT 1 FROM clinical.clinical_assessments WHERE encounter_id = %s UNION ALL "
        "SELECT 1 FROM clinical.diagnoses WHERE encounter_id = %s LIMIT 1", (encounter_id,) * 3)
    if not has_content:
        raise Problem(422, "VALIDATION_FAILED", "Nothing to sign: the consultation is empty")
    ctx.conn.execute(
        "UPDATE clinical.encounters SET status = 'signed', signed_at = now(), signed_by = %s, "
        "encounter_end = coalesce(encounter_end, now()) WHERE encounter_id = %s", (ctx.user_id, encounter_id))
    return _respond(ctx, encounter_id)


@router.post("/encounters/{encounter_id}/amendments", status_code=201)
def amend_encounter(encounter_id: uuid.UUID, body: Amendment, ctx: Ctx = Depends(CLINICIAN)):
    row = _encounter_row(ctx, encounter_id, for_update=True)
    if row["status"] not in ("signed", "amended"):
        raise Problem(409, "CONFLICT", "Only a signed consultation takes amendments; edit the draft instead")
    last = ctx.one("SELECT amended_value FROM clinical.encounter_amendments WHERE encounter_id = %s AND field_name = %s "
                   "ORDER BY amended_at DESC LIMIT 1", (encounter_id, body.field_name))
    previous = last["amended_value"] if last else row[body.field_name]
    if (previous or "") == body.amended_value:
        raise Problem(422, "VALIDATION_FAILED", "The amended text is the same as the current text")
    ctx.conn.execute(
        "INSERT INTO clinical.encounter_amendments (encounter_id, patient_id, centre_id, field_name, previous_value, "
        "amended_value, reason) VALUES (%s, %s, %s, %s, %s, %s, %s)",
        (encounter_id, row["patient_id"], ctx.centre_id, body.field_name, previous, body.amended_value, body.reason))
    return _respond(ctx, encounter_id, 201)


# --- vitals ---------------------------------------------------------------------

@router.post("/patients/{patient_id}/vitals", status_code=201)
def record_vitals(patient_id: uuid.UUID, body: Vitals, ctx: Ctx = Depends(VITALS_WRITERS)):
    _patient_here(ctx, patient_id)
    if body.encounter_id:
        enc = _encounter_row(ctx, body.encounter_id)
        if enc["patient_id"] != patient_id:
            raise Problem(422, "VALIDATION_FAILED", "The consultation belongs to another patient")
        _require_draft(enc)
    values = {k: v for k, v in body.model_dump().items() if v is not None}
    cols = ["patient_id", "centre_id", *values]
    row = ctx.one(sql.SQL("INSERT INTO clinical.vital_signs ({}) VALUES ({}) RETURNING vital_id, measured_at, bmi, "
                          + ", ".join(VITAL_FIELDS)).format(
        sql.SQL(", ").join(map(sql.Identifier, cols)), sql.SQL(", ").join(sql.Placeholder() * len(cols))),
        [patient_id, ctx.centre_id, *values.values()])
    return JSONResponse(_jsonable(row), status_code=201)


@router.get("/patients/{patient_id}/vitals")
def list_vitals(patient_id: uuid.UUID, limit: int = Query(10, ge=1, le=100), ctx: Ctx = Depends(READERS)):
    _patient_here(ctx, patient_id)
    rows = ctx.all("SELECT vital_id, encounter_id, measured_at, bmi, " + ", ".join(VITAL_FIELDS) +
                   " FROM clinical.vital_signs WHERE patient_id = %s AND status = 'final' "
                   "ORDER BY measured_at DESC LIMIT %s", (patient_id, limit))
    return {"items": _jsonable(rows)}


# --- diagnoses -------------------------------------------------------------------

DIAGNOSIS_SELECT = (
    "SELECT d.diagnosis_id, d.encounter_id, c.concept_code, d.diagnosis_text, d.icd10_code, d.diagnosis_role, "
    "d.certainty, d.is_principal, d.onset_date, d.onset_precision, d.resolved_date, d.status, d.created_at, "
    "d.row_version FROM clinical.diagnoses d LEFT JOIN ref.concepts c USING (concept_id) ")


@router.get("/patients/{patient_id}/diagnoses")
def list_diagnoses(patient_id: uuid.UUID, include_resolved: bool = True, ctx: Ctx = Depends(READERS)):
    _patient_here(ctx, patient_id)
    where = "d.status <> 'entered_in_error'" if include_resolved else "d.status = 'active'"
    rows = ctx.all(DIAGNOSIS_SELECT + f"WHERE d.patient_id = %s AND {where} "
                   "ORDER BY d.status, d.is_principal DESC, d.created_at DESC", (patient_id,))
    return {"items": _jsonable(rows)}


@router.post("/patients/{patient_id}/diagnoses", status_code=201)
def add_diagnosis(patient_id: uuid.UUID, body: NewDiagnosis, ctx: Ctx = Depends(DIAGNOSIS_WRITERS)):
    _patient_here(ctx, patient_id)
    concept_id, text, icd10 = None, body.diagnosis_text, body.icd10_code
    if body.concept_code:
        c = ctx.one("SELECT c.concept_id, c.display_name, (SELECT m.code FROM ref.concept_mappings m "
                    " WHERE m.concept_id = c.concept_id AND m.code_system = 'ICD-10' ORDER BY m.code LIMIT 1) AS icd10 "
                    "FROM ref.concepts c WHERE c.concept_code = %s AND c.domain = 'diagnosis' AND c.status = 'active'",
                    (body.concept_code,))
        if c is None:
            raise Problem(422, "VALIDATION_FAILED", "Unknown diagnosis", detail=body.concept_code)
        concept_id, text, icd10 = c["concept_id"], text or c["display_name"], icd10 or c["icd10"]
    elif body.diagnosis_role != "working" and not icd10:
        raise Problem(422, "VALIDATION_FAILED", "A typed diagnosis needs an ICD-10 code unless it is a working diagnosis")
    if body.encounter_id:
        enc = _encounter_row(ctx, body.encounter_id)
        if enc["patient_id"] != patient_id:
            raise Problem(422, "VALIDATION_FAILED", "The consultation belongs to another patient")
        _require_draft(enc)
    before = {r["suggestion_id"] for r in _open_suggestions(ctx, patient_id)} if ctx.role == "clinician" else set()
    row = ctx.one(
        "INSERT INTO clinical.diagnoses (patient_id, centre_id, encounter_id, concept_id, diagnosis_text, icd10_code, "
        "diagnosis_role, certainty, is_principal, onset_date, onset_precision) "
        "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING diagnosis_id",
        (patient_id, ctx.centre_id, body.encounter_id, concept_id, text, icd10, body.diagnosis_role, body.certainty,
         body.is_principal, body.onset_date, body.onset_precision))
    out = _jsonable(ctx.one(DIAGNOSIS_SELECT + "WHERE d.diagnosis_id = %s", (row["diagnosis_id"],)))
    new = [s for s in _open_suggestions(ctx, patient_id) if s["suggestion_id"] not in before] \
        if ctx.role == "clinician" else []
    out["new_registry_suggestions"] = _jsonable(new)
    return JSONResponse(out, status_code=201, headers={"ETag": etag(out["row_version"])})


def _open_suggestions(ctx: Ctx, patient_id: uuid.UUID) -> list[dict]:
    return ctx.all("SELECT suggestion_id, registry_code FROM registry.registry_suggestions "
                   "WHERE patient_id = %s AND status = 'open'", (patient_id,))


@router.patch("/diagnoses/{diagnosis_id}")
def update_diagnosis(diagnosis_id: uuid.UUID, body: DiagnosisUpdate, if_match: str = Header(...),
                     ctx: Ctx = Depends(DIAGNOSIS_WRITERS)):
    changes = body.model_dump(exclude_unset=True)
    if not changes:
        raise Problem(400, "VALIDATION_FAILED", "Nothing to change")
    if changes.get("status") == "resolved" and not changes.get("resolved_date"):
        changes["resolved_date"] = date.today()
    if changes.get("status") == "entered_in_error":
        require_change_reason(ctx)
    row = _versioned_update(ctx, "clinical.diagnoses", "diagnosis_id", diagnosis_id, if_match, changes,
                            sql.SQL("status <> 'entered_in_error'"))
    out = _jsonable(ctx.one(DIAGNOSIS_SELECT + "WHERE d.diagnosis_id = %s", (row["diagnosis_id"],)))
    return JSONResponse(out, headers={"ETag": etag(out["row_version"])})


# --- allergies -------------------------------------------------------------------

@router.post("/patients/{patient_id}/allergies", status_code=201)
def add_allergy(patient_id: uuid.UUID, body: NewAllergy, ctx: Ctx = Depends(ALLERGY_WRITERS)):
    _patient_here(ctx, patient_id)
    drug_id = None
    if body.drug_code:
        d = ctx.one("SELECT drug_id FROM ref.drugs WHERE drug_code = %s", (body.drug_code,))
        if d is None:
            raise Problem(422, "VALIDATION_FAILED", "Unknown drug", detail=body.drug_code)
        drug_id = d["drug_id"]
    elif body.allergen_type == "drug":
        # A drug typed by name is linked to the catalogue when it names one drug exactly.
        d = ctx.one("SELECT drug_id FROM ref.drugs WHERE status = 'active' AND (lower(generic_name) = lower(%s) "
                    "OR lower(reference_ingredient) = lower(%s))", (body.allergen_text.strip(), body.allergen_text.strip()))
        drug_id = d["drug_id"] if d else None
    if body.drug_class_code and ctx.one("SELECT 1 FROM ref.drug_classes WHERE drug_class_code = %s",
                                        (body.drug_class_code,)) is None:
        raise Problem(422, "VALIDATION_FAILED", "Unknown drug class", detail=body.drug_class_code)
    row = ctx.one(
        "INSERT INTO clinical.allergies (patient_id, centre_id, allergen_type, drug_id, drug_class_code, allergen_text, "
        "reaction, severity) VALUES (%s, %s, %s, %s, %s, %s, %s, %s) "
        "RETURNING allergy_id, allergen_type, allergen_text, reaction, severity, status, row_version",
        (patient_id, ctx.centre_id, body.allergen_type, drug_id, body.drug_class_code, body.allergen_text,
         body.reaction, body.severity))
    return JSONResponse(_jsonable(row), status_code=201, headers={"ETag": etag(row["row_version"])})


@router.patch("/allergies/{allergy_id}")
def update_allergy(allergy_id: uuid.UUID, body: AllergyUpdate, if_match: str = Header(...),
                   ctx: Ctx = Depends(ALLERGY_WRITERS)):
    require_change_reason(ctx)
    row = _versioned_update(ctx, "clinical.allergies", "allergy_id", allergy_id, if_match, {"status": body.status})
    return JSONResponse(_jsonable({k: row[k] for k in ("allergy_id", "allergen_type", "allergen_text", "reaction",
                                                         "severity", "status", "row_version")}),
                        headers={"ETag": etag(row["row_version"])})


# --- reference lookups ----------------------------------------------------------------

@router.get("/concepts")
def list_concepts(domain: Literal["complaint", "diagnosis", "reason"], ctx: Ctx = Depends(READERS)):
    rows = ctx.all(
        "SELECT c.concept_code, c.display_name, (SELECT m.code FROM ref.concept_mappings m WHERE m.concept_id = "
        "c.concept_id AND m.code_system = 'ICD-10' ORDER BY m.code LIMIT 1) AS icd10_code, "
        "array(SELECT t.registry_code FROM ref.concept_registry_triggers t WHERE t.concept_id = c.concept_id "
        " ORDER BY 1) AS registry_triggers "
        "FROM ref.concepts c WHERE c.domain = %s AND c.status = 'active' ORDER BY c.display_name", (domain,))
    return {"items": rows}


# --- summary beside a consultation ------------------------------------------------------

@router.get("/patients/{patient_id}/clinical-summary")
def clinical_summary(patient_id: uuid.UUID, response: Response, ctx: Ctx = Depends(READERS)):
    """What a clinician wants in view while writing the next note: the last signed consultation, current
    medicines, active problems, allergies, latest vitals and the latest key results."""
    _patient_here(ctx, patient_id)
    last = ctx.one(
        "SELECT encounter_id FROM clinical.encounters WHERE patient_id = %s AND status IN ('signed','amended') "
        "ORDER BY encounter_start DESC LIMIT 1", (patient_id,))
    labs = ctx.all(
        "SELECT DISTINCT ON (r.analyte_code) r.analyte_code, a.analyte_name, r.comparator, r.value_reported, "
        "r.unit_reported, r.value_canonical, a.canonical_unit, r.collected_at, r.verification_status, r.abnormal_flag "
        "FROM clinical.lab_results r JOIN ref.analytes a USING (analyte_code) "
        "WHERE r.patient_id = %s AND r.status <> 'entered_in_error' AND r.analyte_code = ANY(%s) "
        "ORDER BY r.analyte_code, r.collected_at DESC", (patient_id, list(SUMMARY_ANALYTES)))
    order = {a: i for i, a in enumerate(SUMMARY_ANALYTES)}
    labs.sort(key=lambda r: order.get(r["analyte_code"], 99))
    echo = ctx.one(
        "SELECT i.performed_on, e.lvef, e.lvef_method, e.rv_function, e.diastolic_grade, e.pasp_mmhg, e.interpretation, "
        "i.verification_status FROM clinical.echo_reports e JOIN clinical.investigations i USING (investigation_id) "
        "WHERE e.patient_id = %s AND i.status <> 'entered_in_error' ORDER BY i.performed_on DESC LIMIT 1", (patient_id,))
    ecg = ctx.one(
        "SELECT i.performed_on, g.rhythm, g.heart_rate, g.qrs_ms, g.qtc_ms, g.qrs_morphology, g.interpretation, "
        "i.verification_status FROM clinical.ecg_reports g JOIN clinical.investigations i USING (investigation_id) "
        "WHERE g.patient_id = %s AND i.status <> 'entered_in_error' ORDER BY i.performed_on DESC LIMIT 1", (patient_id,))
    vitals = ctx.one("SELECT measured_at, bmi, " + ", ".join(VITAL_FIELDS) + " FROM clinical.vital_signs "
                     "WHERE patient_id = %s AND status = 'final' ORDER BY measured_at DESC LIMIT 1", (patient_id,))
    from .medications import current_medications      # late import: medications imports helpers from here
    ctx.log_access("patient_record_view", patient_id, "clinical.clinical_summary", patient_id)
    return _jsonable({
        "last_signed_encounter": encounter_out(ctx, last["encounter_id"]) if last else None,
        "medications": current_medications(ctx, patient_id),
        "diagnoses": ctx.all(DIAGNOSIS_SELECT + "WHERE d.patient_id = %s AND d.status = 'active' "
                             "ORDER BY d.is_principal DESC, d.created_at DESC", (patient_id,)),
        "allergies": ctx.all("SELECT allergy_id, allergen_type, allergen_text, reaction, severity, row_version "
                             "FROM clinical.allergies WHERE patient_id = %s AND status = 'active' ORDER BY created_at",
                             (patient_id,)),
        "latest_vitals": vitals, "latest_labs": labs, "latest_echo": echo, "latest_ecg": ecg,
    })
