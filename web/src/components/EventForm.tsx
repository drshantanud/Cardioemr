"use client";
import { EVENT_OPTIONS, EVENT_TYPES, eventAsks, lesionLine, type EventDraft } from "@/lib/cad";
import { formatDate } from "@/lib/format";
import type { PciProcedure } from "@/lib/types";
import { Field } from "./ui";

type Opt = [string, string][];

function Select({ id, text, value, options, onChange, required, error, className, disabled }: {
  id: string; text: string; value: string; options: Opt; onChange: (v: string) => void; required?: boolean; error?: string;
  className?: string; disabled?: boolean;
}) {
  return (
    <Field label={text} htmlFor={id} required={required} error={error} className={className ?? "span-2"}>
      <select id={id} className="input" value={value} disabled={disabled} aria-invalid={error ? true : undefined}
        onChange={(e) => onChange(e.target.value)}>
        <option value="">{required ? "Choose…" : "—"}</option>
        {options.map(([c, l]) => <option key={c} value={c}>{l}</option>)}
      </select>
    </Field>
  );
}

/** Report or correct a clinical event. The type is fixed once reported (correct it by marking the
 * event entered in error and reporting it again). */
export function EventForm({ draft, set, errors, today, typeFixed, procedures }: {
  draft: EventDraft; set: (d: EventDraft) => void; errors: Record<string, string>; today: string; typeFixed?: boolean;
  procedures: PciProcedure[];
}) {
  const up = <K extends keyof EventDraft>(f: K) => (v: EventDraft[K]) => set({ ...draft, [f]: v });
  const asks = eventAsks(draft.event_type);
  const proc = procedures.find((p) => p.procedure_id === draft.pci_procedure_id);
  return (
    <div className="form-grid">
      <Select id="ev-type" text="What happened" required value={draft.event_type} options={EVENT_TYPES} onChange={up("event_type")}
        error={errors.event_type} disabled={typeFixed} className="span-3" />
      <Field label="Date" htmlFor="ev-date" required error={errors.event_date} className="span-2">
        <input id="ev-date" type="date" className="input" value={draft.event_date} max={today} onChange={(e) => up("event_date")(e.target.value)}
          aria-invalid={errors.event_date ? true : undefined} />
      </Field>
      <Field label="Date known to" htmlFor="ev-prec" className="span-1">
        <select id="ev-prec" className="input" value={draft.event_date_precision}
          onChange={(e) => up("event_date_precision")(e.target.value as EventDraft["event_date_precision"])}>
          {EVENT_OPTIONS.precision.map(([c, l]) => <option key={c} value={c}>{l}</option>)}
        </select>
      </Field>
      <label className="check span-6">
        <input type="checkbox" checked={draft.is_historical} onChange={(e) => up("is_historical")(e.target.checked)} />
        {" "}Past history, before this patient came under our care (not counted as a registry outcome)
      </label>

      {asks.death && (
        <>
          <Select id="ev-death" text="Cause of death" required value={draft.death_cause} options={EVENT_OPTIONS.death_cause}
            onChange={up("death_cause")} error={errors.death_cause} />
          {draft.death_cause === "cardiovascular" && (
            <Select id="ev-cvmode" text="Mode of cardiovascular death" value={draft.death_cv_mode} options={EVENT_OPTIONS.death_cv_mode}
              onChange={up("death_cv_mode")} />
          )}
        </>
      )}
      {asks.mi && <Select id="ev-mi" text="MI type (as reported)" value={draft.mi_type} options={EVENT_OPTIONS.mi_type} onChange={up("mi_type")} />}
      {asks.stroke && <Select id="ev-stroke" text="Stroke type" value={draft.stroke_type} options={EVENT_OPTIONS.stroke_type} onChange={up("stroke_type")} />}
      {asks.bleeding && (
        <Field label="Bleeding site" htmlFor="ev-bleed" className="span-2">
          <input id="ev-bleed" className="input" value={draft.bleeding_site} onChange={(e) => up("bleeding_site")(e.target.value)} placeholder="e.g. gastrointestinal" />
        </Field>
      )}
      {asks.potassium && (
        <Field label="Potassium (mmol/L)" htmlFor="ev-k" error={errors.potassium_mmol_l} className="span-1">
          <input id="ev-k" className="input" inputMode="decimal" value={draft.potassium_mmol_l} onChange={(e) => up("potassium_mmol_l")(e.target.value)} />
        </Field>
      )}
      {asks.procedure && procedures.length > 0 && (
        <>
          <Field label="Related PCI" htmlFor="ev-pci" className="span-3">
            <select id="ev-pci" className="input" value={draft.pci_procedure_id}
              onChange={(e) => set({ ...draft, pci_procedure_id: e.target.value, target_lesion_id: "" })}>
              <option value="">—</option>
              {procedures.map((p) => <option key={p.procedure_id} value={p.procedure_id}>PCI {formatDate(p.procedure_date)}</option>)}
            </select>
          </Field>
          {proc && (
            <Field label="Lesion" htmlFor="ev-lesion" className="span-3">
              <select id="ev-lesion" className="input" value={draft.target_lesion_id} onChange={(e) => up("target_lesion_id")(e.target.value)}>
                <option value="">—</option>
                {proc.lesions.map((l) => <option key={l.lesion_id} value={l.lesion_id}>Lesion {l.lesion_number}: {lesionLine(l)}</option>)}
              </select>
            </Field>
          )}
        </>
      )}

      {asks.hospital && !asks.hospitalAlways && (
        <Select id="ev-hosp" text="Admitted to hospital" value={draft.hospitalised} options={[["yes", "Yes"], ["no", "No"]]}
          onChange={(v) => up("hospitalised")(v as EventDraft["hospitalised"])} className="span-2" />
      )}
      {(asks.hospitalAlways || (asks.hospital && draft.hospitalised === "yes")) && (
        <>
          <Field label="Admitted" htmlFor="ev-adm" className="span-2">
            <input id="ev-adm" type="date" className="input" value={draft.admission_date} max={today} onChange={(e) => up("admission_date")(e.target.value)} />
          </Field>
          <Field label="Discharged" htmlFor="ev-dis" error={errors.discharge_date} className="span-2">
            <input id="ev-dis" type="date" className="input" value={draft.discharge_date} max={today} onChange={(e) => up("discharge_date")(e.target.value)} />
          </Field>
        </>
      )}
      <Field label="Hospital or place" htmlFor="ev-fac" className="span-3">
        <input id="ev-fac" className="input" value={draft.facility_name} onChange={(e) => up("facility_name")(e.target.value)} />
      </Field>
      <Select id="ev-source" text="Where this came from" required value={draft.source} options={EVENT_OPTIONS.source}
        onChange={up("source")} error={errors.source} className="span-3" />
      <Select id="ev-sev" text="Severity" value={draft.severity} options={EVENT_OPTIONS.severity} onChange={up("severity")} />
      <Select id="ev-out" text="Outcome" value={draft.outcome} options={EVENT_OPTIONS.outcome} onChange={up("outcome")} />
      <Field label="Description" htmlFor="ev-desc" className="span-6" hint="Adjudicators read this; leave out the patient's name">
        <textarea id="ev-desc" className="input" rows={3} value={draft.description} onChange={(e) => up("description")(e.target.value)} />
      </Field>
    </div>
  );
}
