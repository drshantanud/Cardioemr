// Registry wording and options shared by the screening, enrolment and assessment screens.
import type { Protocol, ScheduleItem, VariableDefinition, VariableValue } from "./types";

export const REGISTRY_NAMES: Record<string, string> = { HF: "Heart failure", LIPID: "Lipid", CAD: "Coronary artery disease" };

export interface Criterion { code: string; label: string; kind: "inclusion" | "exclusion" }

/** The checklist a clinician answers at screening: the protocol's machine rules when it has them,
 *  otherwise one line per clause of the inclusion and exclusion text. */
export function criteria(p: Pick<Protocol, "inclusion_text" | "exclusion_text" | "inclusion_rules" | "exclusion_rules">): Criterion[] {
  const fromText = (text: string | null, prefix: string, kind: Criterion["kind"]) =>
    (text ?? "").split(";").map((t) => t.trim()).filter(Boolean)
      .map((label, i) => ({ code: `${prefix}_${i + 1}`, label, kind }));
  const inc = p.inclusion_rules?.length ? p.inclusion_rules.map((r) => ({ ...r, kind: "inclusion" as const }))
    : fromText(p.inclusion_text, "INC", "inclusion");
  const exc = p.exclusion_rules?.length ? p.exclusion_rules.map((r) => ({ ...r, kind: "exclusion" as const }))
    : fromText(p.exclusion_text, "EXC", "exclusion");
  return [...inc, ...exc];
}

export type Answer = "yes" | "no" | "unknown";

/** Eligible only when every inclusion is yes and every exclusion is no. */
export function eligibilityFrom(list: Criterion[], answers: Record<string, Answer | undefined>):
  "eligible" | "ineligible" | "incomplete" {
  if (list.some((c) => !answers[c.code])) return "incomplete";
  if (list.some((c) => (c.kind === "inclusion" ? answers[c.code] !== "yes" : answers[c.code] !== "no"))) {
    return list.some((c) => answers[c.code] === "unknown") ? "incomplete" : "ineligible";
  }
  return "eligible";
}

const o = (...codes: string[]): [string, string][] => codes.map((c) => [c, humanCode(c)]);

export function humanCode(c: string): string {
  const special: Record<string, string> = {
    STEMI: "STEMI", NSTEMI: "NSTEMI", HFrEF: "HFrEF", HFmrEF: "HFmrEF", HFpEF: "HFpEF", HFimpEF: "HFimpEF",
    post_mi: "Post-MI", post_pci: "Post-PCI", post_cabg: "Post-CABG", cto: "CTO", ckd: "CKD", pad: "PAD",
    stroke_tia: "Stroke / TIA", established_cad: "Established CAD", ldl_c: "LDL-C", elevated_lpa: "Elevated Lp(a)", dlcn: "Dutch Lipid Clinic Network",
    pci: "PCI", cabg: "CABG", pci_planned: "PCI planned", cabg_planned: "CABG planned", previous_mi: "Previous MI",
    previous_pci: "Previous PCI", previous_cabg: "Previous CABG", extreme_a: "Extreme (A)", extreme_b: "Extreme (B)",
  };
  if (special[c]) return special[c];
  const s = c.replace(/_/g, " ");
  return s.charAt(0).toUpperCase() + s.slice(1);
}

export const HF_OPTIONS = {
  hf_status_at_enrolment: o("newly_diagnosed", "prevalent", "post_discharge"),
  primary_aetiology: o("ischaemic", "dilated_non_ischaemic", "hypertensive", "valvular", "rheumatic_valvular",
    "tachycardia_induced", "peripartum", "myocarditis", "infiltrative", "hypertrophic", "chemotherapy_related",
    "alcohol_related", "congenital", "other", "unknown"),
  baseline_phenotype: o("HFrEF", "HFmrEF", "HFpEF", "HFimpEF"),
};
export const LIPID_OPTIONS = {
  prevention_type: o("primary", "secondary"),
  categories: o("primary_prevention", "secondary_prevention", "established_cad", "post_mi", "post_pci", "post_cabg",
    "diabetes", "familial_hypercholesterolaemia", "elevated_lpa", "statin_intolerance", "ckd", "stroke_tia", "pad"),
  fh_diagnosis_basis: o("dlcn", "simon_broome", "genetic", "clinical"),
  statin_intolerance_type: o("partial", "complete"),
  baseline_ldl_kind: o("untreated", "on_treatment_at_enrolment", "imputed_untreated"),
  baseline_statin_intensity: o("none", "low", "moderate", "high"),
  lpa_unit: [["nmol/L", "nmol/L"], ["mg/dL", "mg/dL"]] as [string, string][],
};
export const CAD_OPTIONS = {
  presentation: o("chronic_coronary_syndrome", "STEMI", "NSTEMI", "unstable_angina", "prior_mi_stable",
    "prior_revascularisation_stable", "other"),
  categories: o("chronic_coronary_syndrome", "acute_coronary_syndrome", "STEMI", "NSTEMI", "unstable_angina",
    "previous_mi", "previous_pci", "previous_cabg", "multivessel", "left_main", "cto", "bifurcation"),
  killip_class_at_presentation: o("I", "II", "III", "IV"),
  ccs_class_at_enrolment: [["0", "0 (no angina)"], ["I", "I"], ["II", "II"], ["III", "III"], ["IV", "IV"]] as [string, string][],
  initial_strategy: o("medical", "pci", "cabg", "pci_planned", "cabg_planned", "hybrid"),
};

export const SCHEDULE_LABEL: Record<ScheduleItem["status"], string> = {
  done: "done", due: "due now", overdue: "overdue", not_due: "upcoming", missed: "missed", not_applicable: "not applicable",
};

export const SOURCE_LABEL: Record<string, string> = {
  entered: "entered", emr_derived: "from chart", calculated: "calculated",
};

export const VALUE_STATUS_LABEL: Record<string, string> = {
  present: "Value", not_done: "Not done", unknown: "Unknown", not_applicable: "Not applicable", declined: "Declined",
};

/** A dictionary option's label, tidied: some dictionaries repeat the code in lower case. */
export function optionLabel(a: { code: string; label: string }): string {
  if (!a.label || a.label === a.code || a.label === a.code.replace(/_/g, " ")) return humanCode(a.code);
  return a.label.charAt(0).toUpperCase() + a.label.slice(1);
}

/** What a value shows read-only. */
export function valueText(d: VariableDefinition, v: VariableValue | null | undefined): string {
  if (!v) return "";
  if (v.value_status !== "present") return VALUE_STATUS_LABEL[v.value_status] ?? v.value_status;
  const label = (code: string) => {
    const a = d.allowed_values?.find((x) => x.code === code);
    return a ? optionLabel(a) : humanCode(code);
  };
  if (v.value === null || v.value === undefined) return "";
  if (d.data_type === "boolean") return v.value ? "Yes" : "No";
  if (d.data_type === "coded") return label(String(v.value));
  if (d.data_type === "multi_coded") return (v.value as string[]).map(label).join(", ");
  if (d.data_type === "numeric" || d.data_type === "integer") {
    const shown = `${Number(v.value).toLocaleString("en-IN", { maximumFractionDigits: 2 })}${d.unit ? ` ${d.unit}` : ""}`;
    return v.entered_unit && v.entered_unit !== d.unit ? `${shown} (entered ${v.entered_value} ${v.entered_unit})` : shown;
  }
  return String(v.value);
}

/** A draft value typed in the form, turned into what the API takes; undefined when it is empty. */
export function parseDraft(d: VariableDefinition, raw: string | string[] | boolean | null):
  { value: unknown } | { error: string } | undefined {
  if (raw === null || raw === "" || (Array.isArray(raw) && raw.length === 0)) return undefined;
  switch (d.data_type) {
    case "numeric":
    case "integer": {
      const n = Number(String(raw).replace(",", "."));
      if (!Number.isFinite(n)) return { error: "Enter a number" };
      if (d.data_type === "integer" && !Number.isInteger(n)) return { error: "Enter a whole number" };
      return { value: n };
    }
    case "boolean":
      return { value: raw === true || raw === "true" };
    case "multi_coded":
      return { value: raw as string[] };
    case "date":
      return /^\d{4}-\d{2}-\d{2}$/.test(String(raw)) ? { value: raw } : { error: "Enter a date" };
    default:
      return { value: String(raw).trim() };
  }
}

/** Whether a stored value differs from what is on screen (so saving it needs a change reason). */
export function sameValue(a: unknown, b: unknown): boolean {
  if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((x, i) => x === b[i]);
  return a === b;
}
