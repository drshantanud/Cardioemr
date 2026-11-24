"use client";
import type { ReactNode } from "react";
import {
  label, newLesion, newStent, PCI_OPTIONS, type LesionDraft, type PciDraft, type PciErrors, type StentDraft,
} from "@/lib/cad";
import { Field } from "./ui";

type Opt = [string, string][];

function Select({ id, labelText, value, options, onChange, required, error, className, blank = "—", hint }: {
  id: string; labelText: string; value: string; options: Opt; onChange: (v: string) => void; required?: boolean;
  error?: string; className?: string; blank?: string | null; hint?: string;
}) {
  return (
    <Field label={labelText} htmlFor={id} required={required} error={error} hint={hint} className={className ?? "span-2"}>
      <select id={id} className="input" value={value} aria-invalid={error ? true : undefined} onChange={(e) => onChange(e.target.value)}>
        {blank !== null && <option value="">{blank}</option>}
        {options.map(([c, l]) => <option key={c} value={c}>{l}</option>)}
      </select>
    </Field>
  );
}

function Num({ id, labelText, value, onChange, error, unit, required, className }: {
  id: string; labelText: string; value: string; onChange: (v: string) => void; error?: string; unit?: string;
  required?: boolean; className?: string;
}) {
  return (
    <Field label={unit ? `${labelText} (${unit})` : labelText} htmlFor={id} error={error} required={required} className={className ?? "span-1"}>
      <input id={id} className="input" inputMode="decimal" value={value} aria-invalid={error ? true : undefined}
        onChange={(e) => onChange(e.target.value)} />
    </Field>
  );
}

const YES_NO: Opt = [["yes", "Yes"], ["no", "No"]];

function Chips({ labelText, options, value, onChange, error }: {
  labelText: string; options: Opt; value: string[]; onChange: (v: string[]) => void; error?: string;
}) {
  return (
    <div className="field span-6">
      <span className="label">{labelText}</span>
      <div className="chips" role="group" aria-label={labelText}>
        {options.map(([c, l]) => {
          const on = value.includes(c);
          return (
            <button key={c} type="button" className="chip" aria-pressed={on}
              onClick={() => onChange(on ? value.filter((x) => x !== c) : c === "none" ? ["none"] : [...value.filter((x) => x !== "none"), c])}>
              {l}
            </button>
          );
        })}
      </div>
      {error && <span className="err">{error}</span>}
    </div>
  );
}

function Check({ checked, onChange, children }: { checked: boolean; onChange: (v: boolean) => void; children: ReactNode }) {
  return (
    <label className="check span-2 align-end">
      <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} /> {children}
    </label>
  );
}

function StentRow({ lesion, s, set, remove, errors, locked }: {
  lesion: number; s: StentDraft; set: (s: StentDraft) => void; remove?: () => void; errors: PciErrors; locked: boolean;
}) {
  const k = `lesion.${lesion}.stent.${s.sequence_number}`;
  const id = `l${lesion}-s${s.sequence_number}`;
  const up = <K extends keyof StentDraft>(f: K) => (v: StentDraft[K]) => set({ ...s, [f]: v });
  return (
    <div className="stent-row">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <strong className="small">Stent {s.sequence_number}</strong>
        {remove && !locked && <button type="button" className="link-button small" onClick={remove}>Remove stent</button>}
      </div>
      <div className="form-grid">
        <Field label="Make and model" htmlFor={`${id}-dev`} required error={errors[`${k}.device_text`]} className="span-3"
          hint={s.stent_id ? undefined : "e.g. Xience Sierra"}>
          <input id={`${id}-dev`} className="input" value={s.device_text} onChange={(e) => up("device_text")(e.target.value)}
            aria-invalid={errors[`${k}.device_text`] ? true : undefined} />
        </Field>
        <Num id={`${id}-dia`} labelText="Diameter" unit="mm" required value={s.diameter_mm} onChange={up("diameter_mm")} error={errors[`${k}.diameter_mm`]} />
        <Num id={`${id}-len`} labelText="Length" unit="mm" required value={s.length_mm} onChange={up("length_mm")} error={errors[`${k}.length_mm`]} />
        <Num id={`${id}-atm`} labelText="Pressure" unit="atm" value={s.deployment_atm} onChange={up("deployment_atm")} error={errors[`${k}.deployment_atm`]} />
        <Num id={`${id}-post`} labelText="Post-dilatation balloon" unit="mm" value={s.post_dilatation_balloon_mm}
          onChange={up("post_dilatation_balloon_mm")} className="span-2" />
      </div>
    </div>
  );
}

function LesionCard({ l, set, remove, errors, locked }: {
  l: LesionDraft; set: (l: LesionDraft) => void; remove?: () => void; errors: PciErrors; locked: boolean;
}) {
  const k = `lesion.${l.lesion_number}`;
  const id = `l${l.lesion_number}`;
  const up = <K extends keyof LesionDraft>(f: K) => (v: LesionDraft[K]) => set({ ...l, [f]: v });
  const nextStent = Math.max(0, ...l.stents.map((s) => s.sequence_number)) + 1;
  return (
    <fieldset className="lesion-card" aria-label={`Lesion ${l.lesion_number}`}>
      <legend>
        Lesion {l.lesion_number}{l.vessel ? ` · ${label(PCI_OPTIONS.vessel, l.vessel)}` : ""}
      </legend>
      {remove && !locked && (
        <button type="button" className="link-button small lesion-remove" onClick={remove}>Remove lesion</button>
      )}
      <div className="form-grid">
        <Select id={`${id}-vessel`} labelText="Vessel" required value={l.vessel} options={PCI_OPTIONS.vessel} onChange={up("vessel")}
          error={errors[`${k}.vessel`]} blank="Choose…" />
        <Field label="Segment" htmlFor={`${id}-seg`} className="span-1" hint="SYNTAX number">
          <input id={`${id}-seg`} className="input" value={l.segment_code} onChange={(e) => up("segment_code")(e.target.value)} />
        </Field>
        <Select id={`${id}-type`} labelText="ACC/AHA type" value={l.lesion_type_acc_aha} options={PCI_OPTIONS.lesion_type_acc_aha}
          onChange={up("lesion_type_acc_aha")} className="span-1" />
        <Select id={`${id}-calc`} labelText="Calcification" value={l.calcification} options={PCI_OPTIONS.calcification} onChange={up("calcification")} />
        <Num id={`${id}-len`} labelText="Length" unit="mm" value={l.lesion_length_mm} onChange={up("lesion_length_mm")} error={errors[`${k}.lesion_length_mm`]} />
        <Num id={`${id}-ref`} labelText="Reference diameter" unit="mm" value={l.reference_diameter_mm} onChange={up("reference_diameter_mm")}
          error={errors[`${k}.reference_diameter_mm`]} className="span-2" />
        <Num id={`${id}-pre`} labelText="Stenosis before" unit="%" value={l.pre_stenosis_pct} onChange={up("pre_stenosis_pct")} error={errors[`${k}.pre_stenosis_pct`]} />
        <Select id={`${id}-pretimi`} labelText="TIMI before" value={l.pre_timi_flow} options={PCI_OPTIONS.timi} onChange={up("pre_timi_flow")} className="span-1" />
        <Select id={`${id}-thr`} labelText="Thrombus" value={l.thrombus} options={YES_NO} onChange={(v) => up("thrombus")(v as LesionDraft["thrombus"])} className="span-1" />
        <Check checked={l.is_cto} onChange={up("is_cto")}>Chronic total occlusion</Check>
        <Check checked={l.is_bifurcation} onChange={up("is_bifurcation")}>Bifurcation</Check>
        <Check checked={l.is_in_stent_restenosis} onChange={up("is_in_stent_restenosis")}>In-stent restenosis</Check>
        {l.is_cto && (
          <Num id={`${id}-jcto`} labelText="J-CTO score" value={l.j_cto_score} onChange={up("j_cto_score")} error={errors[`${k}.j_cto_score`]} />
        )}
        {l.is_bifurcation && (
          <>
            <Field label="Medina" htmlFor={`${id}-medina`} required error={errors[`${k}.medina`]} className="span-1" hint="e.g. 1,1,0">
              <input id={`${id}-medina`} className="input" value={l.medina} onChange={(e) => up("medina")(e.target.value.replace(/\s/g, ""))}
                aria-invalid={errors[`${k}.medina`] ? true : undefined} />
            </Field>
            <Select id={`${id}-bif`} labelText="Bifurcation technique" value={l.bifurcation_technique} options={PCI_OPTIONS.bifurcation_technique}
              onChange={up("bifurcation_technique")} />
          </>
        )}
        <Chips labelText={`Lesion preparation, lesion ${l.lesion_number}`} options={PCI_OPTIONS.lesion_preparation}
          value={l.lesion_preparation} onChange={up("lesion_preparation")} />
        <Select id={`${id}-treat`} labelText="Treatment" required value={l.treatment} options={PCI_OPTIONS.treatment} blank={null}
          onChange={(v) => set({ ...l, treatment: v, stents: v === "stent" ? (l.stents.length ? l.stents : [newStent(1)]) : l.stents })} />
        <Select id={`${id}-postdil`} labelText="Post-dilatation" value={l.post_dilatation} options={YES_NO}
          onChange={(v) => up("post_dilatation")(v as LesionDraft["post_dilatation"])} className="span-1" />
        <Num id={`${id}-prephys`} labelText="Physiology before" value={l.pre_physiology_value} onChange={up("pre_physiology_value")} />
        <Num id={`${id}-postphys`} labelText="Physiology after" value={l.post_physiology_value} onChange={up("post_physiology_value")} />
        <Select id={`${id}-finaltimi`} labelText="Final TIMI" value={l.final_timi_flow} options={PCI_OPTIONS.timi} onChange={up("final_timi_flow")} className="span-1" />
        <Num id={`${id}-resid`} labelText="Residual stenosis" unit="%" value={l.residual_stenosis_pct} onChange={up("residual_stenosis_pct")}
          error={errors[`${k}.residual_stenosis_pct`]} />
      </div>
      {l.treatment === "stent" && (
        <div className="stack" style={{ gap: 8, marginTop: 12 }}>
          {errors[`${k}.stents`] && <span className="err small">{errors[`${k}.stents`]}</span>}
          {l.stents.map((s, i) => (
            <StentRow key={s.sequence_number} lesion={l.lesion_number} s={s} errors={errors} locked={locked}
              set={(x) => set({ ...l, stents: l.stents.map((y, j) => (j === i ? x : y)) })}
              remove={!s.stent_id && l.stents.length > 1 ? () => set({ ...l, stents: l.stents.filter((_, j) => j !== i) }) : undefined} />
          ))}
          {!locked && (
            <div>
              <button type="button" className="btn btn-sm" onClick={() => set({ ...l, stents: [...l.stents, newStent(nextStent)] })}>
                Add stent
              </button>
            </div>
          )}
        </div>
      )}
    </fieldset>
  );
}

/** The whole PCI document: procedure, then each lesion with its stents. Saved lesions and stents
 * cannot be removed (the API refuses); a wrong procedure is marked entered in error instead. */
export function PciForm({ draft, set, errors, today, locked = false }: {
  draft: PciDraft; set: (d: PciDraft) => void; errors: PciErrors; today: string; locked?: boolean;
}) {
  const up = <K extends keyof PciDraft>(f: K) => (v: PciDraft[K]) => set({ ...draft, [f]: v });
  const nextLesion = Math.max(0, ...draft.lesions.map((l) => l.lesion_number)) + 1;
  return (
    <div className="stack">
      <section className="form-section">
        <h2>Procedure</h2>
        <div className="form-grid">
          <Field label="Procedure date" htmlFor="pci-date" required error={errors.procedure_date} className="span-2">
            <input id="pci-date" type="date" className="input" value={draft.procedure_date} max={today}
              onChange={(e) => up("procedure_date")(e.target.value)} aria-invalid={errors.procedure_date ? true : undefined} />
          </Field>
          <Select id="pci-ind" labelText="Indication" required value={draft.indication} options={PCI_OPTIONS.indication}
            onChange={up("indication")} error={errors.indication} blank="Choose…" className="span-2" />
          <Select id="pci-urg" labelText="Urgency" value={draft.urgency} options={PCI_OPTIONS.urgency} onChange={up("urgency")} />
          <Select id="pci-access" labelText="Access" value={draft.access_site} options={PCI_OPTIONS.access_site} onChange={up("access_site")} />
          <Select id="pci-img" labelText="Intravascular imaging" value={draft.imaging_guidance} options={PCI_OPTIONS.imaging_guidance}
            onChange={up("imaging_guidance")} blank={null} />
          <Select id="pci-phys" labelText="Physiology" value={draft.physiology} options={PCI_OPTIONS.physiology} onChange={up("physiology")} blank={null} />
          <Select id="pci-mcs" labelText="Mechanical support" value={draft.mechanical_support} options={PCI_OPTIONS.mechanical_support}
            onChange={up("mechanical_support")} />
          <Field label="Operator" htmlFor="pci-op" className="span-2">
            <input id="pci-op" className="input" value={draft.operator_name} onChange={(e) => up("operator_name")(e.target.value)} />
          </Field>
          <Field label="Performed at" htmlFor="pci-fac" className="span-2" hint="If not at this centre">
            <input id="pci-fac" className="input" value={draft.performed_at_facility} onChange={(e) => up("performed_at_facility")(e.target.value)} />
          </Field>
          <Num id="pci-contrast" labelText="Contrast" unit="mL" value={draft.contrast_ml} onChange={up("contrast_ml")} error={errors.contrast_ml} />
          <Num id="pci-fluoro" labelText="Fluoroscopy" unit="min" value={draft.fluoroscopy_min} onChange={up("fluoroscopy_min")} error={errors.fluoroscopy_min} />
          <Select id="pci-success" labelText="Procedural success" value={draft.procedural_success} options={YES_NO}
            onChange={(v) => up("procedural_success")(v as PciDraft["procedural_success"])} />
          <Chips labelText="Complications" options={PCI_OPTIONS.complications} value={draft.complications}
            onChange={up("complications")} error={errors.complications} />
        </div>
      </section>
      <section className="form-section">
        <h2>Lesions</h2>
        {errors.lesions && <span className="err small">{errors.lesions}</span>}
        <div className="stack">
          {draft.lesions.map((l, i) => (
            <LesionCard key={l.lesion_number} l={l} errors={errors} locked={locked}
              set={(x) => set({ ...draft, lesions: draft.lesions.map((y, j) => (j === i ? x : y)) })}
              remove={!l.lesion_id && draft.lesions.length > 1 ? () => set({ ...draft, lesions: draft.lesions.filter((_, j) => j !== i) }) : undefined} />
          ))}
        </div>
        {!locked && (
          <div style={{ marginTop: 12 }}>
            <button type="button" className="btn" onClick={() => set({ ...draft, lesions: [...draft.lesions, newLesion(nextLesion)] })}>
              Add lesion
            </button>
          </div>
        )}
      </section>
    </div>
  );
}
