"""Consent: record a patient's consent at this centre and record its withdrawal.

Research registry consent names the protocol it covers and is recorded by registry staff;
withdrawing it ends any enrolment that relies on it (database trigger)."""
from __future__ import annotations

import uuid
from datetime import date
from typing import Literal

from fastapi import APIRouter, Depends, Header
from fastapi.responses import JSONResponse
from psycopg import sql
from pydantic import BaseModel, ConfigDict, Field, model_validator

from ..context import Ctx, Idempotency, etag, require_change_reason, roles
from ..errors import Problem
from .enrolment import _jsonable, _replay, _versioned_update

router = APIRouter(tags=["Patients"])
FRONT_DESK = ("assistant", "nurse", "clinician", "research_coordinator", "principal_investigator")
WRITERS = roles(*FRONT_DESK)
REGISTRY_STAFF = {"clinician", "research_coordinator", "principal_investigator"}
COLS = ("consent_id", "patient_id", "consent_type", "protocol_id", "consent_form_version", "consent_language",
        "consent_date", "consent_method", "signed_by", "lar_name", "lar_relation", "witness_name", "consent_status",
        "withdrawal_date", "withdrawal_scope", "withdrawal_reason", "row_version")


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class NewConsent(Strict):
    consent_type: Literal["clinical_care", "research_registry", "cross_centre_linkage", "external_data_sharing",
                          "ai_processing", "recontact"]
    protocol_id: uuid.UUID | None = Field(None, description="Required for research_registry, and only then")
    consent_form_version: str = Field(min_length=1, max_length=50)
    consent_language: str | None = Field(None, max_length=40)
    consent_date: date
    consent_method: Literal["written", "electronic", "audio_video", "verbal_witnessed", "waiver_approved"]
    signed_by: Literal["patient", "legally_authorised_rep"] = "patient"
    lar_name: str | None = Field(None, max_length=200)
    lar_relation: str | None = Field(None, max_length=100)
    witness_name: str | None = Field(None, max_length=200)
    consent_status: Literal["active", "refused"] = "active"

    @model_validator(mode="after")
    def _shape(self):
        if (self.consent_type == "research_registry") != (self.protocol_id is not None):
            raise ValueError("protocol_id is required for research registry consent, and only for it")
        if self.signed_by == "legally_authorised_rep" and not self.lar_name:
            raise ValueError("lar_name is required when a representative signs")
        if self.consent_date > date.today():
            raise ValueError("consent_date is in the future")
        return self


class Withdrawal(Strict):
    withdrawal_date: date
    withdrawal_scope: Literal["no_further_contact", "no_further_collection", "exclude_collected_data"]
    withdrawal_reason: str | None = Field(None, max_length=500)


def _out(ctx: Ctx, consent_id) -> dict:
    row = ctx.one(f"SELECT {', '.join(COLS)} FROM clinical.patient_consents WHERE consent_id = %s", (consent_id,))
    if row is None:
        raise Problem(404, "NOT_FOUND", "Consent not found")
    row["protocol_code"] = None
    if row["protocol_id"] and ctx.role in REGISTRY_STAFF:   # other roles have no access to protocols
        row["protocol_code"] = ctx.one("SELECT protocol_code FROM registry.registry_protocols WHERE protocol_id = %s",
                                       (row["protocol_id"],))["protocol_code"]
    return _jsonable(row)


@router.post("/patients/{patient_id}/consents", status_code=201)
def record_consent(patient_id: uuid.UUID, body: NewConsent, idempotency_key: str = Header(...),
                   ctx: Ctx = Depends(WRITERS)):
    if body.consent_type == "research_registry" and ctx.role not in REGISTRY_STAFF:
        raise Problem(403, "FORBIDDEN", "Research consent is recorded by a clinician or the research team")
    idem = Idempotency(ctx, idempotency_key, body.model_dump(mode="json"))
    if (prev := idem.previous()) is not None:
        return _replay(prev)
    reg = ctx.one("SELECT organisation_id FROM clinical.patient_registrations WHERE patient_id = %s AND centre_id = %s "
                  "AND status <> 'entered_in_error'", (patient_id, ctx.centre_id))
    if reg is None:
        raise Problem(404, "NOT_FOUND", "Patient not found at this centre")
    if body.protocol_id and ctx.one("SELECT 1 FROM registry.registry_protocols WHERE protocol_id = %s",
                                    (body.protocol_id,)) is None:
        raise Problem(422, "VALIDATION_FAILED", "Unknown protocol", detail=str(body.protocol_id))
    if body.consent_status == "active" and ctx.one(
            "SELECT 1 FROM clinical.patient_consents WHERE patient_id = %s AND centre_id = %s AND consent_type = %s "
            "AND protocol_id IS NOT DISTINCT FROM %s AND consent_status = 'active'",
            (patient_id, ctx.centre_id, body.consent_type, body.protocol_id)):
        raise Problem(409, "CONFLICT", "An active consent of this kind is already recorded")
    consent_id = uuid.uuid4()
    data = body.model_dump()
    cols = ["consent_id", "patient_id", "organisation_id", "centre_id", *data]
    ctx.conn.execute(
        f"INSERT INTO clinical.patient_consents ({', '.join(cols)}) VALUES ({', '.join(['%s'] * len(cols))})",
        (consent_id, patient_id, reg["organisation_id"], ctx.centre_id, *data.values()))
    out = _out(ctx, consent_id)
    idem.store(201, out)
    return JSONResponse(out, status_code=201, headers={"ETag": etag(out["row_version"])})


@router.post("/consents/{consent_id}/withdraw")
def withdraw_consent(consent_id: uuid.UUID, body: Withdrawal, if_match: str = Header(...),
                     ctx: Ctx = Depends(WRITERS)):
    require_change_reason(ctx)
    current = _out(ctx, consent_id)
    if current["consent_type"] == "research_registry" and ctx.role not in REGISTRY_STAFF:
        raise Problem(403, "FORBIDDEN", "Research consent is withdrawn by a clinician or the research team")
    if body.withdrawal_date > date.today() or body.withdrawal_date < date.fromisoformat(current["consent_date"]):
        raise Problem(422, "VALIDATION_FAILED", "Withdrawal date must be between the consent date and today")
    _versioned_update(ctx, "clinical.patient_consents", "consent_id", consent_id, if_match,
                      {"consent_status": "withdrawn", **body.model_dump()},
                      where_extra=sql.SQL("consent_status = 'active'"))
    out = _out(ctx, consent_id)
    return JSONResponse(out, headers={"ETag": etag(out["row_version"])})
