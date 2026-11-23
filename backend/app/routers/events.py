"""Clinical events and their adjudication.

An event is reported once.  The database opens one pending adjudication for
every protocol the patient is enrolled in (at this centre) whose endpoints
use the event type (registry._open_adjudications, migration 0006).
Adjudication is always a human decision, by a clinician or PI who did not
report the event; the database enforces that and checks the classification
against the endpoint's classification system."""
from __future__ import annotations

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

router = APIRouter(tags=["Events"])
REPORTERS = roles("clinician", "research_coordinator", "nurse")
READERS = roles("clinician", "research_coordinator", "principal_investigator", "nurse")
CORRECTORS = roles("clinician", "research_coordinator")
ADJUDICATORS = roles("principal_investigator", "clinician")
QUEUE_READERS = roles("principal_investigator", "clinician", "research_coordinator")
REGISTRY_ROLES = ("clinician", "research_coordinator", "principal_investigator")

EventType = Literal["death", "mi", "stroke", "tia", "hf_hospitalisation", "urgent_hf_visit", "worsening_hf_outpatient",
                    "pci", "cabg", "stent_thrombosis", "bleeding", "hyperkalaemia", "hypotension",
                    "renal_deterioration", "arrhythmia", "device_therapy", "other_cv_hospitalisation",
                    "non_cv_hospitalisation", "other"]
HOSPITAL_TYPES = {"hf_hospitalisation", "other_cv_hospitalisation", "non_cv_hospitalisation"}


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class EventDetails(Strict):
    event_date: date
    event_date_precision: Literal["day", "month", "year"] = "day"
    is_historical: bool = False
    description: str | None = Field(None, max_length=4000)
    hospitalised: bool | None = None
    admission_date: date | None = None
    discharge_date: date | None = None
    facility_name: str | None = Field(None, max_length=200)
    severity: Literal["mild", "moderate", "severe", "life_threatening", "fatal"] | None = None
    outcome: Literal["recovered", "recovered_with_sequelae", "ongoing", "fatal", "unknown"] | None = None
    death_cause: Literal["cardiovascular", "non_cardiovascular", "undetermined"] | None = None
    death_cv_mode: Literal["sudden", "heart_failure", "mi", "stroke", "procedural", "other_cv"] | None = None
    mi_type: Literal["1", "2", "3", "4a", "4b", "4c", "5"] | None = None
    stroke_type: Literal["ischaemic", "haemorrhagic", "undetermined"] | None = None
    bleeding_site: str | None = Field(None, max_length=200)
    pci_procedure_id: uuid.UUID | None = None
    target_lesion_id: uuid.UUID | None = None
    potassium_mmol_l: float | None = Field(None, ge=1, le=10)
    creatinine_result_id: uuid.UUID | None = None
    source: Literal["site_clinician", "patient_report", "relative_report", "hospital_records", "death_certificate",
                    "follow_up_call", "imported"]
    source_document_id: uuid.UUID | None = None

    @model_validator(mode="after")
    def _dates(self):
        if self.event_date > date.today():
            raise ValueError("event_date cannot be in the future")
        if self.discharge_date and self.admission_date and self.discharge_date < self.admission_date:
            raise ValueError("discharge_date is before admission_date")
        return self


class NewEvent(EventDetails):
    patient_id: uuid.UUID
    event_type: EventType

    @model_validator(mode="after")
    def _type_rules(self):
        if self.event_type == "death" and self.death_cause is None:
            raise ValueError("a death needs death_cause")
        if self.event_type in HOSPITAL_TYPES and self.hospitalised is False:
            raise ValueError(f"{self.event_type} means hospitalised = true")
        return self


EVENT_FIELDS = ["patient_id", "event_type", *EventDetails.model_fields]


def event_out(row: dict) -> dict:
    return _jsonable({k: row[k] for k in ("event_id", *EVENT_FIELDS, "reported_by", "status", "created_at",
                                          "row_version")})


def adjudication_out(r: dict) -> dict:
    out = {k: r.get(k) for k in (
        "adjudication_id", "event_id", "protocol_code", "endpoint_code", "endpoint_label", "classification_system",
        "qualifying_classifications", "event_type", "event_date", "event_day", "adjudication_status",
        "classification", "meets_endpoint", "adjudicated_by", "adjudicated_at", "committee_reference", "notes",
        "centre_code", "study_subject_code", "patient_id", "row_version")}
    out["event"] = {k: r.get(k) for k in (
        "event_date_precision", "description", "hospitalised", "admission_date", "discharge_date", "facility_name",
        "severity", "outcome", "death_cause", "death_cv_mode", "mi_type", "stroke_type", "bleeding_site",
        "pci_procedure_id", "target_lesion_id", "source", "event_status", "reported_by", "reported_at")}
    return _jsonable(out)


def _adjudications_for(ctx: Ctx, event_id) -> list[dict]:
    if ctx.role not in REGISTRY_ROLES:
        return []      # nurses report events but have no access to registry adjudication
    return [adjudication_out(r) for r in ctx.all(
        "SELECT * FROM registry.v_adjudication_queue WHERE event_id = %s ORDER BY protocol_code, endpoint_code",
        (event_id,))]


@router.post("/events", status_code=201)
def report_event(body: NewEvent, idempotency_key: str = Header(...), ctx: Ctx = Depends(REPORTERS)):
    idem = Idempotency(ctx, idempotency_key, body.model_dump(mode="json"))
    if (prev := idem.previous()) is not None:
        return _replay(prev)
    if ctx.one("SELECT 1 FROM clinical.patient_registrations WHERE patient_id = %s", (body.patient_id,)) is None:
        raise Problem(404, "NOT_FOUND", "Patient not found at this centre")
    values = body.model_dump()
    if body.event_type in HOSPITAL_TYPES:
        values["hospitalised"] = True
    cols = ["centre_id", *values]
    row = ctx.one(sql.SQL("INSERT INTO clinical.clinical_events ({}) VALUES ({}) RETURNING *").format(
        sql.SQL(", ").join(map(sql.Identifier, cols)), sql.SQL(", ").join(sql.Placeholder() * len(cols))),
        [ctx.centre_id, *values.values()])
    out = {"event": event_out(row), "adjudications": _adjudications_for(ctx, row["event_id"])}
    idem.store(201, out)
    return JSONResponse(out, status_code=201, headers={"ETag": etag(row["row_version"]),
                                                      "Location": f"/api/v1/events/{row['event_id']}"})


@router.get("/events/{event_id}")
def get_event(event_id: uuid.UUID, response: Response, ctx: Ctx = Depends(READERS)):
    row = ctx.one("SELECT * FROM clinical.clinical_events WHERE event_id = %s", (event_id,))
    if row is None:
        raise Problem(404, "NOT_FOUND", "Event not found")
    ctx.log_access("patient_record_view", row["patient_id"], "clinical.clinical_events", event_id)
    response.headers["ETag"] = etag(row["row_version"])
    return {"event": event_out(row), "adjudications": _adjudications_for(ctx, event_id)}


@router.get("/patients/{patient_id}/events")
def list_patient_events(patient_id: uuid.UUID, include_entered_in_error: bool = False,
                        ctx: Ctx = Depends(READERS)):
    rows = ctx.all("SELECT * FROM clinical.clinical_events WHERE patient_id = %s "
                   "AND (%s OR status <> 'entered_in_error') ORDER BY event_date, created_at",
                   (patient_id, include_entered_in_error))
    if rows:
        ctx.log_access("patient_record_view", patient_id, "clinical.clinical_events", "list")
    return {"items": [event_out(r) for r in rows]}


class EventCorrection(EventDetails):
    """Full replacement of the event's details.  The type and patient never change: to correct
    them, set status entered_in_error and report the event again."""
    status: Literal["reported", "source_verified", "entered_in_error"] = "reported"


@router.put("/events/{event_id}")
def correct_event(event_id: uuid.UUID, body: EventCorrection, response: Response, if_match: str = Header(...),
                  ctx: Ctx = Depends(CORRECTORS)):
    require_change_reason(ctx)
    cur = ctx.one("SELECT event_type FROM clinical.clinical_events WHERE event_id = %s", (event_id,))
    if cur is None:
        raise Problem(404, "NOT_FOUND", "Event not found")
    changes = body.model_dump()
    if cur["event_type"] in HOSPITAL_TYPES:
        changes["hospitalised"] = True
    row = _versioned_update(ctx, "clinical.clinical_events", "event_id", event_id, if_match, changes)
    response.headers["ETag"] = etag(row["row_version"])
    return {"event": event_out(row), "adjudications": _adjudications_for(ctx, event_id)}


class AdjudicationDecision(Strict):
    adjudication_status: Literal["in_review", "adjudicated", "not_an_event", "insufficient_data"]
    endpoint_code: str | None = None
    classification: str | None = Field(None, max_length=60)
    meets_endpoint: bool | None = None
    committee_reference: str | None = Field(None, max_length=200)
    notes: str | None = Field(None, max_length=4000)

    @model_validator(mode="after")
    def _rules(self):
        if self.adjudication_status == "adjudicated" and self.meets_endpoint is None and self.classification is None:
            raise ValueError("an adjudicated event needs meets_endpoint or a classification that decides it")
        return self


@router.put("/events/{event_id}/adjudications/{adjudication_id}")
def adjudicate(event_id: uuid.UUID, adjudication_id: uuid.UUID, body: AdjudicationDecision, response: Response,
               if_match: str = Header(...), ctx: Ctx = Depends(ADJUDICATORS)):
    cur = ctx.one("SELECT * FROM registry.v_adjudication_queue WHERE adjudication_id = %s AND event_id = %s",
                  (adjudication_id, event_id))
    if cur is None:
        raise Problem(404, "NOT_FOUND", "Adjudication not found")
    if body.endpoint_code is not None and body.endpoint_code != cur["endpoint_code"]:
        raise Problem(422, "PROTOCOL_MISMATCH", "This adjudication is for another endpoint",
                      detail=f"adjudication is for {cur['endpoint_code']}")
    # meets_endpoint left empty is derived by the database from the classification when the endpoint
    # lists qualifying classifications; otherwise an adjudicated decision must state it.
    changes = body.model_dump(exclude={"endpoint_code"})
    _versioned_update(ctx, "registry.event_adjudications", "adjudication_id", adjudication_id, if_match, changes)
    row = ctx.one("SELECT * FROM registry.v_adjudication_queue WHERE adjudication_id = %s", (adjudication_id,))
    response.headers["ETag"] = etag(row["row_version"])
    return adjudication_out(row)


@router.get("/protocols/{protocol_id}/adjudication-queue")
def adjudication_queue(protocol_id: uuid.UUID,
                       status: Literal["pending", "in_review", "insufficient_data", "adjudicated",
                                       "not_an_event"] = "pending",
                       limit: int = Query(50, ge=1, le=200), cursor: str | None = None,
                       ctx: Ctx = Depends(QUEUE_READERS)):
    after_date, after_id = None, None
    if cursor:
        d, _, i = cursor.partition("|")
        try:
            after_date, after_id = date.fromisoformat(d), uuid.UUID(i)
        except ValueError:
            raise Problem(400, "VALIDATION_FAILED", "Invalid cursor") from None
    rows = ctx.all("""
        SELECT * FROM registry.v_adjudication_queue
         WHERE protocol_id = %s AND adjudication_status = %s
           AND (%s::date IS NULL OR (event_date, adjudication_id) > (%s, %s))
         ORDER BY event_date, adjudication_id LIMIT %s""",
        (protocol_id, status, after_date, after_date, after_id, limit + 1))
    more = len(rows) > limit
    rows = rows[:limit]
    return {"items": [adjudication_out(r) for r in rows],
            "next_cursor": f"{rows[-1]['event_date'].isoformat()}|{rows[-1]['adjudication_id']}" if more else None}


@router.get("/adjudication-classifications")
def list_classifications(ctx: Ctx = Depends(QUEUE_READERS)):
    """Classification codes per system (BARC, ARC-2, UDMI-4, HF-ARC, custom), for the adjudication form."""
    rows = ctx.all("SELECT classification_system, code, label FROM ref.adjudication_classifications "
                   "ORDER BY classification_system, code")
    return {"items": rows}
