"""Prescribing: a medication course per drug, and an append-only event for
every start, dose change, hold, resume and stop (PRD module 4).  Nothing is
overwritten: the dose in force on any date is the latest event that was not
voided, and the research views read the same events.

The daily dose is worked out here from strength, quantity and frequency, in
the drug's reference unit (ref.drugs.reference_unit), because it drives the
GDMT percentage of target dose and statin intensity."""
from __future__ import annotations

import uuid
from datetime import date
from typing import Literal

from fastapi import APIRouter, Depends, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, model_validator

from ..context import Ctx, roles
from ..errors import Problem
from .consultations import _encounter_row, _patient_here, _require_draft
from .enrolment import _jsonable

router = APIRouter(tags=["Medications"])
READERS = roles("assistant", "nurse", "clinician", "research_coordinator", "principal_investigator")
PRESCRIBERS = roles("clinician")

Frequency = Literal["OD", "BD", "TDS", "QID", "HS", "weekly", "Q2W", "Q4W", "Q6M", "SOS", "other"]
DoseUnit = Literal["tablet", "capsule", "mg", "mcg", "ml", "unit", "puff", "sachet", "injection"]
Route = Literal["oral", "sublingual", "iv", "sc", "im", "inhaled", "transdermal", "topical", "other"]
DOSES_PER_DAY = {"OD": 1, "BD": 2, "TDS": 3, "QID": 4, "HS": 1, "weekly": 1 / 7, "Q2W": 1 / 14, "Q4W": 1 / 28,
                 "Q6M": 1 / 182.5}
DOSING_EVENTS = ("initiate", "increase", "decrease", "change_frequency", "switch_product", "resume",
                 "record_external", "reconcile_continue")


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Dose(Strict):
    product_id: uuid.UUID | None = None
    brand_name_text: str | None = Field(None, max_length=200)
    strength: float | None = Field(None, gt=0, le=100000, description="Per tablet/capsule/ml/unit, in the drug's "
                                   "reference unit; taken from the product when product_id is given")
    strength_label: str | None = Field(None, max_length=50)
    dose_quantity: float = Field(gt=0, le=1000)
    dose_unit: DoseUnit = "tablet"
    frequency_code: Frequency
    doses_per_day: float | None = Field(None, gt=0, le=24, description="Needed for SOS and other")
    route: Route | None = None
    duration_days: int | None = Field(None, gt=0, le=3650)
    instructions: str | None = Field(None, max_length=1000)


class NewMedication(Dose):
    drug_code: str = Field(pattern=r"^[A-Z0-9_]+$")
    started_on: date | None = None
    indication: str | None = Field(None, max_length=300)
    reason_code: str | None = Field(None, pattern=r"^RSN_[A-Z_]+$")
    reason_text: str | None = Field(None, max_length=500)
    prescriber_source: Literal["this_centre", "external", "patient_reported"] = "this_centre"
    encounter_id: uuid.UUID | None = None


class CourseEvent(Strict):
    event_type: Literal["dose_change", "hold", "resume", "discontinue", "reconcile_continue"]
    effective_date: date | None = None
    dose: Dose | None = Field(None, description="Required for dose_change")
    reason_code: str | None = Field(None, pattern=r"^RSN_[A-Z_]+$")
    reason_text: str | None = Field(None, max_length=500)
    encounter_id: uuid.UUID | None = None

    @model_validator(mode="after")
    def _check(self):
        if self.event_type == "dose_change" and self.dose is None:
            raise ValueError("a dose change needs the new dose")
        if self.event_type != "dose_change" and self.dose is not None:
            raise ValueError("only a dose change takes a dose")
        if self.event_type in ("hold", "discontinue") and not (self.reason_code or self.reason_text):
            raise ValueError("say why the medicine is held or stopped")
        return self


class VoidEvent(Strict):
    reason_text: str = Field(min_length=5, max_length=500)


def daily_dose(strength: float | None, quantity: float, unit: str, frequency: str, doses_per_day: float | None,
               reference_unit: str) -> tuple[float, float]:
    """(doses per day, daily dose in the reference unit)."""
    per_day = DOSES_PER_DAY.get(frequency) if frequency not in ("SOS", "other") else None
    per_day = doses_per_day or per_day
    if per_day is None:
        raise Problem(422, "VALIDATION_FAILED", "Give the number of doses per day for SOS or other frequencies")
    if unit in ("mg", "mcg"):
        if reference_unit not in ("mg", "mcg"):
            raise Problem(422, "VALIDATION_FAILED", f"This drug is dosed in {reference_unit}")
        factor = {("mg", "mg"): 1, ("mcg", "mg"): 0.001, ("mg", "mcg"): 1000, ("mcg", "mcg"): 1}[(unit, reference_unit)]
        per_dose = quantity * factor
    else:
        if strength is None:
            raise Problem(422, "VALIDATION_FAILED", f"Give the strength per {unit} in {reference_unit}")
        per_dose = quantity * strength
    return per_day, round(per_dose * per_day, 4)


def _resolve_dose(ctx: Ctx, drug: dict, d: Dose) -> dict:
    strength, label, brand = d.strength, d.strength_label, d.brand_name_text
    if d.product_id:
        p = ctx.one("SELECT drug_id, brand_name, strength_label, reference_strength, dose_form FROM ref.drug_products "
                    "WHERE product_id = %s AND status = 'active'", (d.product_id,))
        if p is None or p["drug_id"] != drug["drug_id"]:
            raise Problem(422, "VALIDATION_FAILED", "The product is not a form of this drug")
        strength, label = float(p["reference_strength"]), p["strength_label"]
        brand = brand or (p["brand_name"] if p["brand_name"] != "Generic" else None)
    if label is None and strength is not None and d.dose_unit not in ("mg", "mcg"):
        label = f"{strength:g} {drug['reference_unit']}"
    per_day, daily = daily_dose(strength, d.dose_quantity, d.dose_unit, d.frequency_code, d.doses_per_day,
                                drug["reference_unit"])
    return {"product_id": d.product_id, "brand_name_text": brand, "strength_label": label,
            "dose_quantity": d.dose_quantity, "dose_unit": d.dose_unit, "frequency_code": d.frequency_code,
            "doses_per_day": round(per_day, 6), "daily_dose": daily, "route": d.route or drug["default_route"],
            "duration_days": d.duration_days, "instructions": d.instructions}


def _reason(ctx: Ctx, code: str | None) -> uuid.UUID | None:
    if not code:
        return None
    r = ctx.one("SELECT concept_id FROM ref.concepts WHERE concept_code = %s AND domain = 'reason'", (code,))
    if r is None:
        raise Problem(422, "VALIDATION_FAILED", "Unknown reason", detail=code)
    return r["concept_id"]


def _check_encounter(ctx: Ctx, encounter_id: uuid.UUID | None, patient_id: uuid.UUID) -> None:
    if encounter_id:
        enc = _encounter_row(ctx, encounter_id)
        if enc["patient_id"] != patient_id:
            raise Problem(422, "VALIDATION_FAILED", "The consultation belongs to another patient")
        _require_draft(enc)


def _insert_event(ctx: Ctx, course: dict, event_type: str, effective: date, dose: dict | None, reason_id, reason_text,
                  encounter_id, source: str = "this_centre", voids: uuid.UUID | None = None) -> uuid.UUID:
    event_id = uuid.uuid4()
    d = dose or {}
    ctx.conn.execute(
        "INSERT INTO clinical.medication_events (medication_event_id, course_id, patient_id, centre_id, encounter_id, "
        "event_type, effective_date, drug_id, product_id, brand_name_text, strength_label, dose_quantity, dose_unit, "
        "frequency_code, doses_per_day, daily_dose, route, duration_days, instructions, reason_concept_id, reason_text, "
        "prescribed_by, prescriber_source, voids_event_id) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, "
        "%s, %s, %s, coalesce(%s, 'oral'), %s, %s, %s, %s, %s, %s, %s)",
        (event_id, course["course_id"], course["patient_id"], ctx.centre_id, encounter_id, event_type, effective,
         course["drug_id"], d.get("product_id"), d.get("brand_name_text"), d.get("strength_label"),
         d.get("dose_quantity"), d.get("dose_unit"), d.get("frequency_code"), d.get("doses_per_day"),
         d.get("daily_dose"), d.get("route"), d.get("duration_days"), d.get("instructions"), reason_id, reason_text,
         ctx.user_id if source == "this_centre" else None, source, voids))
    return event_id


COURSE_SELECT = (
    "SELECT c.course_id, c.patient_id, c.drug_id, d.drug_code, d.generic_name, d.reference_unit, d.default_route, "
    "c.indication, c.started_on, c.stopped_on, c.status, c.row_version, "
    "array(SELECT m.drug_class_code FROM ref.drug_class_members m WHERE m.drug_id = c.drug_id ORDER BY 1) AS classes "
    "FROM clinical.medication_courses c JOIN ref.drugs d USING (drug_id) ")
EVENT_SELECT = (
    "SELECT e.medication_event_id, e.event_type, e.effective_date, e.recorded_at, e.encounter_id, e.brand_name_text, "
    "e.strength_label, e.dose_quantity, e.dose_unit, e.frequency_code, e.doses_per_day, e.daily_dose, e.route, "
    "e.duration_days, e.instructions, e.reason_text, rc.display_name AS reason, e.prescriber_source, e.voids_event_id, "
    "u.full_name AS prescribed_by_name, "
    "EXISTS (SELECT 1 FROM clinical.medication_events v WHERE v.voids_event_id = e.medication_event_id) AS voided "
    "FROM clinical.medication_events e LEFT JOIN iam.users u ON u.user_id = e.prescribed_by "
    "LEFT JOIN ref.concepts rc ON rc.concept_id = e.reason_concept_id ")


def _course_out(ctx: Ctx, course: dict, with_events: bool = True) -> dict:
    events = ctx.all(EVENT_SELECT + "WHERE e.course_id = %s ORDER BY e.effective_date, e.recorded_at",
                     (course["course_id"],))
    current = next((e for e in reversed(events) if e["event_type"] in DOSING_EVENTS and not e["voided"]), None)
    out = {k: course[k] for k in course if k != "patient_id"}
    out["current_dose"] = current
    if with_events:
        out["events"] = events
    return out


def current_medications(ctx: Ctx, patient_id: uuid.UUID, include_stopped: bool = False) -> list[dict]:
    where = "c.status <> 'entered_in_error'" if include_stopped else "c.status IN ('active','on_hold')"
    courses = ctx.all(COURSE_SELECT + f"WHERE c.patient_id = %s AND {where} "
                      "ORDER BY (c.status = 'stopped'), d.generic_name", (patient_id,))
    return [_jsonable(_course_out(ctx, c)) for c in courses]


def _course(ctx: Ctx, course_id: uuid.UUID) -> dict:
    c = ctx.one(COURSE_SELECT + "WHERE c.course_id = %s FOR UPDATE OF c", (course_id,))
    if c is None:
        raise Problem(404, "NOT_FOUND", "Medicine not found at this centre")
    return c


# --- endpoints ----------------------------------------------------------------------


# A beta-blocker class allergy also covers the beta-blockers kept outside the
# HF class (atenolol, propranolol), which sit in their own class only so they do
# not count towards the GDMT pillar.
ALLERGY_CLASS_ALSO_COVERS = {"BETA_BLOCKER": ["BETA_BLOCKER_NON_HF"]}


def matching_allergy(ctx: Ctx, patient_id: uuid.UUID, drug_id) -> dict | None:
    """An active allergy that rules this drug out: linked to the drug, to one of its
    classes, or a drug allergy typed by hand that names the drug's ingredient."""
    extra = [(k, v) for k, vs in ALLERGY_CLASS_ALSO_COVERS.items() for v in vs]
    return ctx.one(
        "WITH cls AS (SELECT drug_class_code FROM ref.drug_class_members WHERE drug_id = %(d)s), "
        "covers(allergy_class, member_class) AS (SELECT * FROM unnest(%(ak)s::text[], %(mk)s::text[])) "
        "SELECT a.allergen_text FROM clinical.allergies a, ref.drugs dr "
        "WHERE dr.drug_id = %(d)s AND a.patient_id = %(p)s AND a.status = 'active' AND ("
        " a.drug_id = dr.drug_id"
        " OR a.drug_class_code IN (SELECT drug_class_code FROM cls)"
        " OR a.drug_class_code IN (SELECT allergy_class FROM covers WHERE member_class IN (SELECT drug_class_code FROM cls))"
        " OR (a.allergen_type = 'drug' AND a.drug_id IS NULL"
        "     AND position(lower(dr.reference_ingredient) IN lower(a.allergen_text)) > 0)) LIMIT 1",
        {"d": drug_id, "p": patient_id, "ak": [k for k, _ in extra], "mk": [v for _, v in extra]})

@router.get("/drugs")
def search_drugs(q: str | None = Query(None, max_length=60), limit: int = Query(20, ge=1, le=100),
                 ctx: Ctx = Depends(READERS)):
    pattern = f"%{(q or '').lower().replace('%', '').replace('_', ' ')}%"
    drugs = ctx.all(
        "SELECT d.drug_id, d.drug_code, d.generic_name, d.reference_unit, d.default_route, d.is_combination, "
        "array(SELECT m.drug_class_code FROM ref.drug_class_members m WHERE m.drug_id = d.drug_id ORDER BY 1) AS classes "
        "FROM ref.drugs d WHERE d.status = 'active' AND (lower(d.generic_name) LIKE %s OR lower(replace(d.drug_code, '_', ' ')) "
        "LIKE %s OR EXISTS (SELECT 1 FROM ref.drug_products p WHERE p.drug_id = d.drug_id AND p.status = 'active' "
        "AND lower(p.brand_name) LIKE %s AND p.brand_name <> 'Generic')) "
        "ORDER BY (lower(d.generic_name) LIKE %s) DESC, d.generic_name LIMIT %s",
        (pattern, pattern, pattern, pattern[1:], limit))
    products = ctx.all(
        "SELECT product_id, drug_id, brand_name, strength_label, reference_strength, dose_form FROM ref.drug_products "
        "WHERE status = 'active' AND drug_id = ANY(%s) ORDER BY reference_strength", ([d["drug_id"] for d in drugs],))
    for d in drugs:
        d["products"] = [{k: p[k] for k in p if k != "drug_id"} for p in products if p["drug_id"] == d["drug_id"]]
        del d["drug_id"]
    return {"items": _jsonable(drugs)}


@router.get("/patients/{patient_id}/medications")
def list_medications(patient_id: uuid.UUID, include_stopped: bool = False, ctx: Ctx = Depends(READERS)):
    _patient_here(ctx, patient_id)
    ctx.log_access("patient_record_view", patient_id, "clinical.medication_courses", patient_id)
    return {"items": current_medications(ctx, patient_id, include_stopped)}


@router.post("/patients/{patient_id}/medications", status_code=201)
def start_medication(patient_id: uuid.UUID, body: NewMedication, ctx: Ctx = Depends(PRESCRIBERS)):
    _patient_here(ctx, patient_id)
    _check_encounter(ctx, body.encounter_id, patient_id)
    drug = ctx.one("SELECT drug_id, generic_name, reference_unit, default_route FROM ref.drugs "
                   "WHERE drug_code = %s AND status = 'active'", (body.drug_code,))
    if drug is None:
        raise Problem(422, "VALIDATION_FAILED", "Unknown drug", detail=body.drug_code)
    if ctx.one("SELECT 1 FROM clinical.medication_courses WHERE patient_id = %s AND drug_id = %s "
               "AND status IN ('active','on_hold')", (patient_id, drug["drug_id"])):
        raise Problem(409, "ALREADY_PRESCRIBED", f"{drug['generic_name']} is already on the medicine list; "
                      "change its dose instead")
    allergy = matching_allergy(ctx, patient_id, drug["drug_id"])
    if allergy:
        raise Problem(409, "ALLERGY", f"Recorded allergy: {allergy['allergen_text']}")
    dose = _resolve_dose(ctx, drug, body)
    started = body.started_on or date.today()
    if started > date.today():
        raise Problem(422, "VALIDATION_FAILED", "Start date is in the future")
    course_id = uuid.uuid4()
    ctx.conn.execute(
        "INSERT INTO clinical.medication_courses (course_id, patient_id, centre_id, drug_id, indication, started_on) "
        "VALUES (%s, %s, %s, %s, %s, %s)",
        (course_id, patient_id, ctx.centre_id, drug["drug_id"], body.indication, started))
    course = _course(ctx, course_id)
    event_type = "initiate" if body.prescriber_source == "this_centre" else "record_external"
    _insert_event(ctx, course, event_type, started, dose, _reason(ctx, body.reason_code), body.reason_text,
                  body.encounter_id, body.prescriber_source)
    out = _jsonable(_course_out(ctx, _course(ctx, course_id)))
    return JSONResponse(out, status_code=201, headers={"Location": f"/api/v1/medication-courses/{course_id}"})


@router.get("/medication-courses/{course_id}")
def get_course(course_id: uuid.UUID, ctx: Ctx = Depends(READERS)):
    c = ctx.one(COURSE_SELECT + "WHERE c.course_id = %s", (course_id,))
    if c is None:
        raise Problem(404, "NOT_FOUND", "Medicine not found at this centre")
    return _jsonable(_course_out(ctx, c))


@router.post("/medication-courses/{course_id}/events", status_code=201)
def course_event(course_id: uuid.UUID, body: CourseEvent, ctx: Ctx = Depends(PRESCRIBERS)):
    course = _course(ctx, course_id)
    _check_encounter(ctx, body.encounter_id, course["patient_id"])
    effective = body.effective_date or date.today()
    if effective > date.today() or effective < course["started_on"]:
        raise Problem(422, "VALIDATION_FAILED", "The date must be between the start date and today")
    state = course["status"]
    allowed = {"dose_change": ("active",), "hold": ("active",), "resume": ("on_hold", "stopped"),
               "discontinue": ("active", "on_hold"), "reconcile_continue": ("active",)}[body.event_type]
    if state not in allowed:
        raise Problem(409, "CONFLICT", f"The medicine is {state.replace('_', ' ')}; it cannot take a "
                      f"{body.event_type.replace('_', ' ')}")
    current = _course_out(ctx, course, with_events=False)["current_dose"]
    reason_id = _reason(ctx, body.reason_code)
    if body.event_type == "dose_change":
        drug = {"drug_id": course["drug_id"], "reference_unit": course["reference_unit"],
                "default_route": course["default_route"]}
        dose = _resolve_dose(ctx, drug, body.dose)
        old = float(current["daily_dose"]) if current and current["daily_dose"] is not None else None
        if old is not None and dose["daily_dose"] > old + 1e-9:
            event_type = "increase"
        elif old is not None and dose["daily_dose"] < old - 1e-9:
            event_type = "decrease"
        elif current and dose["frequency_code"] != current["frequency_code"]:
            event_type = "change_frequency"
        elif current and (dose["product_id"] or dose["strength_label"] != current["strength_label"]
                          or dose["brand_name_text"] != current["brand_name_text"]):
            event_type = "switch_product"
        else:
            raise Problem(422, "VALIDATION_FAILED", "The new dose is the same as the current dose")
    else:
        event_type = body.event_type
        dose = None
        if event_type in ("resume", "reconcile_continue"):
            if current is None:
                raise Problem(409, "CONFLICT", "No earlier dose to continue; record a dose change instead")
            dose = {k: current[k] for k in ("brand_name_text", "strength_label", "dose_quantity", "dose_unit",
                                            "frequency_code", "doses_per_day", "daily_dose", "route",
                                            "duration_days", "instructions")}
    _insert_event(ctx, course, event_type, effective, dose, reason_id, body.reason_text, body.encounter_id)
    return JSONResponse(_jsonable(_course_out(ctx, _course(ctx, course_id))), status_code=201)


@router.post("/medication-events/{event_id}/void", status_code=201)
def void_event(event_id: uuid.UUID, body: VoidEvent, ctx: Ctx = Depends(PRESCRIBERS)):
    """Marks an event entered in error.  The event stays; the course status is recomputed from what remains."""
    ev = ctx.one("SELECT medication_event_id, course_id, event_type, encounter_id, "
                 "EXISTS (SELECT 1 FROM clinical.medication_events v WHERE v.voids_event_id = e.medication_event_id) "
                 "AS voided FROM clinical.medication_events e WHERE medication_event_id = %s", (event_id,))
    if ev is None:
        raise Problem(404, "NOT_FOUND", "Medication event not found at this centre")
    if ev["event_type"] == "void" or ev["voided"]:
        raise Problem(409, "CONFLICT", "This event is already voided")
    course = _course(ctx, ev["course_id"])
    _insert_event(ctx, course, "void", date.today(), None, None, body.reason_text, None, voids=event_id)
    remaining = [e for e in ctx.all(EVENT_SELECT + "WHERE e.course_id = %s ORDER BY e.effective_date, e.recorded_at",
                                    (course["course_id"],)) if e["event_type"] != "void" and not e["voided"]]
    if not any(e["event_type"] in DOSING_EVENTS for e in remaining):
        status, stopped = "entered_in_error", None
    else:
        last = next((e for e in reversed(remaining) if e["event_type"] in (*DOSING_EVENTS, "hold", "discontinue")))
        status = {"hold": "on_hold", "discontinue": "stopped"}.get(last["event_type"], "active")
        stopped = last["effective_date"] if status == "stopped" else None
    ctx.conn.execute("UPDATE clinical.medication_courses SET status = %s, stopped_on = %s WHERE course_id = %s",
                     (status, stopped, course["course_id"]))
    return JSONResponse(_jsonable(_course_out(ctx, _course(ctx, course["course_id"]))), status_code=201)
