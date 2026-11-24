import { describe, expect, it } from "vitest";
import { detailsBody, phenotypeFor } from "@/components/EnrolDetailsForm";
import { criteria, eligibilityFrom, optionLabel, parseDraft, sameValue, valueText } from "@/lib/registry";
import type { VariableDefinition, VariableValue } from "@/lib/types";

const proto = { inclusion_text: "Age >= 18; clinician-diagnosed HF", exclusion_text: "Unable to consent", inclusion_rules: [], exclusion_rules: [] };

function def(over: Partial<VariableDefinition>): VariableDefinition {
  return { variable_code: "x", definition_version: 1, category: "C", variable_label: "X", data_type: "numeric", unit: "mg/dL",
    allowed_values: null, min_value: null, max_value: null, source_kind: "entered", emr_source: null, visit_code: "BL",
    requirement: "optional", condition_text: null, accepted_units: null, ...over };
}
function val(over: Partial<VariableValue>): VariableValue {
  return { variable_code: "x", value_status: "present", value: null, source_kind: "entered", source_table: null, source_row_id: null,
    verification_status: "unverified", entered_value: null, entered_unit: null, updated_at: null, row_version: 1, ...over };
}

describe("screening checklist", () => {
  it("splits the protocol text into criteria", () => {
    const c = criteria(proto);
    expect(c.map((x) => [x.code, x.kind])).toEqual([["INC_1", "inclusion"], ["INC_2", "inclusion"], ["EXC_1", "exclusion"]]);
  });
  it("is eligible only when every inclusion is yes and every exclusion no", () => {
    const c = criteria(proto);
    expect(eligibilityFrom(c, { INC_1: "yes", INC_2: "yes" })).toBe("incomplete");
    expect(eligibilityFrom(c, { INC_1: "yes", INC_2: "yes", EXC_1: "no" })).toBe("eligible");
    expect(eligibilityFrom(c, { INC_1: "no", INC_2: "yes", EXC_1: "no" })).toBe("ineligible");
    expect(eligibilityFrom(c, { INC_1: "unknown", INC_2: "yes", EXC_1: "no" })).toBe("incomplete");
  });
});

describe("enrolment details", () => {
  it("suggests the HF phenotype from LVEF", () => {
    expect(phenotypeFor(30, null)).toBe("HFrEF");
    expect(phenotypeFor(45, null)).toBe("HFmrEF");
    expect(phenotypeFor(55, null)).toBe("HFpEF");
    expect(phenotypeFor(48, 30)).toBe("HFimpEF");
  });
  it("says what is still missing", () => {
    expect(detailsBody("HF", { hf_status_at_enrolment: "post_discharge", primary_aetiology: "ischaemic", baseline_phenotype: "HFrEF",
      index_discharge_date: "" })).toEqual({ missing: "discharge date" });
    expect(detailsBody("LIPID", { prevention_type: "primary", categories: ["familial_hypercholesterolaemia"], baseline_ldl_kind: "untreated",
      fh_diagnosis_basis: "" })).toEqual({ missing: "how FH was diagnosed" });
    const ok = detailsBody("CAD", { presentation: "STEMI", index_event_date: "2026-11-01", categories: ["STEMI"] });
    expect("details" in ok && ok.details.registry_code).toBe("CAD");
  });
});

describe("assessment values", () => {
  it("parses typed values by data type", () => {
    expect(parseDraft(def({ data_type: "integer" }), "72")).toEqual({ value: 72 });
    expect(parseDraft(def({ data_type: "integer" }), "7.5")).toEqual({ error: "Enter a whole number" });
    expect(parseDraft(def({ data_type: "numeric" }), "3,5")).toEqual({ value: 3.5 });
    expect(parseDraft(def({ data_type: "numeric" }), "")).toBeUndefined();
    expect(parseDraft(def({ data_type: "boolean" }), false)).toEqual({ value: false });
    expect(parseDraft(def({ data_type: "date" }), "23/11/2026")).toEqual({ error: "Enter a date" });
  });
  it("shows values read-only, including a converted unit", () => {
    const ldl = def({ unit: "mg/dL" });
    expect(valueText(ldl, val({ value: 88 }))).toBe("88 mg/dL");
    expect(valueText(ldl, val({ value: 88.9, entered_value: 2.3, entered_unit: "mmol/L" }))).toBe("88.9 mg/dL (entered 2.3 mmol/L)");
    expect(valueText(ldl, val({ value_status: "not_done" }))).toBe("Not done");
    const coded = def({ data_type: "coded", allowed_values: [{ code: "dilated_non_ischaemic", label: "dilated non ischaemic" }] });
    expect(valueText(coded, val({ value: "dilated_non_ischaemic" }))).toBe("Dilated non ischaemic");
    expect(optionLabel({ code: "I", label: "NYHA I" })).toBe("NYHA I");
    expect(sameValue(["a", "b"], ["a", "b"])).toBe(true);
  });
});
