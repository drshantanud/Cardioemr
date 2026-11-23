"""Prefill: fill emr_derived and calculated registry variables from the chart.

Each variable definition names an engine rule in derivation_key.  A rule
returns a Found (value plus the chart row it came from) or None when the
chart has nothing in the window.  Rules not written yet are reported as
not_automated_yet; nothing is guessed.

Look-back windows, all relative to the assessment date (D):
  vitals            D-7 .. D+1, nearest to D, per measurement
  height            latest on or before D, within 365 days
  labs              D-30 .. D+7, nearest to D (final, not rejected)
  echo              D-90 .. D+7, nearest to D
  clinical findings the assessment's own encounter, else the latest encounter in D-7 .. D
  lifestyle         latest observation on or before D
  diagnoses         active and confirmed on D (onset on or before D, when recorded)
  medicines         dose in force on D (clinical.course_dose_on); discontinued or held courses are off
  events "since last"  after the previous assessment of this enrolment (or from the index date) up to D;
                    reported events only, never entered in error or historical
  events before index  a reported event before the index date, or historical; nothing on file stays empty

Every query runs as the acting role at the acting centre, so row-level
security limits the chart to this centre's records."""
from __future__ import annotations

import math
import re
from dataclasses import dataclass
from datetime import date, timedelta
from decimal import Decimal
from typing import Any, Callable

from .context import Ctx

VITALS_BEFORE, VITALS_AFTER = 7, 1
HEIGHT_LOOKBACK = 365
LAB_BEFORE, LAB_AFTER = 30, 7
ECHO_BEFORE, ECHO_AFTER = 90, 7
ENCOUNTER_LOOKBACK = 7
INDEX_CABG_DAYS = 90    # CAD: CABG counts as part of the index revascularisation within 90 days of index
SEVERE_BLEEDING = {"severe", "life_threatening", "fatal"}

LAB_ANALYTE = {"alt": "ALT", "apob": "APOB", "ck": "CK", "creatinine": "CREATININE", "haemoglobin": "HB",
               "hba1c": "HBA1C", "hdl_c": "HDL_C", "ldl_c": "LDL_C", "nt_probnp": "NT_PROBNP", "potassium": "K",
               "sodium": "NA", "total_cholesterol": "TC", "triglycerides": "TG"}
VITAL_COLUMN = {"systolic_bp": "systolic_bp", "diastolic_bp": "diastolic_bp", "heart_rate": "heart_rate",
                "weight_kg": "weight_kg", "height_cm": "height_cm"}
ECHO_COLUMN = {"lvef": "lvef", "lvef_method": "lvef_method", "lvedd_mm": "lvedd_mm", "lvesd_mm": "lvesd_mm",
               "la_volume_index": "la_volume_index_ml_m2", "tapse_mm": "tapse_mm", "pasp_mmhg": "pasp_mmhg",
               "rv_function": "rv_function", "rwma": "rwma", "diastolic_grade": "diastolic_grade"}
GDMT_PILLAR = {"rasi": "RASI", "bb": "BB", "mra": "MRA", "sglt2i": "SGLT2I"}
P2Y12_CODES = {"CLOPIDOGREL": "clopidogrel", "TICAGRELOR": "ticagrelor", "PRASUGREL": "prasugrel"}
LDL_METHODS = {"direct", "friedewald", "martin_hopkins", "sampson"}
MAX_TOLERATED_REASONS = {"intolerance", "hypotension", "hyperkalaemia", "renal_dysfunction", "bradycardia",
                         "contraindication", "worsening_hf"}


@dataclass
class Found:
    value: Any
    table: str
    row_id: Any = None


class Chart:
    """Read-only, cached view of one patient's chart around one assessment."""

    def __init__(self, ctx: Ctx, assessment: dict):
        self.ctx = ctx
        self.a = assessment
        self.patient = assessment["patient_id"]
        self.d: date = assessment["assessment_date"]
        self._cache: dict[Any, Any] = {}
        self.enrolment = ctx.one("""
            SELECT e.enrolment_id, e.index_date, e.protocol_id, p.hf_target_dose_rule_set_id, p.statin_rule_set_id,
                   p.ldl_target_rule_set_id, p.ldl_secondary_rule_set_id, t.registry_code
              FROM registry.enrolments e JOIN registry.registry_protocols p USING (protocol_id)
              JOIN registry.registry_types t ON t.registry_type_id = e.registry_type_id
             WHERE e.enrolment_id = %s""", (assessment["enrolment_id"],))

    def _memo(self, key, fn: Callable[[], Any]):
        if key not in self._cache:
            self._cache[key] = fn()
        return self._cache[key]

    # --- chart lookups ---------------------------------------------------
    def registration(self) -> dict | None:
        return self._memo("reg", lambda: self.ctx.one(
            "SELECT registration_id, sex, date_of_birth FROM clinical.patient_registrations "
            "WHERE patient_id = %s AND centre_id = %s", (self.patient, self.ctx.centre_id)))

    def vital(self, column: str) -> dict | None:
        def q():
            if column == "height_cm":
                return self.ctx.one(
                    "SELECT vital_id, height_cm AS v FROM clinical.vital_signs WHERE patient_id = %s "
                    "AND status = 'final' AND height_cm IS NOT NULL AND measured_at::date BETWEEN %s AND %s "
                    "ORDER BY measured_at DESC LIMIT 1",
                    (self.patient, self.d - timedelta(days=HEIGHT_LOOKBACK), self.d))
            return self.ctx.one(
                f"SELECT vital_id, {column} AS v FROM clinical.vital_signs WHERE patient_id = %s "
                f"AND status = 'final' AND {column} IS NOT NULL AND measured_at::date BETWEEN %s AND %s "
                "ORDER BY abs(measured_at::date - %s::date), measured_at DESC LIMIT 1",
                (self.patient, self.d - timedelta(days=VITALS_BEFORE), self.d + timedelta(days=VITALS_AFTER), self.d))
        assert column in VITAL_COLUMN.values()
        return self._memo(("vital", column), q)

    def lab(self, analyte: str) -> dict | None:
        return self._memo(("lab", analyte), lambda: self.ctx.one("""
            SELECT r.result_id, r.value_canonical AS v, r.method, r.collected_at::date AS collected_on, a.canonical_unit
              FROM clinical.lab_results r JOIN ref.analytes a USING (analyte_code)
             WHERE r.patient_id = %s AND r.analyte_code = %s AND r.status = 'final'
               AND r.verification_status <> 'rejected' AND r.value_canonical IS NOT NULL
               AND r.collected_at::date BETWEEN %s AND %s
             ORDER BY abs(r.collected_at::date - %s::date), r.collected_at DESC LIMIT 1""",
            (self.patient, analyte, self.d - timedelta(days=LAB_BEFORE), self.d + timedelta(days=LAB_AFTER), self.d)))

    def echo(self) -> dict | None:
        return self._memo("echo", lambda: self.ctx.one("""
            SELECT e.*, i.performed_on FROM clinical.echo_reports e
              JOIN clinical.investigations i USING (investigation_id)
             WHERE e.patient_id = %s AND i.status <> 'entered_in_error' AND i.verification_status <> 'rejected'
               AND i.performed_on BETWEEN %s AND %s
             ORDER BY abs(i.performed_on - %s::date), i.performed_on DESC LIMIT 1""",
            (self.patient, self.d - timedelta(days=ECHO_BEFORE), self.d + timedelta(days=ECHO_AFTER), self.d)))

    def clinical_assessment(self) -> dict | None:
        def q():
            if self.a.get("encounter_id"):
                row = self.ctx.one("SELECT * FROM clinical.clinical_assessments WHERE encounter_id = %s",
                                   (self.a["encounter_id"],))
                if row:
                    return row
            return self.ctx.one("""
                SELECT ca.* FROM clinical.clinical_assessments ca JOIN clinical.encounters en USING (encounter_id)
                 WHERE ca.patient_id = %s AND en.status <> 'entered_in_error'
                   AND en.encounter_start::date BETWEEN %s AND %s
                 ORDER BY en.encounter_start DESC LIMIT 1""",
                (self.patient, self.d - timedelta(days=ENCOUNTER_LOOKBACK), self.d))
        return self._memo("ca", q)

    def lifestyle(self, column: str) -> dict | None:
        assert column in ("smoking_status",)
        return self._memo(("life", column), lambda: self.ctx.one(
            f"SELECT lifestyle_id, {column} AS v FROM clinical.lifestyle_observations WHERE patient_id = %s "
            f"AND {column} IS NOT NULL AND observed_on <= %s ORDER BY observed_on DESC, created_at DESC LIMIT 1",
            (self.patient, self.d)))

    def diagnosis(self, codes: list[str]) -> dict | None:
        return self._memo(("dx", tuple(codes)), lambda: self.ctx.one("""
            SELECT d.diagnosis_id FROM clinical.diagnoses d JOIN ref.concepts c USING (concept_id)
             WHERE d.patient_id = %s AND c.concept_code = ANY(%s) AND d.status = 'active'
               AND d.certainty = 'confirmed' AND (d.onset_date IS NULL OR d.onset_date <= %s)
             ORDER BY d.onset_date NULLS LAST LIMIT 1""", (self.patient, codes, self.d)))

    def active_drugs(self) -> list[dict]:
        """Courses in force on D: drug, classes and the daily dose of the latest dosing event."""
        return self._memo("drugs", lambda: self.ctx.all("""
            SELECT c.course_id, dr.drug_id, dr.drug_code, d.medication_event_id,
                   coalesce(d.daily_dose, (SELECT e.daily_dose FROM clinical.medication_events e
                                            WHERE e.course_id = c.course_id AND e.daily_dose IS NOT NULL
                                              AND e.effective_date <= %s
                                            ORDER BY e.effective_date DESC, e.recorded_at DESC LIMIT 1)) AS daily_dose,
                   array(SELECT m.drug_class_code FROM ref.drug_class_members m WHERE m.drug_id = dr.drug_id) AS classes
              FROM clinical.medication_courses c JOIN ref.drugs dr USING (drug_id)
              CROSS JOIN LATERAL clinical.course_dose_on(c.course_id, %s) d
              JOIN clinical.medication_events le ON le.medication_event_id = d.medication_event_id
             WHERE c.patient_id = %s AND c.status <> 'entered_in_error' AND c.started_on <= %s
               AND le.event_type NOT IN ('discontinue', 'hold')
             ORDER BY c.started_on, dr.drug_code""", (self.d, self.d, self.patient, self.d)))

    def drugs_in(self, classes: set[str]) -> list[dict]:
        return [r for r in self.active_drugs() if classes & set(r["classes"])]

    def gdmt(self) -> dict[str, dict]:
        def q():
            rule = self.enrolment["hf_target_dose_rule_set_id"]
            phenotype = self.phenotype()
            if rule is None:
                return {}
            rows = self.ctx.all("""
                SELECT g.*, d.drug_code FROM registry.compute_gdmt(%s, %s, %s, %s) g
                  LEFT JOIN ref.drugs d ON d.drug_id = g.drug_id""", (self.patient, self.d, rule, phenotype))
            return {r["pillar_code"]: r for r in rows}
        return self._memo("gdmt", q)

    def phenotype(self) -> str | None:
        def q():
            row = self.ctx.one("""
                SELECT v.coded_value FROM registry.variable_values v JOIN registry.variable_definitions d
                 USING (variable_id) WHERE v.assessment_id = %s AND d.variable_code = 'hf_phenotype'
                   AND v.value_status = 'present'""", (self.a["assessment_id"],))
            if row:
                return row["coded_value"]
            hf = self.ctx.one("SELECT baseline_phenotype FROM registry.hf_enrolment_details WHERE enrolment_id = %s",
                              (self.a["enrolment_id"],))
            return hf["baseline_phenotype"] if hf else None
        return self._memo("phenotype", q)

    def since_last(self) -> tuple[date | None, bool]:
        """(start, inclusive): events after the previous assessment of this enrolment, else from index."""
        def q():
            row = self.ctx.one("""SELECT max(assessment_date) AS d FROM registry.assessments
                                   WHERE enrolment_id = %s AND assessment_id <> %s AND assessment_date < %s
                                     AND completion_status <> 'missed'""",
                               (self.a["enrolment_id"], self.a["assessment_id"], self.d))
            if row and row["d"]:
                return row["d"], False
            return self.enrolment["index_date"], True
        return self._memo("since_last", q)

    def events(self, types: tuple[str, ...], start: date | None, end: date, inclusive_start: bool = True) -> list[dict]:
        return self._memo(("events", types, start, end, inclusive_start), lambda: self.ctx.all("""
            SELECT ev.*, p.indication AS pci_indication FROM clinical.clinical_events ev
              LEFT JOIN clinical.pci_procedures p ON p.procedure_id = ev.pci_procedure_id
             WHERE ev.patient_id = %s AND ev.event_type = ANY(%s) AND ev.status <> 'entered_in_error'
               AND NOT ev.is_historical AND ev.event_date <= %s
               AND (%s::date IS NULL OR ev.event_date > %s OR (%s AND ev.event_date = %s))
             ORDER BY ev.event_date, ev.created_at""",
            (self.patient, list(types), end, start, start, inclusive_start, start)))

    def events_before_index(self, types: tuple[str, ...]) -> list[dict]:
        return self._memo(("events_before", types), lambda: self.ctx.all("""
            SELECT event_id FROM clinical.clinical_events
             WHERE patient_id = %s AND event_type = ANY(%s) AND status <> 'entered_in_error'
               AND (is_historical OR event_date < %s) ORDER BY event_date""",
            (self.patient, list(types), self.enrolment["index_date"])))

    def adjudication(self, event_id, endpoint_code: str) -> dict | None:
        return self.ctx.one("""SELECT adj.adjudication_status, adj.meets_endpoint FROM registry.event_adjudications adj
                                JOIN registry.endpoint_definitions ed USING (endpoint_id)
                               WHERE adj.event_id = %s AND adj.protocol_id = %s AND ed.endpoint_code = %s""",
                            (event_id, self.enrolment["protocol_id"], endpoint_code))

    def convert(self, analyte: str, value, from_unit: str, to_unit: str):
        row = self.ctx.one("SELECT ref.convert_unit(%s, %s, %s, %s) AS v", (analyte, value, from_unit, to_unit))
        return None if row["v"] is None else round(row["v"], 2)

    def lipid_baseline(self) -> Decimal | None:
        row = self._memo("lipid_bl", lambda: self.ctx.one(
            "SELECT baseline_ldl_mg_dl FROM registry.lipid_enrolment_details WHERE enrolment_id = %s",
            (self.a["enrolment_id"],)))
        return row["baseline_ldl_mg_dl"] if row else None


# --- rules ----------------------------------------------------------------------
# Each rule: (chart, definition) -> Found | None.  A rule raises NotAutomated
# when it cannot handle this particular variable.

class NotAutomated(Exception):
    pass


def _age(dob: date, on: date) -> int:
    return on.year - dob.year - ((on.month, on.day) < (dob.month, dob.day))


def r_registration_sex(ch: Chart, d: dict):
    reg = ch.registration()
    return Found(reg["sex"], "clinical.patient_registrations", reg["registration_id"]) if reg else None


def r_age_at_index(ch: Chart, d: dict):
    reg, idx = ch.registration(), ch.enrolment["index_date"]
    if not reg or not reg["date_of_birth"] or not idx:
        return None
    return Found(_age(reg["date_of_birth"], idx), "clinical.patient_registrations", reg["registration_id"])


def r_vitals(ch: Chart, d: dict):
    col = VITAL_COLUMN.get(d["variable_code"])
    if col is None:
        raise NotAutomated
    row = ch.vital(col)
    return Found(row["v"], "clinical.vital_signs", row["vital_id"]) if row else None


def r_bmi(ch: Chart, d: dict):
    w, h = ch.vital("weight_kg"), ch.vital("height_cm")
    if not w or not h:
        return None
    return Found(round(float(w["v"]) / (float(h["v"]) / 100) ** 2, 1), "clinical.vital_signs", w["vital_id"])


def r_lab(ch: Chart, d: dict):
    code = d["variable_code"]
    if code == "ldl_method":
        row = ch.lab("LDL_C")
        if not row or row["method"] not in LDL_METHODS:
            return None
        return Found(row["method"], "clinical.lab_results", row["result_id"])
    if code == "lipid_test_date":
        row = ch.lab("LDL_C")
        return Found(row["collected_on"], "clinical.lab_results", row["result_id"]) if row else None
    analyte = LAB_ANALYTE.get(code)
    if analyte is None:
        raise NotAutomated
    row = ch.lab(analyte)
    if not row:
        return None
    if d["unit"] and row["canonical_unit"] != d["unit"]:
        value = ch.convert(analyte, row["v"], row["canonical_unit"], d["unit"])
        if value is None:
            raise NotAutomated      # no conversion between these units (for example Lp(a) nmol/L and mg/dL)
        return Found(value, "clinical.lab_results", row["result_id"])
    return Found(row["v"], "clinical.lab_results", row["result_id"])


def r_egfr(ch: Chart, d: dict):
    """CKD-EPI 2021 creatinine equation (race-free)."""
    reg, cr = ch.registration(), ch.lab("CREATININE")
    if not reg or not cr or not reg["date_of_birth"] or reg["sex"] not in ("male", "female"):
        return None
    scr, age, female = float(cr["v"]), _age(reg["date_of_birth"], ch.d), reg["sex"] == "female"
    k, a = (0.7, -0.241) if female else (0.9, -0.302)
    egfr = 142 * min(scr / k, 1) ** a * max(scr / k, 1) ** -1.200 * 0.9938 ** age * (1.012 if female else 1)
    return Found(round(egfr, 1), "clinical.lab_results", cr["result_id"])


def r_echo(ch: Chart, d: dict):
    e = ch.echo()
    if d["variable_code"] == "echo_date":
        return Found(e["performed_on"], "clinical.echo_reports", e["investigation_id"]) if e else None
    col = ECHO_COLUMN.get(d["variable_code"])
    if col is None:
        raise NotAutomated
    if not e or e[col] is None:
        return None
    return Found(e[col], "clinical.echo_reports", e["investigation_id"])


def r_hf_phenotype(ch: Chart, d: dict):
    e = ch.echo()
    if not e or e["lvef"] is None:
        return None
    hf = ch.ctx.one("SELECT prior_lowest_lvef FROM registry.hf_enrolment_details WHERE enrolment_id = %s",
                    (ch.a["enrolment_id"],))
    row = ch.ctx.one("SELECT registry.classify_hf_phenotype(%s, %s) AS p", (e["lvef"], hf and hf["prior_lowest_lvef"]))
    return Found(row["p"], "clinical.echo_reports", e["investigation_id"])


def r_clinical_assessment(ch: Chart, d: dict):
    ca = ch.clinical_assessment()
    if not ca:
        return None
    code = d["variable_code"]
    src = ("clinical.clinical_assessments", ca["clinical_assessment_id"])
    if code in ("nyha_class", "ccs_class", "congestion_status"):
        return Found(ca[code], *src) if ca[code] is not None else None
    if code == "jvp_raised":
        return Found(ca["jvp"] == "raised", *src) if ca["jvp"] in ("normal", "raised") else None
    if code == "peripheral_oedema":
        return Found(ca["peripheral_oedema"] != "none", *src) if ca["peripheral_oedema"] else None
    raise NotAutomated


def r_lifestyle(ch: Chart, d: dict):
    if d["variable_code"] != "smoking_status":
        raise NotAutomated
    row = ch.lifestyle("smoking_status")
    return Found(row["v"], "clinical.lifestyle_observations", row["lifestyle_id"]) if row else None


def r_active_diagnosis(ch: Chart, d: dict):
    codes = re.findall(r"\bDX_[A-Z_]+\b", d["emr_source"] or "")
    if not codes:
        raise NotAutomated
    row = ch.diagnosis(codes)
    # No confirmed, active diagnosis on file is recorded as "no"; it stays unverified until someone checks it.
    return Found(row is not None, "clinical.diagnoses", row["diagnosis_id"] if row else None)


def r_active_drug_class(ch: Chart, d: dict):
    code = d["variable_code"]
    if code == "on_aspirin":
        hits = [r for r in ch.active_drugs() if r["drug_code"] == "ASPIRIN"]
    elif code == "p2y12_agent":
        hits = ch.drugs_in({"P2Y12I"})
        if hits and hits[0]["drug_code"] not in P2Y12_CODES:
            return None
        return Found(P2Y12_CODES[hits[0]["drug_code"]] if hits else "none", "clinical.medication_courses",
                     hits[0]["course_id"] if hits else None)
    elif code in ("statin_drug", "statin_daily_dose"):
        hits = ch.drugs_in({"STATIN"})
        if not hits:
            return None
        h = hits[0]
        value = h["drug_code"] if code == "statin_drug" else h["daily_dose"]
        return Found(value, "clinical.medication_courses", h["course_id"]) if value is not None else None
    else:
        known = {"ARNI", "ACEI", "ARB", "BETA_BLOCKER", "MRA", "SGLT2I", "LOOP_DIURETIC", "IVABRADINE", "DIGOXIN",
                 "STATIN", "EZETIMIBE", "PCSK9_MAB", "PCSK9_SIRNA", "BEMPEDOIC_ACID", "ANTIPLATELET", "P2Y12I",
                 "ANTICOAGULANT"}
        classes = set(re.findall(r"\b[A-Z][A-Z0-9_]+\b", d["emr_source"] or "")) & known
        if not classes or d["data_type"] != "boolean":
            raise NotAutomated
        hits = ch.drugs_in(classes)
    return Found(bool(hits), "clinical.medication_courses", hits[0]["course_id"] if hits else None)


def r_dapt(ch: Chart, d: dict):
    asp = [r for r in ch.active_drugs() if r["drug_code"] == "ASPIRIN"]
    p2 = ch.drugs_in({"P2Y12I"})
    return Found(bool(asp and p2), "clinical.medication_courses", (asp or p2 or [{}])[0].get("course_id"))


def r_statin_intensity(ch: Chart, d: dict):
    rule = ch.enrolment["statin_rule_set_id"]
    if rule is None:
        return None
    hits = ch.drugs_in({"STATIN"})
    if not hits:
        return Found("none", "clinical.medication_courses", None)
    h = hits[0]
    row = ch.ctx.one("SELECT registry.statin_intensity(%s, %s, %s) AS i", (rule, h["drug_id"], h["daily_dose"]))
    return Found(row["i"], "clinical.medication_courses", h["course_id"]) if row["i"] else None


def dose_status(pillar: dict, reasons: set[str] | None = None) -> str:
    """Engine view of one pillar.  Reasons recorded by a clinician turn 'uptitrating'
    into 'max tolerated' when they name a limiting effect."""
    if not pillar["eligible"]:
        return "not_indicated"
    if not pillar["prescribed"]:
        return "not_prescribed"
    if pillar["pct_target_dose"] is not None and pillar["pct_target_dose"] >= 100:
        return "at_target"
    if reasons and reasons & MAX_TOLERATED_REASONS:
        return "below_target_max_tolerated"
    return "below_target_uptitrating"


def r_gdmt(ch: Chart, d: dict):
    g = ch.gdmt()
    if not g:
        return None
    code = d["variable_code"]
    src = "registry.compute_gdmt"
    if code == "gdmt_pillars_prescribed":
        return Found(sum(1 for p in g.values() if p["prescribed"]), src)
    if code == "gdmt_pillars_at_target":
        return Found(sum(1 for p in g.values() if dose_status(p) == "at_target"), src)
    prefix, _, suffix = code.partition("_")
    pillar = g.get(GDMT_PILLAR.get(prefix, ""))
    if pillar is None:
        raise NotAutomated
    course = pillar["course_id"]
    if suffix == "prescribed":
        return Found(pillar["prescribed"], src, course)
    if suffix == "eligible":
        return Found(pillar["eligible"], src, course)
    if suffix == "drug":
        return Found(pillar["drug_code"], src, course) if pillar["drug_code"] else None
    if suffix == "daily_dose":
        return Found(pillar["daily_dose"], src, course) if pillar["daily_dose"] is not None else None
    if suffix == "pct_target":
        return Found(pillar["pct_target_dose"], src, course) if pillar["pct_target_dose"] is not None else None
    if suffix == "dose_status":
        return Found(dose_status(pillar), src, course)
    raise NotAutomated


def r_ldl_reduction(ch: Chart, d: dict):
    base, ldl = ch.lipid_baseline(), ch.lab("LDL_C")
    if base is None or not ldl:
        return None
    src = ("clinical.lab_results", ldl["result_id"])
    current = float(ldl["v"])
    pct = round((float(base) - current) / float(base) * 100, 1) if base > 0 else None
    code = d["variable_code"]
    if code == "ldl_abs_reduction":
        return Found(round(float(base) - current, 1), *src)
    if code == "ldl_pct_reduction":
        return Found(pct, *src) if pct is not None else None
    if code == "reduction_50pct_met":
        return Found(pct >= 50, *src) if pct is not None else None
    raise NotAutomated


def r_non_hdl(ch: Chart, d: dict):
    tc, hdl = ch.lab("TC"), ch.lab("HDL_C")
    if not tc or not hdl:
        return None
    return Found(round(float(tc["v"]) - float(hdl["v"]), 1), "clinical.lab_results", tc["result_id"])


# --- events ---------------------------------------------------------------------
# variable -> (event types, kind).  kind: count | exists.  Extra filters below.
EVENT_SINCE_LAST = {
    "hf_hospitalisations_since_last": (("hf_hospitalisation",), "count"),
    "urgent_hf_visits_since_last": (("urgent_hf_visit",), "count"),
    "worsening_hf_escalation": (("worsening_hf_outpatient",), "exists"),
    "symptomatic_hypotension": (("hypotension",), "exists"),
    "cv_events_since_last": (("mi", "stroke", "pci", "cabg", "death"), "count"),
    "mi_since_last": (("mi",), "exists"),
    "stroke_since_last": (("stroke",), "exists"),
    "stent_thrombosis_since_last": (("stent_thrombosis",), "exists"),
    "hf_hospitalisation_since_last": (("hf_hospitalisation",), "exists"),
    "cv_death": (("death",), "exists"),
    "any_revasc_since_last": (("pci", "cabg"), "exists"),
    "major_bleeding_since_last": (("bleeding",), "exists"),
}
EVENT_BEFORE_INDEX = {"prior_mi": ("mi",), "prior_pci": ("pci",), "prior_cabg": ("cabg",)}


def _event_counts(code: str, ev: dict) -> bool:
    if code in ("cv_events_since_last", "cv_death") and ev["event_type"] == "death":
        return ev["death_cause"] == "cardiovascular"     # site-reported cause; adjudication may differ
    if code == "any_revasc_since_last" and ev["event_type"] == "pci":
        return ev["pci_indication"] != "staged"          # a planned staged PCI is not a repeat revascularisation
    return True


def r_event_since_last(ch: Chart, d: dict):
    code = d["variable_code"]
    spec = EVENT_SINCE_LAST.get(code)
    if spec is None:
        raise NotAutomated          # tlr / tvr need the target lesion or vessel: left to adjudication
    types, kind = spec
    start, inclusive = ch.since_last()
    hits = [e for e in ch.events(types, start, ch.d, inclusive) if _event_counts(code, e)]
    first = hits[0]["event_id"] if hits else None
    if code == "major_bleeding_since_last":
        # BARC 3-5 by adjudication; while a bleed awaits adjudication, a reported severe bleed counts.
        decided = []
        for e in hits:
            adj = ch.adjudication(e["event_id"], "BLEED_BARC35")
            if adj and adj["adjudication_status"] == "adjudicated":
                decided.append(bool(adj["meets_endpoint"]))
            elif adj and adj["adjudication_status"] == "not_an_event":
                decided.append(False)
            elif e["severity"] in SEVERE_BLEEDING:
                decided.append(True)
            else:
                return None        # a bleed of unknown grade is waiting for adjudication
        major = [e for e, m in zip(hits, decided) if m]
        return Found(bool(major), "clinical.clinical_events", major[0]["event_id"] if major else None)
    if kind == "count":
        return Found(len(hits), "clinical.clinical_events", first)
    return Found(bool(hits), "clinical.clinical_events", first)


def r_event_before_index(ch: Chart, d: dict):
    types = EVENT_BEFORE_INDEX.get(d["variable_code"])
    if types is None or ch.enrolment["index_date"] is None:
        raise NotAutomated
    hits = ch.events_before_index(types)
    if not hits and d["variable_code"] == "prior_mi":
        dx = ch.diagnosis(["DX_MI"])
        if dx:
            return Found(True, "clinical.diagnoses", dx["diagnosis_id"])
    # Nothing on file is not the same as "no": leave it for the coordinator.
    return Found(True, "clinical.clinical_events", hits[0]["event_id"]) if hits else None


def r_event_in_index_window(ch: Chart, d: dict):
    code = d["variable_code"]
    if code not in ("cabg_date", "index_cabg_done") or ch.enrolment["index_date"] is None:
        raise NotAutomated
    index = ch.enrolment["index_date"]
    end = index + timedelta(days=INDEX_CABG_DAYS)
    hits = ch.events(("cabg",), index, min(end, ch.d), True)
    if hits:
        e = hits[0]
        return Found(e["event_date"] if code == "cabg_date" else True, "clinical.clinical_events", e["event_id"])
    if code == "index_cabg_done" and ch.d >= end:
        return Found(False, "clinical.clinical_events", None)
    return None


RULES: dict[str, Callable[[Chart, dict], Found | None]] = {
    "emr.registration_sex": r_registration_sex,
    "calc.age_at_index": r_age_at_index,
    "emr.vitals_in_window": r_vitals,
    "emr.vitals_latest": r_vitals,
    "calc.bmi": r_bmi,
    "emr.lab_in_window": r_lab,
    "calc.egfr_ckd_epi_2021": r_egfr,
    "emr.echo_in_window": r_echo,
    "calc.hf_phenotype": r_hf_phenotype,
    "emr.clinical_assessment": r_clinical_assessment,
    "emr.lifestyle_latest": r_lifestyle,
    "emr.active_diagnosis": r_active_diagnosis,
    "emr.active_drug_class": r_active_drug_class,
    "calc.dapt": r_dapt,
    "calc.statin_intensity": r_statin_intensity,
    "calc.gdmt": r_gdmt,
    "calc.gdmt + clinician confirmation": r_gdmt,
    "calc.ldl_abs_reduction": r_ldl_reduction,
    "calc.ldl_pct_reduction": r_ldl_reduction,
    "calc.ldl_pct_reduction >= 50": r_ldl_reduction,
    "calc.non_hdl": r_non_hdl,
    "calc.event_count": r_event_since_last,
    "calc.event_exists": r_event_since_last,
    "emr.event_before_index": r_event_before_index,
    "emr.event_in_window": r_event_in_index_window,
    "calc.event_in_window": r_event_in_index_window,
}


def derive(chart: Chart, definition: dict) -> Found | None:
    """Found, None (nothing in the window) or NotAutomated."""
    rule = RULES.get(definition["derivation_key"] or "")
    if rule is None:
        raise NotAutomated
    found = rule(chart, definition)
    if found is not None and isinstance(found.value, float) and not math.isfinite(found.value):
        return None
    return found
