// PCI procedures, clinical events and adjudication: option lists, form drafts and the
// conversion between a draft (what the form holds, all strings) and the API body.
// The API and the database check everything again; this only gives early, plain messages.
import type { Classification, ClinicalEvent, PciLesion, PciProcedure, PciStent } from "./types";

type Opt = [string, string][];
const opts = (pairs: Record<string, string>): Opt => Object.entries(pairs);

export const PCI_OPTIONS = {
  indication: opts({
    primary_pci_stemi: "Primary PCI for STEMI", pharmacoinvasive: "Pharmacoinvasive", rescue_pci: "Rescue PCI",
    nstemi: "NSTEMI", unstable_angina: "Unstable angina", chronic_coronary_syndrome: "Chronic coronary syndrome",
    staged: "Staged procedure", silent_ischaemia: "Silent ischaemia", other: "Other",
  }),
  urgency: opts({ elective: "Elective", urgent: "Urgent", emergency: "Emergency", salvage: "Salvage" }),
  access_site: opts({ radial: "Radial", distal_radial: "Distal radial", femoral: "Femoral", brachial: "Brachial", ulnar: "Ulnar" }),
  imaging_guidance: opts({ none: "None", IVUS: "IVUS", OCT: "OCT", IVUS_and_OCT: "IVUS and OCT" }),
  physiology: opts({ none: "None", FFR: "FFR", iFR: "iFR", RFR: "RFR", QFR: "QFR", other: "Other" }),
  mechanical_support: opts({ none: "None", IABP: "IABP", Impella: "Impella", ECMO: "ECMO" }),
  complications: opts({
    none: "None", dissection: "Dissection", perforation: "Perforation", no_reflow: "No-reflow",
    side_branch_occlusion: "Side-branch occlusion", acute_stent_thrombosis: "Acute stent thrombosis",
    access_bleeding: "Access-site bleeding", haematoma: "Haematoma", pseudoaneurysm: "Pseudoaneurysm",
    contrast_nephropathy: "Contrast nephropathy", arrhythmia: "Arrhythmia", stroke: "Stroke", death: "Death", other: "Other",
  }),
  vessel: opts({
    LM: "Left main", LAD: "LAD", LCX: "LCx", RCA: "RCA", RAMUS: "Ramus", DIAGONAL: "Diagonal", OM: "Obtuse marginal",
    PDA: "PDA", PLV: "PLV", SVG: "Vein graft", LIMA: "LIMA graft", RIMA: "RIMA graft", RADIAL_GRAFT: "Radial graft",
  }),
  lesion_type_acc_aha: opts({ A: "A", B1: "B1", B2: "B2", C: "C" }),
  calcification: opts({ none: "None", mild: "Mild", moderate: "Moderate", severe: "Severe" }),
  bifurcation_technique: opts({
    provisional: "Provisional", TAP: "TAP", culotte: "Culotte", DK_crush: "DK crush", mini_crush: "Mini-crush",
    T_stenting: "T-stenting", V_stenting: "V-stenting", other: "Other",
  }),
  lesion_preparation: opts({
    predilatation: "Predilatation", cutting_balloon: "Cutting balloon", scoring_balloon: "Scoring balloon",
    rotational_atherectomy: "Rotational atherectomy", orbital_atherectomy: "Orbital atherectomy", IVL: "IVL", laser: "Laser",
  }),
  treatment: opts({
    stent: "Stent", DCB: "Drug-coated balloon", POBA: "Balloon only (POBA)", failed: "Failed",
    deferred_by_physiology: "Deferred by physiology",
  }),
  timi: opts({ "0": "TIMI 0", "1": "TIMI 1", "2": "TIMI 2", "3": "TIMI 3" }),
};

export const EVENT_TYPES = opts({
  death: "Death", mi: "Myocardial infarction", stroke: "Stroke", tia: "TIA", hf_hospitalisation: "Heart failure hospitalisation",
  urgent_hf_visit: "Urgent heart failure visit", worsening_hf_outpatient: "Worsening heart failure (outpatient)",
  pci: "PCI", cabg: "CABG", stent_thrombosis: "Stent thrombosis", bleeding: "Bleeding", hyperkalaemia: "Hyperkalaemia",
  hypotension: "Hypotension", renal_deterioration: "Renal deterioration", arrhythmia: "Arrhythmia",
  device_therapy: "Device therapy (shock or pacing)", other_cv_hospitalisation: "Other cardiovascular hospitalisation",
  non_cv_hospitalisation: "Non-cardiovascular hospitalisation", other: "Other",
});
export const HOSPITAL_TYPES = new Set(["hf_hospitalisation", "other_cv_hospitalisation", "non_cv_hospitalisation"]);

export const EVENT_OPTIONS = {
  source: opts({
    site_clinician: "Seen by our clinician", patient_report: "Patient's report", relative_report: "Relative's report",
    hospital_records: "Hospital records", death_certificate: "Death certificate", follow_up_call: "Follow-up call",
  }),
  severity: opts({ mild: "Mild", moderate: "Moderate", severe: "Severe", life_threatening: "Life-threatening", fatal: "Fatal" }),
  outcome: opts({
    recovered: "Recovered", recovered_with_sequelae: "Recovered with sequelae", ongoing: "Ongoing", fatal: "Fatal", unknown: "Unknown",
  }),
  death_cause: opts({ cardiovascular: "Cardiovascular", non_cardiovascular: "Non-cardiovascular", undetermined: "Undetermined" }),
  death_cv_mode: opts({
    sudden: "Sudden", heart_failure: "Heart failure", mi: "Myocardial infarction", stroke: "Stroke", procedural: "Procedural", other_cv: "Other cardiovascular",
  }),
  mi_type: opts({ "1": "Type 1", "2": "Type 2", "3": "Type 3", "4a": "Type 4a", "4b": "Type 4b", "4c": "Type 4c", "5": "Type 5" }),
  stroke_type: opts({ ischaemic: "Ischaemic", haemorrhagic: "Haemorrhagic", undetermined: "Undetermined" }),
  precision: opts({ day: "Exact day", month: "Month only", year: "Year only" }),
};

export function label(list: Opt, code: string | null | undefined): string {
  if (code == null || code === "") return "";
  return list.find(([c]) => c === code)?.[1] ?? code.replace(/_/g, " ");
}

// --- PCI drafts --------------------------------------------------------------------

export interface StentDraft {
  stent_id?: string; sequence_number: number; device_text: string; stent_device_id: string | null;
  diameter_mm: string; length_mm: string; deployment_atm: string; post_dilatation_balloon_mm: string;
}
export interface LesionDraft {
  lesion_id?: string; lesion_number: number; vessel: string; segment_code: string; lesion_type_acc_aha: string;
  lesion_length_mm: string; reference_diameter_mm: string; pre_stenosis_pct: string; pre_timi_flow: string;
  calcification: string; is_cto: boolean; j_cto_score: string; is_bifurcation: boolean; medina: string;
  bifurcation_technique: string; is_in_stent_restenosis: boolean; thrombus: "" | "yes" | "no";
  lesion_preparation: string[]; post_dilatation: "" | "yes" | "no"; pre_physiology_value: string;
  post_physiology_value: string; final_timi_flow: string; residual_stenosis_pct: string; treatment: string;
  stents: StentDraft[];
}
export interface PciDraft {
  procedure_date: string; performed_at_facility: string; indication: string; urgency: string; access_site: string;
  operator_name: string; imaging_guidance: string; physiology: string; mechanical_support: string; contrast_ml: string;
  fluoroscopy_min: string; procedural_success: "" | "yes" | "no"; complications: string[];
  status: "draft" | "final" | "entered_in_error"; lesions: LesionDraft[];
}

const str = (v: number | string | null | undefined) => (v == null ? "" : String(v));
const yn = (v: boolean | null | undefined): "" | "yes" | "no" => (v == null ? "" : v ? "yes" : "no");

export function newStent(n: number): StentDraft {
  return { sequence_number: n, device_text: "", stent_device_id: null, diameter_mm: "", length_mm: "", deployment_atm: "", post_dilatation_balloon_mm: "" };
}
export function newLesion(n: number): LesionDraft {
  return {
    lesion_number: n, vessel: "", segment_code: "", lesion_type_acc_aha: "", lesion_length_mm: "", reference_diameter_mm: "",
    pre_stenosis_pct: "", pre_timi_flow: "", calcification: "", is_cto: false, j_cto_score: "", is_bifurcation: false, medina: "",
    bifurcation_technique: "", is_in_stent_restenosis: false, thrombus: "", lesion_preparation: [], post_dilatation: "",
    pre_physiology_value: "", post_physiology_value: "", final_timi_flow: "", residual_stenosis_pct: "", treatment: "stent",
    stents: [newStent(1)],
  };
}
export function newPci(today: string): PciDraft {
  return {
    procedure_date: today, performed_at_facility: "", indication: "", urgency: "", access_site: "radial", operator_name: "",
    imaging_guidance: "none", physiology: "none", mechanical_support: "", contrast_ml: "", fluoroscopy_min: "",
    procedural_success: "", complications: [], status: "final", lesions: [newLesion(1)],
  };
}

export function pciDraftOf(p: PciProcedure): PciDraft {
  return {
    procedure_date: p.procedure_date, performed_at_facility: str(p.performed_at_facility), indication: p.indication,
    urgency: str(p.urgency), access_site: str(p.access_site), operator_name: str(p.operator_name),
    imaging_guidance: p.imaging_guidance, physiology: p.physiology, mechanical_support: str(p.mechanical_support),
    contrast_ml: str(p.contrast_ml), fluoroscopy_min: str(p.fluoroscopy_min), procedural_success: yn(p.procedural_success),
    complications: p.complications ?? [], status: p.status,
    lesions: p.lesions.map((l) => ({
      lesion_id: l.lesion_id, lesion_number: l.lesion_number, vessel: l.vessel, segment_code: str(l.segment_code),
      lesion_type_acc_aha: str(l.lesion_type_acc_aha), lesion_length_mm: str(l.lesion_length_mm),
      reference_diameter_mm: str(l.reference_diameter_mm), pre_stenosis_pct: str(l.pre_stenosis_pct),
      pre_timi_flow: str(l.pre_timi_flow), calcification: str(l.calcification), is_cto: l.is_cto, j_cto_score: str(l.j_cto_score),
      is_bifurcation: l.is_bifurcation, medina: str(l.medina), bifurcation_technique: str(l.bifurcation_technique),
      is_in_stent_restenosis: l.is_in_stent_restenosis, thrombus: yn(l.thrombus), lesion_preparation: l.lesion_preparation ?? [],
      post_dilatation: yn(l.post_dilatation), pre_physiology_value: str(l.pre_physiology_value),
      post_physiology_value: str(l.post_physiology_value), final_timi_flow: str(l.final_timi_flow),
      residual_stenosis_pct: str(l.residual_stenosis_pct), treatment: l.treatment,
      stents: l.stents.map((s) => ({
        stent_id: s.stent_id, sequence_number: s.sequence_number, device_text: str(s.device_text), stent_device_id: s.stent_device_id,
        diameter_mm: str(s.diameter_mm), length_mm: str(s.length_mm), deployment_atm: str(s.deployment_atm),
        post_dilatation_balloon_mm: str(s.post_dilatation_balloon_mm),
      })),
    })),
  };
}

const num = (s: string): number | null => {
  const t = s.trim();
  if (!t) return null;
  const n = Number(t);
  return Number.isFinite(n) ? n : NaN;
};
const int = (s: string): number | null => {
  const n = num(s);
  return n == null || Number.isNaN(n) ? n : Math.round(n);
};
const opt = (s: string) => (s.trim() ? s.trim() : null);
const bool = (s: "" | "yes" | "no") => (s === "" ? null : s === "yes");

/** Field key -> message.  Keys: "procedure_date", "lesion.1.vessel", "lesion.1.stent.2.diameter_mm" … */
export type PciErrors = Record<string, string>;

const range = (errs: PciErrors, key: string, raw: string, lo: number, hi: number, what: string, required = false) => {
  const v = num(raw);
  if (v == null) {
    if (required) errs[key] = `Enter the ${what}`;
  } else if (Number.isNaN(v) || v < lo || v > hi) {
    errs[key] = `${what.charAt(0).toUpperCase()}${what.slice(1)} must be between ${lo} and ${hi}`;
  }
};

export function validatePci(d: PciDraft, today: string): PciErrors {
  const e: PciErrors = {};
  if (!d.procedure_date) e.procedure_date = "Enter the procedure date";
  else if (d.procedure_date > today) e.procedure_date = "The procedure date cannot be in the future";
  if (!d.indication) e.indication = "Choose the indication";
  range(e, "contrast_ml", d.contrast_ml, 0, 2000, "contrast volume");
  range(e, "fluoroscopy_min", d.fluoroscopy_min, 0, 600, "fluoroscopy time");
  if (d.complications.includes("none") && d.complications.length > 1) e.complications = "\"None\" cannot go with a complication";
  if (d.lesions.length === 0) e.lesions = "Add at least one lesion";
  for (const l of d.lesions) {
    const k = `lesion.${l.lesion_number}`;
    if (!l.vessel) e[`${k}.vessel`] = "Choose the vessel";
    range(e, `${k}.lesion_length_mm`, l.lesion_length_mm, 1, 200, "lesion length");
    range(e, `${k}.reference_diameter_mm`, l.reference_diameter_mm, 1.5, 7, "reference diameter");
    range(e, `${k}.pre_stenosis_pct`, l.pre_stenosis_pct, 0, 100, "stenosis");
    range(e, `${k}.residual_stenosis_pct`, l.residual_stenosis_pct, 0, 100, "residual stenosis");
    if (l.is_cto) range(e, `${k}.j_cto_score`, l.j_cto_score, 0, 5, "J-CTO score");
    if (l.is_bifurcation && !/^[01],[01],[01]$/.test(l.medina)) e[`${k}.medina`] = "Give the Medina class, e.g. 1,1,0";
    if (l.treatment === "stent" && l.stents.length === 0) e[`${k}.stents`] = "Add the stent";
    if (l.treatment === "stent") {
      for (const s of l.stents) {
        const sk = `${k}.stent.${s.sequence_number}`;
        if (!s.device_text.trim() && !s.stent_device_id) e[`${sk}.device_text`] = "Name the stent";
        range(e, `${sk}.diameter_mm`, s.diameter_mm, 1.5, 6, "diameter", true);
        range(e, `${sk}.length_mm`, s.length_mm, 6, 60, "length", true);
        range(e, `${sk}.deployment_atm`, s.deployment_atm, 4, 30, "deployment pressure");
      }
    }
  }
  return e;
}

export function pciBody(d: PciDraft): Record<string, unknown> {
  return {
    procedure_date: d.procedure_date, performed_at_facility: opt(d.performed_at_facility), indication: d.indication,
    urgency: opt(d.urgency), access_site: opt(d.access_site), operator_name: opt(d.operator_name),
    imaging_guidance: d.imaging_guidance, physiology: d.physiology, mechanical_support: opt(d.mechanical_support),
    contrast_ml: int(d.contrast_ml), fluoroscopy_min: num(d.fluoroscopy_min), procedural_success: bool(d.procedural_success),
    complications: d.complications.length ? d.complications : null, status: d.status,
    lesions: d.lesions.map((l): Omit<PciLesion, "lesion_id"> => ({
      lesion_number: l.lesion_number, vessel: l.vessel, segment_code: opt(l.segment_code),
      lesion_type_acc_aha: opt(l.lesion_type_acc_aha), lesion_length_mm: num(l.lesion_length_mm),
      reference_diameter_mm: num(l.reference_diameter_mm), pre_stenosis_pct: int(l.pre_stenosis_pct),
      pre_timi_flow: int(l.pre_timi_flow), calcification: opt(l.calcification), is_cto: l.is_cto,
      j_cto_score: l.is_cto ? int(l.j_cto_score) : null, is_bifurcation: l.is_bifurcation,
      medina: l.is_bifurcation ? opt(l.medina) : null, bifurcation_technique: l.is_bifurcation ? opt(l.bifurcation_technique) : null,
      is_in_stent_restenosis: l.is_in_stent_restenosis, thrombus: bool(l.thrombus),
      lesion_preparation: l.lesion_preparation.length ? l.lesion_preparation : null, post_dilatation: bool(l.post_dilatation),
      pre_physiology_value: num(l.pre_physiology_value), post_physiology_value: num(l.post_physiology_value),
      final_timi_flow: int(l.final_timi_flow), residual_stenosis_pct: int(l.residual_stenosis_pct), treatment: l.treatment,
      stents: l.treatment !== "stent" ? [] : l.stents.map((s): Omit<PciStent, "stent_id"> => ({
        sequence_number: s.sequence_number, stent_device_id: s.stent_device_id, device_text: opt(s.device_text),
        diameter_mm: num(s.diameter_mm) as number, length_mm: num(s.length_mm) as number,
        deployment_atm: int(s.deployment_atm), post_dilatation_balloon_mm: num(s.post_dilatation_balloon_mm),
      })),
    })),
  };
}

/** One line per lesion, e.g. "LAD (6) · B2 · 90% → 0% · 2 stents". */
export function lesionLine(l: PciLesion): string {
  const parts = [`${label(PCI_OPTIONS.vessel, l.vessel)}${l.segment_code ? ` (${l.segment_code})` : ""}`];
  if (l.lesion_type_acc_aha) parts.push(l.lesion_type_acc_aha);
  if (l.is_cto) parts.push("CTO");
  if (l.is_bifurcation) parts.push(`bifurcation ${l.medina ?? ""}`.trim());
  if (l.pre_stenosis_pct != null) parts.push(`${l.pre_stenosis_pct}%${l.residual_stenosis_pct != null ? ` → ${l.residual_stenosis_pct}%` : ""}`);
  parts.push(l.treatment === "stent" ? `${l.stents.length} stent${l.stents.length === 1 ? "" : "s"}` : label(PCI_OPTIONS.treatment, l.treatment));
  return parts.join(" · ");
}

export function stentLine(s: PciStent): string {
  return `${s.device_text ?? "Catalogue stent"} ${s.diameter_mm} × ${s.length_mm} mm${s.deployment_atm ? ` at ${s.deployment_atm} atm` : ""}`;
}

// --- Event drafts ------------------------------------------------------------------

export interface EventDraft {
  event_type: string; event_date: string; event_date_precision: "day" | "month" | "year"; is_historical: boolean;
  description: string; hospitalised: "" | "yes" | "no"; admission_date: string; discharge_date: string; facility_name: string;
  severity: string; outcome: string; death_cause: string; death_cv_mode: string; mi_type: string; stroke_type: string;
  bleeding_site: string; pci_procedure_id: string; target_lesion_id: string; potassium_mmol_l: string; source: string;
}

export function newEvent(today: string): EventDraft {
  return {
    event_type: "", event_date: today, event_date_precision: "day", is_historical: false, description: "", hospitalised: "",
    admission_date: "", discharge_date: "", facility_name: "", severity: "", outcome: "", death_cause: "", death_cv_mode: "",
    mi_type: "", stroke_type: "", bleeding_site: "", pci_procedure_id: "", target_lesion_id: "", potassium_mmol_l: "",
    source: "site_clinician",
  };
}

export function eventDraftOf(e: ClinicalEvent): EventDraft {
  return {
    event_type: e.event_type, event_date: e.event_date, event_date_precision: e.event_date_precision, is_historical: e.is_historical,
    description: str(e.description), hospitalised: yn(e.hospitalised), admission_date: str(e.admission_date),
    discharge_date: str(e.discharge_date), facility_name: str(e.facility_name), severity: str(e.severity), outcome: str(e.outcome),
    death_cause: str(e.death_cause), death_cv_mode: str(e.death_cv_mode), mi_type: str(e.mi_type), stroke_type: str(e.stroke_type),
    bleeding_site: str(e.bleeding_site), pci_procedure_id: str(e.pci_procedure_id), target_lesion_id: str(e.target_lesion_id),
    potassium_mmol_l: str(e.potassium_mmol_l), source: e.source,
  };
}

/** Which detail questions the event type asks. */
export function eventAsks(type: string) {
  return {
    hospital: HOSPITAL_TYPES.has(type) || ["mi", "stroke", "bleeding", "pci", "cabg", "stent_thrombosis", "other"].includes(type),
    hospitalAlways: HOSPITAL_TYPES.has(type),
    death: type === "death",
    mi: type === "mi",
    stroke: type === "stroke",
    bleeding: type === "bleeding",
    procedure: ["pci", "stent_thrombosis"].includes(type),
    potassium: type === "hyperkalaemia",
  };
}

export function validateEvent(d: EventDraft, today: string): Record<string, string> {
  const e: Record<string, string> = {};
  if (!d.event_type) e.event_type = "Choose what happened";
  if (!d.event_date) e.event_date = "Enter the date";
  else if (d.event_date > today) e.event_date = "The date cannot be in the future";
  if (d.event_type === "death" && !d.death_cause) e.death_cause = "Choose the cause of death";
  if (d.admission_date && d.discharge_date && d.discharge_date < d.admission_date) e.discharge_date = "Discharge is before admission";
  const k = num(d.potassium_mmol_l);
  if (k != null && (Number.isNaN(k) || k < 1 || k > 10)) e.potassium_mmol_l = "Potassium must be between 1 and 10 mmol/L";
  if (!d.source) e.source = "Choose where this came from";
  return e;
}

/** Body for POST /events (with patient and type) or PUT /events/{id} (details only). */
export function eventBody(d: EventDraft): Record<string, unknown> {
  const a = eventAsks(d.event_type);
  return {
    event_date: d.event_date, event_date_precision: d.event_date_precision, is_historical: d.is_historical,
    description: opt(d.description),
    hospitalised: a.hospitalAlways ? true : a.hospital ? bool(d.hospitalised) : null,
    admission_date: a.hospital ? opt(d.admission_date) : null, discharge_date: a.hospital ? opt(d.discharge_date) : null,
    facility_name: opt(d.facility_name), severity: opt(d.severity), outcome: opt(d.outcome),
    death_cause: a.death ? opt(d.death_cause) : null,
    death_cv_mode: a.death && d.death_cause === "cardiovascular" ? opt(d.death_cv_mode) : null,
    mi_type: a.mi ? opt(d.mi_type) : null, stroke_type: a.stroke ? opt(d.stroke_type) : null,
    bleeding_site: a.bleeding ? opt(d.bleeding_site) : null,
    pci_procedure_id: a.procedure ? opt(d.pci_procedure_id) : null,
    target_lesion_id: a.procedure ? opt(d.target_lesion_id) : null,
    potassium_mmol_l: a.potassium ? num(d.potassium_mmol_l) : null, source: d.source,
  };
}

export function eventLine(e: Pick<ClinicalEvent, "event_type" | "mi_type" | "stroke_type" | "death_cause" | "hospitalised">): string {
  const parts = [label(EVENT_TYPES, e.event_type)];
  if (e.mi_type) parts.push(`type ${e.mi_type}`);
  if (e.stroke_type) parts.push(e.stroke_type);
  if (e.death_cause) parts.push(label(EVENT_OPTIONS.death_cause, e.death_cause).toLowerCase());
  if (e.hospitalised && !HOSPITAL_TYPES.has(e.event_type)) parts.push("hospitalised");
  return parts.join(" · ");
}

/** An event date shown at the precision it was recorded with. */
export function eventDate(iso: string, precision: string): string {
  const [y, m] = iso.split("-");
  if (precision === "year") return y;
  if (precision === "month") return new Date(Number(y), Number(m) - 1, 1).toLocaleDateString("en-IN", { month: "short", year: "numeric" });
  return new Date(`${iso}T00:00:00`).toLocaleDateString("en-IN", { day: "numeric", month: "short", year: "numeric" });
}

// --- Adjudication ------------------------------------------------------------------

export const ADJ_STATUS: Opt = opts({
  pending: "Waiting", in_review: "In review", insufficient_data: "Needs more data", adjudicated: "Adjudicated",
  not_an_event: "Not an event", event_withdrawn: "Event withdrawn",
});

export function classificationsFor(all: Classification[], system: string | null): Classification[] {
  return system ? all.filter((c) => c.classification_system === system) : [];
}

/** Whether the classification alone decides the endpoint (the database then sets meets_endpoint). */
export function decides(qualifying: string[] | null): boolean {
  return !!qualifying && qualifying.length > 0;
}
