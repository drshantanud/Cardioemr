"use client";
import { useState } from "react";
import { formatDate } from "@/lib/format";
import { CAD_OPTIONS, HF_OPTIONS, LIPID_OPTIONS } from "@/lib/registry";
import type { ClinicalSummary } from "@/lib/types";
import { Field } from "./ui";

type Values = Record<string, string | string[] | boolean>;

function Select({ id, label, value, options, onChange, required, className = "span-3", hint }: {
  id: string; label: string; value: string; options: [string, string][]; onChange: (v: string) => void;
  required?: boolean; className?: string; hint?: string;
}) {
  return (
    <Field label={label} htmlFor={id} required={required} className={className} hint={hint}>
      <select id={id} className="input" value={value} onChange={(e) => onChange(e.target.value)}>
        <option value="">—</option>
        {options.map(([c, l]) => <option key={c} value={c}>{l}</option>)}
      </select>
    </Field>
  );
}

function Chips({ label, options, value, onChange, required }: {
  label: string; options: [string, string][]; value: string[]; onChange: (v: string[]) => void; required?: boolean;
}) {
  return (
    <div className="field span-6">
      <span className="label">{label}{required && <span className="req" aria-hidden>*</span>}</span>
      <div className="chips" role="group" aria-label={label}>
        {options.map(([c, l]) => {
          const on = value.includes(c);
          return (
            <button key={c} type="button" className="chip" aria-pressed={on}
              onClick={() => onChange(on ? value.filter((x) => x !== c) : [...value, c])}>{l}</button>
          );
        })}
      </div>
    </div>
  );
}

export function phenotypeFor(lvef: number | null, priorLowest: number | null): string {
  if (lvef === null) return "";
  if (priorLowest !== null && priorLowest <= 40 && lvef > 40) return "HFimpEF";
  return lvef <= 40 ? "HFrEF" : lvef < 50 ? "HFmrEF" : "HFpEF";
}

function initial(registry: string, s: ClinicalSummary | null): Values {
  const lab = (c: string) => s?.latest_labs.find((l) => l.analyte_code === c);
  if (registry === "HF") {
    const lvef = s?.latest_echo?.lvef ?? null;
    return { hf_status_at_enrolment: "", primary_aetiology: "", baseline_lvef: lvef !== null ? String(lvef) : "",
      prior_lowest_lvef: "", baseline_phenotype: phenotypeFor(lvef, null), hf_diagnosis_date: "",
      index_admission_date: "", index_discharge_date: "" };
  }
  if (registry === "LIPID") {
    const ldl = lab("LDL_C");
    const lpa = lab("LPA_NMOL_L") ?? lab("LPA_MG_DL");
    const onLlt = !!s?.medications.some((m) => m.status === "active" && /statin|ezetimibe|evolocumab|alirocumab|inclisiran|bempedoic/i.test(m.generic_name));
    return { prevention_type: "", categories: [], fh_diagnosis_basis: "", dlcn_score: "", statin_intolerance_type: "",
      baseline_ldl_kind: onLlt ? "on_treatment_at_enrolment" : "", baseline_ldl_mg_dl: ldl?.value_canonical != null ? String(ldl.value_canonical) : "",
      baseline_on_llt: onLlt, baseline_statin_intensity: "",
      lpa_value: lpa?.value_reported != null ? String(lpa.value_reported) : "",
      lpa_unit: lpa ? (lpa.analyte_code === "LPA_NMOL_L" ? "nmol/L" : "mg/dL") : "" };
  }
  return { presentation: "", categories: [], index_event_date: "", killip_class_at_presentation: "", ccs_class_at_enrolment: "",
    initial_strategy: "" };
}

/** What the API's enrol call takes as details, or the first thing still missing. */
export function detailsBody(registry: string, v: Values): { details: Record<string, unknown> } | { missing: string } {
  const str = (k: string) => (typeof v[k] === "string" && (v[k] as string).trim()) || undefined;
  const num = (k: string) => (str(k) !== undefined ? Number(str(k)) : undefined);
  const need = (pairs: [string, string][]) => pairs.find(([k]) => {
    const x = v[k];
    return Array.isArray(x) ? x.length === 0 : x === "" || x === undefined;
  })?.[1];
  if (registry === "HF") {
    const m = need([["hf_status_at_enrolment", "HF status at enrolment"], ["primary_aetiology", "primary aetiology"],
      ["baseline_phenotype", "baseline phenotype"]]) ?? (v.hf_status_at_enrolment === "post_discharge" && !str("index_discharge_date") ? "discharge date" : undefined)
      ?? (v.baseline_phenotype === "HFimpEF" && !str("prior_lowest_lvef") ? "prior lowest LVEF (needed for HFimpEF)" : undefined);
    if (m) return { missing: m };
    return { details: { registry_code: "HF", hf_status_at_enrolment: str("hf_status_at_enrolment"),
      hf_diagnosis_date: str("hf_diagnosis_date"), index_admission_date: str("index_admission_date"),
      index_discharge_date: str("index_discharge_date"), primary_aetiology: str("primary_aetiology"),
      baseline_lvef: num("baseline_lvef"), prior_lowest_lvef: num("prior_lowest_lvef"),
      baseline_phenotype: str("baseline_phenotype") } };
  }
  if (registry === "LIPID") {
    const cats = v.categories as string[];
    const m = need([["prevention_type", "prevention type"], ["categories", "at least one category"],
      ["baseline_ldl_kind", "baseline LDL-C kind"]])
      ?? (cats.includes("familial_hypercholesterolaemia") && !str("fh_diagnosis_basis") ? "how FH was diagnosed" : undefined)
      ?? (cats.includes("statin_intolerance") && !str("statin_intolerance_type") ? "statin intolerance type" : undefined)
      ?? (!!str("lpa_value") !== !!str("lpa_unit") ? "the Lp(a) unit" : undefined);
    if (m) return { missing: m };
    return { details: { registry_code: "LIPID", prevention_type: str("prevention_type"), categories: cats,
      fh_diagnosis_basis: str("fh_diagnosis_basis"), dlcn_score: num("dlcn_score"),
      statin_intolerance_type: str("statin_intolerance_type"), baseline_ldl_kind: str("baseline_ldl_kind"),
      baseline_ldl_mg_dl: num("baseline_ldl_mg_dl"), baseline_on_llt: !!v.baseline_on_llt,
      baseline_statin_intensity: str("baseline_statin_intensity"), lpa_value: num("lpa_value"), lpa_unit: str("lpa_unit") } };
  }
  const m = need([["presentation", "presentation"], ["index_event_date", "index event date"]]);
  if (m) return { missing: m };
  return { details: { registry_code: "CAD", presentation: str("presentation"), categories: v.categories,
    index_event_date: str("index_event_date"), killip_class_at_presentation: str("killip_class_at_presentation"),
    ccs_class_at_enrolment: str("ccs_class_at_enrolment"), initial_strategy: str("initial_strategy") } };
}

export function useEnrolDetails(registry: string, summary: ClinicalSummary | null) {
  const [v, setV] = useState<Values>(() => initial(registry, summary));
  const [seeded, setSeeded] = useState(!!summary);
  if (!seeded && summary) {
    setSeeded(true);
    setV(initial(registry, summary));
  }
  return [v, setV] as const;
}

/** The registry-specific baseline asked for at enrolment. Values found in the chart are filled in to check. */
export function EnrolDetailsForm({ registry, v, set, summary }: {
  registry: string; v: Values; set: (v: Values) => void; summary: ClinicalSummary | null;
}) {
  const s = (k: string) => (v[k] as string) ?? "";
  const up = (k: string) => (x: string | string[] | boolean) => {
    const next = { ...v, [k]: x };
    if (registry === "HF" && (k === "baseline_lvef" || k === "prior_lowest_lvef")) {
      const p = phenotypeFor(next.baseline_lvef ? Number(next.baseline_lvef) : null,
        next.prior_lowest_lvef ? Number(next.prior_lowest_lvef) : null);
      if (p) next.baseline_phenotype = p;
    }
    set(next);
  };
  const echo = summary?.latest_echo;
  const ldl = summary?.latest_labs.find((l) => l.analyte_code === "LDL_C");

  if (registry === "HF") {
    return (
      <div className="form-grid">
        <Select id="hf-status" label="HF status at enrolment" required value={s("hf_status_at_enrolment")} options={HF_OPTIONS.hf_status_at_enrolment} onChange={up("hf_status_at_enrolment")} />
        <Field label="HF first diagnosed" htmlFor="hf-dx" className="span-3">
          <input id="hf-dx" type="date" className="input" value={s("hf_diagnosis_date")} onChange={(e) => up("hf_diagnosis_date")(e.target.value)} />
        </Field>
        {s("hf_status_at_enrolment") === "post_discharge" && (
          <>
            <Field label="Admitted" htmlFor="hf-adm" className="span-3">
              <input id="hf-adm" type="date" className="input" value={s("index_admission_date")} onChange={(e) => up("index_admission_date")(e.target.value)} />
            </Field>
            <Field label="Discharged" htmlFor="hf-dis" required className="span-3">
              <input id="hf-dis" type="date" className="input" value={s("index_discharge_date")} onChange={(e) => up("index_discharge_date")(e.target.value)} />
            </Field>
          </>
        )}
        <Select id="hf-aet" label="Primary aetiology" required value={s("primary_aetiology")} options={HF_OPTIONS.primary_aetiology} onChange={up("primary_aetiology")} />
        <Field label="Baseline LVEF (%)" htmlFor="hf-lvef" className="span-1"
          hint={echo?.lvef != null ? `Echo ${formatDate(echo.performed_on)}: ${echo.lvef}%` : undefined}>
          <input id="hf-lvef" className="input" inputMode="decimal" value={s("baseline_lvef")} onChange={(e) => up("baseline_lvef")(e.target.value)} />
        </Field>
        <Field label="Lowest LVEF before (%)" htmlFor="hf-prior" className="span-2" hint="Needed to call HFimpEF">
          <input id="hf-prior" className="input" inputMode="decimal" value={s("prior_lowest_lvef")} onChange={(e) => up("prior_lowest_lvef")(e.target.value)} />
        </Field>
        <Select id="hf-pheno" label="Baseline phenotype" required value={s("baseline_phenotype")} options={HF_OPTIONS.baseline_phenotype}
          onChange={up("baseline_phenotype")} hint="Suggested from LVEF; you confirm it by enrolling" />
      </div>
    );
  }
  if (registry === "LIPID") {
    const cats = (v.categories as string[]) ?? [];
    return (
      <div className="form-grid">
        <Select id="lp-prev" label="Prevention" required value={s("prevention_type")} options={LIPID_OPTIONS.prevention_type} onChange={up("prevention_type")} />
        <Select id="lp-kind" label="Baseline LDL-C is" required value={s("baseline_ldl_kind")} options={LIPID_OPTIONS.baseline_ldl_kind} onChange={up("baseline_ldl_kind")} />
        <Chips label="Categories" required options={LIPID_OPTIONS.categories} value={cats} onChange={up("categories")} />
        {cats.includes("familial_hypercholesterolaemia") && (
          <>
            <Select id="lp-fh" label="FH diagnosed by" required value={s("fh_diagnosis_basis")} options={LIPID_OPTIONS.fh_diagnosis_basis} onChange={up("fh_diagnosis_basis")} />
            <Field label="DLCN score" htmlFor="lp-dlcn" className="span-1">
              <input id="lp-dlcn" className="input" inputMode="numeric" value={s("dlcn_score")} onChange={(e) => up("dlcn_score")(e.target.value)} />
            </Field>
          </>
        )}
        {cats.includes("statin_intolerance") && (
          <Select id="lp-int" label="Statin intolerance" required value={s("statin_intolerance_type")} options={LIPID_OPTIONS.statin_intolerance_type} onChange={up("statin_intolerance_type")} />
        )}
        <Field label="Baseline LDL-C (mg/dL)" htmlFor="lp-ldl" className="span-2"
          hint={ldl ? `Lab ${formatDate(ldl.collected_at)}: ${ldl.value_reported} ${ldl.unit_reported ?? ""}` : undefined}>
          <input id="lp-ldl" className="input" inputMode="decimal" value={s("baseline_ldl_mg_dl")} onChange={(e) => up("baseline_ldl_mg_dl")(e.target.value)} />
        </Field>
        <label className="check span-2 align-end">
          <input type="checkbox" checked={!!v.baseline_on_llt} onChange={(e) => up("baseline_on_llt")(e.target.checked)} /> On lipid-lowering therapy
        </label>
        <Select id="lp-int2" label="Statin intensity at baseline" value={s("baseline_statin_intensity")} options={LIPID_OPTIONS.baseline_statin_intensity}
          onChange={up("baseline_statin_intensity")} className="span-2" />
        <Field label="Lp(a)" htmlFor="lp-lpa" className="span-2">
          <input id="lp-lpa" className="input" inputMode="decimal" value={s("lpa_value")} onChange={(e) => up("lpa_value")(e.target.value)} />
        </Field>
        <Select id="lp-lpau" label="Lp(a) unit" value={s("lpa_unit")} options={LIPID_OPTIONS.lpa_unit} onChange={up("lpa_unit")} className="span-2"
          hint="Not convertible; kept as reported" />
      </div>
    );
  }
  return (
    <div className="form-grid">
      <Select id="cad-pres" label="Presentation" required value={s("presentation")} options={CAD_OPTIONS.presentation} onChange={up("presentation")} />
      <Field label="Index event date" htmlFor="cad-date" required className="span-3">
        <input id="cad-date" type="date" className="input" value={s("index_event_date")} onChange={(e) => up("index_event_date")(e.target.value)} />
      </Field>
      <Chips label="Categories" options={CAD_OPTIONS.categories} value={(v.categories as string[]) ?? []} onChange={up("categories")} />
      <Select id="cad-killip" label="Killip class at presentation" value={s("killip_class_at_presentation")} options={CAD_OPTIONS.killip_class_at_presentation}
        onChange={up("killip_class_at_presentation")} className="span-2" />
      <Select id="cad-ccs" label="CCS class at enrolment" value={s("ccs_class_at_enrolment")} options={CAD_OPTIONS.ccs_class_at_enrolment}
        onChange={up("ccs_class_at_enrolment")} className="span-2" />
      <Select id="cad-strat" label="Initial strategy" value={s("initial_strategy")} options={CAD_OPTIONS.initial_strategy}
        onChange={up("initial_strategy")} className="span-2" />
    </div>
  );
}
