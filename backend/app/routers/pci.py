"""PCI procedures with their lesions and stents, recorded and read as one document."""
from __future__ import annotations

import uuid
from datetime import date
from typing import Literal

from fastapi import APIRouter, Depends, Header, Response
from fastapi.responses import JSONResponse
from psycopg import sql
from pydantic import BaseModel, ConfigDict, Field, model_validator

from ..context import Ctx, Idempotency, etag, parse_if_match, require_change_reason, roles
from ..errors import Problem
from .enrolment import _jsonable, _replay

router = APIRouter(tags=["CAD"])
WRITERS = roles("clinician")
READERS = roles("clinician", "research_coordinator", "principal_investigator", "nurse")

Vessel = Literal["LM", "LAD", "LCX", "RCA", "RAMUS", "DIAGONAL", "OM", "PDA", "PLV", "SVG", "LIMA", "RIMA",
                 "RADIAL_GRAFT"]


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Stent(Strict):
    sequence_number: int = Field(ge=1, le=20)
    stent_device_id: uuid.UUID | None = None
    device_text: str | None = Field(None, max_length=200)
    diameter_mm: float = Field(ge=1.5, le=6.0)
    length_mm: float = Field(ge=6, le=60)
    deployment_atm: int | None = Field(None, ge=4, le=30)
    post_dilatation_balloon_mm: float | None = None

    @model_validator(mode="after")
    def _device(self):
        if self.stent_device_id is None and not self.device_text:
            raise ValueError("give stent_device_id or device_text")
        return self


class Lesion(Strict):
    lesion_number: int = Field(ge=1, le=20)
    vessel: Vessel
    segment_code: str | None = Field(None, max_length=10)
    lesion_type_acc_aha: Literal["A", "B1", "B2", "C"] | None = None
    lesion_length_mm: float | None = Field(None, ge=1, le=200)
    reference_diameter_mm: float | None = Field(None, ge=1.5, le=7.0)
    pre_stenosis_pct: int | None = Field(None, ge=0, le=100)
    pre_timi_flow: int | None = Field(None, ge=0, le=3)
    calcification: Literal["none", "mild", "moderate", "severe"] | None = None
    is_cto: bool = False
    j_cto_score: int | None = Field(None, ge=0, le=5)
    is_bifurcation: bool = False
    medina: str | None = Field(None, pattern=r"^[01],[01],[01]$")
    bifurcation_technique: Literal["provisional", "TAP", "culotte", "DK_crush", "mini_crush", "T_stenting",
                                   "V_stenting", "other"] | None = None
    is_in_stent_restenosis: bool = False
    thrombus: bool | None = None
    lesion_preparation: list[Literal["predilatation", "cutting_balloon", "scoring_balloon", "rotational_atherectomy",
                                     "orbital_atherectomy", "IVL", "laser"]] | None = None
    post_dilatation: bool | None = None
    pre_physiology_value: float | None = None
    post_physiology_value: float | None = None
    final_timi_flow: int | None = Field(None, ge=0, le=3)
    residual_stenosis_pct: int | None = Field(None, ge=0, le=100)
    treatment: Literal["stent", "DCB", "POBA", "failed", "deferred_by_physiology"]
    stents: list[Stent] = Field(default_factory=list, max_length=10)

    @model_validator(mode="after")
    def _rules(self):
        if self.is_bifurcation and not self.medina:
            raise ValueError("a bifurcation lesion needs its Medina class")
        if self.j_cto_score is not None and not self.is_cto:
            raise ValueError("j_cto_score applies to CTO lesions only")
        if self.treatment == "stent" and not self.stents:
            raise ValueError("treatment 'stent' needs at least one stent")
        if self.treatment != "stent" and self.stents:
            raise ValueError("stents are recorded only when treatment is 'stent'")
        if len({s.sequence_number for s in self.stents}) != len(self.stents):
            raise ValueError("stent sequence numbers must be unique within a lesion")
        return self


class Procedure(Strict):
    encounter_id: uuid.UUID | None = None
    angiogram_investigation_id: uuid.UUID | None = None
    procedure_date: date
    performed_at_facility: str | None = Field(None, max_length=200)
    indication: Literal["primary_pci_stemi", "pharmacoinvasive", "rescue_pci", "nstemi", "unstable_angina",
                        "chronic_coronary_syndrome", "staged", "silent_ischaemia", "other"]
    urgency: Literal["elective", "urgent", "emergency", "salvage"] | None = None
    access_site: Literal["radial", "distal_radial", "femoral", "brachial", "ulnar"] | None = None
    operator_name: str | None = Field(None, max_length=200)
    imaging_guidance: Literal["none", "IVUS", "OCT", "IVUS_and_OCT"] = "none"
    physiology: Literal["none", "FFR", "iFR", "RFR", "QFR", "other"] = "none"
    mechanical_support: Literal["none", "IABP", "Impella", "ECMO"] | None = None
    contrast_ml: int | None = Field(None, ge=0, le=2000)
    fluoroscopy_min: float | None = Field(None, ge=0, le=600)
    procedural_success: bool | None = None
    complications: list[Literal["none", "dissection", "perforation", "no_reflow", "side_branch_occlusion",
                                "acute_stent_thrombosis", "access_bleeding", "haematoma", "pseudoaneurysm",
                                "contrast_nephropathy", "arrhythmia", "stroke", "death", "other"]] | None = None
    source: Literal["manual", "ai_extracted", "imported"] = "manual"
    source_document_id: uuid.UUID | None = None
    status: Literal["draft", "final", "entered_in_error"] = "final"
    lesions: list[Lesion] = Field(min_length=1, max_length=20)

    @model_validator(mode="after")
    def _rules(self):
        if len({x.lesion_number for x in self.lesions}) != len(self.lesions):
            raise ValueError("lesion numbers must be unique within a procedure")
        if self.procedure_date > date.today():
            raise ValueError("procedure_date cannot be in the future")
        return self


PROC_FIELDS = [f for f in Procedure.model_fields if f != "lesions"]
LESION_FIELDS = [f for f in Lesion.model_fields if f != "stents"]
STENT_FIELDS = list(Stent.model_fields)


def _insert(ctx: Ctx, table: str, values: dict, returning: str) -> dict:
    cols = list(values)
    return ctx.one(sql.SQL("INSERT INTO {} ({}) VALUES ({}) RETURNING {}").format(
        sql.SQL(table), sql.SQL(", ").join(map(sql.Identifier, cols)),
        sql.SQL(", ").join(sql.Placeholder() * len(cols)), sql.Identifier(returning)), [values[c] for c in cols])


def _update(ctx: Ctx, table: str, pk: str, pk_value, values: dict) -> None:
    ctx.conn.execute(sql.SQL("UPDATE {} SET {} WHERE {} = %s").format(
        sql.SQL(table), sql.SQL(", ").join(sql.SQL("{} = %s").format(sql.Identifier(c)) for c in values),
        sql.Identifier(pk)), [*values.values(), pk_value])


def _owner(ctx: Ctx) -> dict:
    return {"centre_id": ctx.centre_id}


def _write_children(ctx: Ctx, procedure_id, patient_id, lesions: list[Lesion], existing: dict | None = None) -> None:
    """Insert or update lesions and stents.  existing: lesion_number -> {lesion_id, stents: {seq: stent_id}}."""
    existing = existing or {}
    for lesion in lesions:
        values = lesion.model_dump(include=set(LESION_FIELDS))
        prior = existing.get(lesion.lesion_number)
        if prior is None:
            lesion_id = _insert(ctx, "clinical.pci_lesions", {"procedure_id": procedure_id, "patient_id": patient_id,
                                                             **_owner(ctx), **values}, "lesion_id")["lesion_id"]
            prior_stents = {}
        else:
            lesion_id, prior_stents = prior["lesion_id"], prior["stents"]
            _update(ctx, "clinical.pci_lesions", "lesion_id", lesion_id, values)
        for stent in lesion.stents:
            sv = stent.model_dump()
            if stent.sequence_number in prior_stents:
                _update(ctx, "clinical.pci_stents", "stent_id", prior_stents[stent.sequence_number], sv)
            else:
                _insert(ctx, "clinical.pci_stents", {"lesion_id": lesion_id, "patient_id": patient_id,
                                                     **_owner(ctx), **sv}, "stent_id")


def procedure_out(ctx: Ctx, procedure_id) -> dict | None:
    p = ctx.one("SELECT * FROM clinical.pci_procedures WHERE procedure_id = %s", (procedure_id,))
    if p is None:
        return None
    lesions = ctx.all("SELECT * FROM clinical.pci_lesions WHERE procedure_id = %s ORDER BY lesion_number",
                      (procedure_id,))
    stents = ctx.all("""SELECT s.*, d.display_name AS device_name, d.device_type
                          FROM clinical.pci_stents s JOIN clinical.pci_lesions l USING (lesion_id)
                          LEFT JOIN ref.v_stent_catalogue d USING (stent_device_id)
                         WHERE l.procedure_id = %s ORDER BY s.sequence_number""", (procedure_id,))
    out = {k: p[k] for k in ("procedure_id", "patient_id", *PROC_FIELDS, "row_version")}
    out["lesions"] = [{"lesion_id": l["lesion_id"], **{k: l[k] for k in LESION_FIELDS},
                       "stents": [{"stent_id": s["stent_id"], **{k: s[k] for k in STENT_FIELDS},
                                   "device_name": s["device_name"], "device_type": s["device_type"]}
                                  for s in stents if s["lesion_id"] == l["lesion_id"]]} for l in lesions]
    return _jsonable(out)


@router.get("/stent-devices")
def list_stent_devices(include_retired: bool = False, ctx: Ctx = Depends(READERS)):
    """The stent catalogue for the PCI form, in picker order.  A stent not in it is recorded by
    device_text.  Retired devices are listed only on request (to show on older records)."""
    rows = ctx.all("""SELECT stent_device_id, manufacturer, platform_name, display_name, device_type, drug,
                             strut_material, polymer_type, polymer, strut_thickness_min_um, strut_thickness_max_um,
                             aliases, review_status, status
                        FROM ref.v_stent_catalogue WHERE %s OR status = 'active'
                       ORDER BY sort_order, platform_name""", (include_retired,))
    return {"items": _jsonable(rows)}


@router.post("/patients/{patient_id}/pci-procedures", status_code=201)
def create_procedure(patient_id: uuid.UUID, body: Procedure, idempotency_key: str = Header(...),
                     ctx: Ctx = Depends(WRITERS)):
    idem = Idempotency(ctx, idempotency_key, body.model_dump(mode="json"))
    if (prev := idem.previous()) is not None:
        return _replay(prev)
    if ctx.one("SELECT 1 FROM clinical.patient_registrations WHERE patient_id = %s", (patient_id,)) is None:
        raise Problem(404, "NOT_FOUND", "Patient not found at this centre")
    pid = _insert(ctx, "clinical.pci_procedures", {"patient_id": patient_id, **_owner(ctx),
                                                    **body.model_dump(include=set(PROC_FIELDS))},
                  "procedure_id")["procedure_id"]
    _write_children(ctx, pid, patient_id, body.lesions)
    out = procedure_out(ctx, pid)
    idem.store(201, out)
    return JSONResponse(out, status_code=201, headers={"ETag": etag(out["row_version"]),
                                                      "Location": f"/api/v1/pci-procedures/{pid}"})


@router.get("/patients/{patient_id}/pci-procedures")
def list_procedures(patient_id: uuid.UUID, ctx: Ctx = Depends(READERS)):
    ids = ctx.all("SELECT procedure_id FROM clinical.pci_procedures WHERE patient_id = %s "
                  "ORDER BY procedure_date DESC, created_at DESC", (patient_id,))
    if ids:
        ctx.log_access("patient_record_view", patient_id, "clinical.pci_procedures", "list")
    return {"items": [procedure_out(ctx, r["procedure_id"]) for r in ids]}


@router.get("/pci-procedures/{procedure_id}")
def get_procedure(procedure_id: uuid.UUID, response: Response, ctx: Ctx = Depends(READERS)):
    out = procedure_out(ctx, procedure_id)
    if out is None:
        raise Problem(404, "NOT_FOUND", "PCI procedure not found")
    ctx.log_access("patient_record_view", out["patient_id"], "clinical.pci_procedures", procedure_id)
    response.headers["ETag"] = etag(out["row_version"])
    return out


@router.put("/pci-procedures/{procedure_id}")
def replace_procedure(procedure_id: uuid.UUID, body: Procedure, response: Response, if_match: str = Header(...),
                      ctx: Ctx = Depends(WRITERS)):
    """Replace the procedure document.  Lesions and stents are matched by lesion_number and
    sequence_number; one that is left out is refused, since recorded lesions are not deleted.
    To withdraw a procedure, set status to entered_in_error."""
    version = parse_if_match(if_match)
    cur = ctx.one("SELECT * FROM clinical.pci_procedures WHERE procedure_id = %s FOR UPDATE", (procedure_id,))
    if cur is None:
        raise Problem(404, "NOT_FOUND", "PCI procedure not found")
    if cur["row_version"] != version:
        raise Problem(412, "STALE_VERSION", "The procedure changed since you read it",
                      current=procedure_out(ctx, procedure_id))
    if cur["status"] in ("final", "entered_in_error"):
        require_change_reason(ctx)
    existing: dict[int, dict] = {}
    for l in ctx.all("SELECT lesion_id, lesion_number FROM clinical.pci_lesions WHERE procedure_id = %s",
                     (procedure_id,)):
        existing[l["lesion_number"]] = {"lesion_id": l["lesion_id"], "stents": {}}
    for s in ctx.all("""SELECT s.stent_id, s.sequence_number, l.lesion_number FROM clinical.pci_stents s
                          JOIN clinical.pci_lesions l USING (lesion_id) WHERE l.procedure_id = %s""", (procedure_id,)):
        existing[s["lesion_number"]]["stents"][s["sequence_number"]] = s["stent_id"]
    sent = {l.lesion_number: {s.sequence_number for s in l.stents} for l in body.lesions}
    missing = [f"lesion {n}" for n in existing if n not in sent]
    missing += [f"lesion {n} stent {q}" for n, e in existing.items() if n in sent
                for q in e["stents"] if q not in sent[n]]
    if missing:
        raise Problem(422, "VALIDATION_FAILED", "Recorded lesions and stents cannot be removed",
                      detail="Send every recorded lesion and stent; to withdraw the procedure set status "
                             "entered_in_error", errors=[{"field": m, "rule": "no_removal", "message": "missing"}
                                                         for m in missing])
    _update(ctx, "clinical.pci_procedures", "procedure_id", procedure_id, body.model_dump(include=set(PROC_FIELDS)))
    _write_children(ctx, procedure_id, cur["patient_id"], body.lesions, existing)
    out = procedure_out(ctx, procedure_id)
    response.headers["ETag"] = etag(out["row_version"])
    return out
