"""Heart-failure GDMT matrix and lipid target attainment for one assessment."""
from __future__ import annotations

import uuid
from typing import Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field, model_validator

from ..context import Ctx, roles
from ..errors import Problem
from ..prefill import Chart, dose_status
from .enrolment import _jsonable

router = APIRouter()
STAFF = roles("clinician", "research_coordinator", "principal_investigator")
PILLARS = ("RASI", "BB", "MRA", "SGLT2I")
REASON_CODES = Literal["contraindication", "intolerance", "hypotension", "hyperkalaemia", "renal_dysfunction",
                       "bradycardia", "worsening_hf", "patient_refusal", "financial", "drug_unavailable",
                       "titration_in_progress", "recently_initiated", "not_indicated_for_phenotype", "other"]


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


def _assessment(ctx: Ctx, assessment_id, registry: str | None = None) -> dict:
    a = ctx.one("""SELECT a.*, t.registry_code FROM registry.assessments a
                     JOIN registry.enrolments e USING (enrolment_id)
                     JOIN registry.registry_types t ON t.registry_type_id = e.registry_type_id
                    WHERE a.assessment_id = %s""", (assessment_id,))
    if a is None:
        raise Problem(404, "NOT_FOUND", "Assessment not found")
    if registry and a["registry_code"] != registry:
        raise Problem(409, "CONFLICT", f"This applies to {registry} registry assessments only",
                      detail=a["registry_code"])
    return a


def _rule_set(ctx: Ctx, rule_set_id) -> dict:
    return ctx.one("SELECT rule_set_id, rule_set_code, version, status FROM ref.rule_sets WHERE rule_set_id = %s",
                   (rule_set_id,))


# --- HF: GDMT --------------------------------------------------------------------

def _stored_reasons(ctx: Ctx, assessment_id) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {}
    for r in ctx.all("SELECT pillar_code, reason_code, detail FROM registry.hf_gdmt_reasons WHERE assessment_id = %s "
                     "ORDER BY pillar_code, reason_code", (assessment_id,)):
        out.setdefault(r["pillar_code"], []).append(r)
    return out


def _gdmt_out(a: dict, rule: dict, phenotype, pillars: list[dict], reasons: dict[str, list[dict]],
              stored: bool) -> dict:
    items = []
    for p in pillars:
        codes = [r["reason_code"] for r in reasons.get(p["pillar_code"], [])]
        items.append({"pillar": p["pillar_code"], "drug_code": p.get("drug_code"), "daily_dose": p["daily_dose"],
                      "target_daily_dose": p["target_daily_dose"], "pct_of_target": p["pct_target_dose"],
                      "eligible": p["eligible"], "prescribed": p["prescribed"],
                      "dose_status": p.get("dose_status") or dose_status(p, set(codes)),
                      "source": p.get("source", "engine"), "reasons": codes,
                      "initiation_date": p["initiation_date"], "last_titration_date": p["last_titration_date"]})
    return _jsonable({
        "as_of": a["assessment_date"], "rule_set": f"{rule['rule_set_code']} v{rule['version']}",
        "rule_set_status": rule["status"], "hf_phenotype": phenotype, "stored": stored, "pillars": items,
        "pillars_eligible": sum(1 for i in items if i["eligible"]),
        "pillars_on_treatment": sum(1 for i in items if i["prescribed"]),
        "pillars_at_target": sum(1 for i in items if i["dose_status"] == "at_target")})


def _live(ctx: Ctx, a: dict):
    chart = Chart(ctx, a)
    rule_id = chart.enrolment["hf_target_dose_rule_set_id"]
    if rule_id is None:
        raise Problem(409, "CONFLICT", "This protocol has no HF target-dose rule set")
    phenotype = chart.phenotype()
    if phenotype is None:
        raise Problem(422, "VALIDATION_FAILED", "HF phenotype is unknown for this assessment")
    return chart, _rule_set(ctx, rule_id), phenotype, [chart.gdmt()[p] for p in PILLARS]


@router.get("/assessments/{assessment_id}/hf/gdmt", tags=["Heart failure"])
def get_gdmt(assessment_id: uuid.UUID, ctx: Ctx = Depends(STAFF)):
    a = _assessment(ctx, assessment_id, "HF")
    reasons = _stored_reasons(ctx, assessment_id)
    if a["locked_at"] is not None:
        rows = ctx.all("""SELECT s.*, d.drug_code FROM registry.hf_gdmt_status s
                            LEFT JOIN ref.drugs d USING (drug_id)
                            JOIN ref.gdmt_pillars p USING (pillar_code)
                           WHERE s.assessment_id = %s ORDER BY p.sort_order""", (assessment_id,))
        if rows:
            phenotype = Chart(ctx, a).phenotype()
            return _gdmt_out(a, _rule_set(ctx, rows[0]["rule_set_id"]), phenotype, rows, reasons, stored=True)
    _, rule, phenotype, pillars = _live(ctx, a)
    return _gdmt_out(a, rule, phenotype, pillars, reasons, stored=False)


class GdmtReason(Strict):
    pillar: Literal["RASI", "BB", "MRA", "SGLT2I"]
    reason_code: REASON_CODES
    detail: str | None = Field(None, max_length=500)

    @model_validator(mode="after")
    def _other_needs_detail(self):
        if self.reason_code == "other" and not self.detail:
            raise ValueError("detail is required when reason_code is other")
        return self


class GdmtReasons(Strict):
    reasons: list[GdmtReason] = Field(max_length=56)


@router.put("/assessments/{assessment_id}/hf/gdmt", tags=["Heart failure"])
def save_gdmt(assessment_id: uuid.UUID, body: GdmtReasons, ctx: Ctx = Depends(STAFF)):
    """Store the engine's snapshot for the assessment date and add reasons.  Reasons are
    append-only in the database, so a reason stored earlier cannot be dropped here."""
    a = _assessment(ctx, assessment_id, "HF")
    if a["locked_at"] is not None:
        raise Problem(422, "ASSESSMENT_LOCKED", "Assessment is locked")
    _, rule, phenotype, pillars = _live(ctx, a)
    wanted: dict[str, dict[str, str | None]] = {}
    for r in body.reasons:
        wanted.setdefault(r.pillar, {})[r.reason_code] = r.detail
    stored = _stored_reasons(ctx, assessment_id)
    dropped = [{"field": f"{p}.{r['reason_code']}", "rule": "append_only",
                "message": "A stored reason cannot be removed"}
               for p, rs in stored.items() for r in rs if r["reason_code"] not in wanted.get(p, {})]
    if dropped:
        raise Problem(409, "CONFLICT", "Stored GDMT reasons are append-only; send them again with any new ones",
                      errors=dropped)
    for p in pillars:
        status = dose_status(p, set(wanted.get(p["pillar_code"], {})))
        ctx.conn.execute("""
            INSERT INTO registry.hf_gdmt_status (assessment_id, pillar_code, patient_id, centre_id, eligible,
                   prescribed, course_id, drug_id, daily_dose, target_daily_dose, pct_target_dose, evidence_based_drug,
                   initiation_date, last_titration_date, dose_status, rule_set_id)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (assessment_id, pillar_code) DO UPDATE SET
                   eligible = EXCLUDED.eligible, prescribed = EXCLUDED.prescribed, course_id = EXCLUDED.course_id,
                   drug_id = EXCLUDED.drug_id, daily_dose = EXCLUDED.daily_dose,
                   target_daily_dose = EXCLUDED.target_daily_dose, pct_target_dose = EXCLUDED.pct_target_dose,
                   evidence_based_drug = EXCLUDED.evidence_based_drug, initiation_date = EXCLUDED.initiation_date,
                   last_titration_date = EXCLUDED.last_titration_date, dose_status = EXCLUDED.dose_status,
                   rule_set_id = EXCLUDED.rule_set_id
             WHERE registry.hf_gdmt_status.source = 'engine'""",
            (assessment_id, p["pillar_code"], a["patient_id"], ctx.centre_id, p["eligible"], p["prescribed"],
             p["course_id"], p["drug_id"], p["daily_dose"], p["target_daily_dose"], p["pct_target_dose"],
             p["evidence_based_drug"], p["initiation_date"], p["last_titration_date"], status, rule["rule_set_id"]))
        have = {r["reason_code"] for r in stored.get(p["pillar_code"], [])}
        for code, detail in wanted.get(p["pillar_code"], {}).items():
            if code not in have:
                ctx.conn.execute("""INSERT INTO registry.hf_gdmt_reasons (assessment_id, pillar_code, reason_code,
                                      detail, patient_id, centre_id) VALUES (%s, %s, %s, %s, %s, %s)""",
                                 (assessment_id, p["pillar_code"], code, detail, a["patient_id"], ctx.centre_id))
    rows = ctx.all("""SELECT s.*, d.drug_code FROM registry.hf_gdmt_status s LEFT JOIN ref.drugs d USING (drug_id)
                        JOIN ref.gdmt_pillars g USING (pillar_code) WHERE s.assessment_id = %s
                       ORDER BY g.sort_order""", (assessment_id,))
    out = _gdmt_out(a, rule, phenotype, rows, _stored_reasons(ctx, assessment_id), stored=True)
    ctx.conn.execute("""
        INSERT INTO registry.hf_assessment_data (assessment_id, patient_id, centre_id, hf_phenotype, gdmt_rule_set_id,
               pillars_eligible, pillars_prescribed, pillars_at_target, calculated_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, now())
        ON CONFLICT (assessment_id) DO UPDATE SET hf_phenotype = EXCLUDED.hf_phenotype,
               gdmt_rule_set_id = EXCLUDED.gdmt_rule_set_id, pillars_eligible = EXCLUDED.pillars_eligible,
               pillars_prescribed = EXCLUDED.pillars_prescribed, pillars_at_target = EXCLUDED.pillars_at_target,
               calculated_at = now()""",
        (assessment_id, a["patient_id"], ctx.centre_id, phenotype, rule["rule_set_id"], out["pillars_eligible"],
         out["pillars_on_treatment"], out["pillars_at_target"]))
    return out


# --- Lipid: LDL-C target attainment -----------------------------------------------

def _guidelines(ctx: Ctx, a: dict) -> dict[str, dict]:
    """rule_set_code -> rule set, for the protocol's primary and secondary LDL-C guidelines."""
    p = ctx.one("""SELECT p.ldl_target_rule_set_id, p.ldl_secondary_rule_set_id FROM registry.enrolments e
                     JOIN registry.registry_protocols p USING (protocol_id) WHERE e.enrolment_id = %s""",
                (a["enrolment_id"],))
    out = {}
    for rid, primary in ((p["ldl_target_rule_set_id"], True), (p["ldl_secondary_rule_set_id"], False)):
        if rid is not None:
            rs = _rule_set(ctx, rid)
            out[rs["rule_set_code"]] = {**rs, "is_primary": primary}
    return out


def _attainment_rows(ctx: Ctx, assessment_id) -> list[dict]:
    rows = ctx.all("""
        SELECT rs.rule_set_code || ' v' || rs.version AS guideline, rs.rule_set_code, rs.status AS rule_set_status,
               t.is_primary, t.risk_category, t.ldl_target_mg_dl, t.ldl_mg_dl, t.ldl_pct_reduction, t.target_met,
               t.calculated_at, t.row_version
          FROM registry.lipid_target_attainment t JOIN ref.rule_sets rs USING (rule_set_id)
         WHERE t.assessment_id = %s ORDER BY t.is_primary DESC, rs.rule_set_code""", (assessment_id,))
    return _jsonable(rows)


@router.get("/assessments/{assessment_id}/lipid/targets", tags=["Lipid"])
def get_lipid_targets(assessment_id: uuid.UUID, ctx: Ctx = Depends(STAFF)):
    a = _assessment(ctx, assessment_id)
    guides = _guidelines(ctx, a)
    cats: dict = {}
    for r in ctx.all("SELECT rule_set_id, risk_category, ldl_target_mg_dl, target_operator, min_pct_reduction "
                     "FROM ref.ldl_target_rules WHERE rule_set_id = ANY(%s) ORDER BY ldl_target_mg_dl",
                     ([g["rule_set_id"] for g in guides.values()],)):
        cats.setdefault(r["rule_set_id"], []).append({k: r[k] for k in ("risk_category", "ldl_target_mg_dl",
                                                                       "target_operator", "min_pct_reduction")})
    return {"items": _attainment_rows(ctx, assessment_id),
            "guidelines": _jsonable([{"rule_set_code": k, "version": v["version"], "status": v["status"],
                                      "is_primary": v["is_primary"], "categories": cats.get(v["rule_set_id"], [])}
                                     for k, v in guides.items()])}


class RiskCategory(Strict):
    rule_set_code: str = Field(pattern=r"^[A-Z0-9_]{2,40}$")
    risk_category: str = Field(pattern=r"^[a-z0-9_]{1,40}$")


class RiskCategories(Strict):
    categories: list[RiskCategory] = Field(min_length=1, max_length=4)


def _ldl_now(ctx: Ctx, a: dict) -> tuple[float | None, float | None]:
    """LDL-C for this visit: the value recorded on the form, else the chart's nearest result;
    with % reduction from the enrolment baseline when one is recorded."""
    row = ctx.one("""SELECT v.numeric_value FROM registry.variable_values v JOIN registry.variable_definitions d
                       USING (variable_id) WHERE v.assessment_id = %s AND d.variable_code = 'ldl_c'
                        AND v.value_status = 'present'""", (a["assessment_id"],))
    chart = Chart(ctx, a)
    ldl = row["numeric_value"] if row else (lab["v"] if (lab := chart.lab("LDL_C")) else None)
    base = chart.lipid_baseline()
    pct = ctx.one("SELECT registry.ldl_pct_reduction(%s, %s) AS p", (base, ldl))["p"] if base is not None else None
    return ldl, pct


@router.put("/assessments/{assessment_id}/lipid/targets", tags=["Lipid"])
def save_lipid_targets(assessment_id: uuid.UUID, body: RiskCategories, ctx: Ctx = Depends(STAFF)):
    a = _assessment(ctx, assessment_id)
    if a["locked_at"] is not None:
        raise Problem(422, "ASSESSMENT_LOCKED", "Assessment is locked")
    guides = _guidelines(ctx, a)
    unknown = [c.rule_set_code for c in body.categories if c.rule_set_code not in guides]
    if unknown:
        raise Problem(422, "VALIDATION_FAILED", "Guideline is not one this protocol uses",
                      errors=[{"field": "rule_set_code", "rule": "protocol_guideline", "message": u} for u in unknown])
    if len({c.rule_set_code for c in body.categories}) != len(body.categories):
        raise Problem(400, "VALIDATION_FAILED", "Each guideline may appear once per call")
    ldl, pct = _ldl_now(ctx, a)
    stored = {r["rule_set_code"]: r for r in _attainment_rows(ctx, assessment_id)}
    if any(c.rule_set_code in stored and stored[c.rule_set_code]["risk_category"] != c.risk_category
           for c in body.categories) and not ctx.change_reason:
        raise Problem(428, "CHANGE_REASON_REQUIRED", "X-Change-Reason is required to change a saved risk category")
    for c in body.categories:
        g = guides[c.rule_set_code]
        ctx.conn.execute("""
            INSERT INTO registry.lipid_target_attainment (assessment_id, rule_set_id, patient_id, centre_id, is_primary,
                   risk_category, ldl_target_mg_dl, ldl_mg_dl, ldl_pct_reduction)
            VALUES (%s, %s, %s, %s, %s, %s, 0.1, %s, %s)
            ON CONFLICT (assessment_id, rule_set_id) DO UPDATE SET risk_category = EXCLUDED.risk_category,
                   ldl_mg_dl = EXCLUDED.ldl_mg_dl, ldl_pct_reduction = EXCLUDED.ldl_pct_reduction""",
            (assessment_id, g["rule_set_id"], a["patient_id"], ctx.centre_id, g["is_primary"], c.risk_category,
             ldl, pct))
    return {"items": _attainment_rows(ctx, assessment_id)}
