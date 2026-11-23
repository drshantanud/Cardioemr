"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError } from "@/lib/api";
import { formatDate } from "@/lib/format";
import { DOSE_UNITS, FREQUENCIES, ROUTES, courseLine, dailyDose, doseLine, eventLabel } from "@/lib/meds";
import { useSession } from "@/lib/session";
import type { Concept, Drug, MedicationCourse } from "@/lib/types";
import { ErrorBanner, Field, Loading, StatusBadge } from "./ui";

interface DoseValues {
  product_id: string;
  strength: string;
  strength_label: string;
  dose_quantity: string;
  dose_unit: string;
  frequency_code: string;
  doses_per_day: string;
  route: string;
  duration_days: string;
  instructions: string;
}

function emptyDose(drug?: Pick<Drug, "default_route" | "products">): DoseValues {
  return {
    product_id: drug?.products[0]?.product_id ?? "", strength: "", strength_label: "", dose_quantity: "1",
    dose_unit: "tablet", frequency_code: "OD", doses_per_day: "", route: drug?.default_route ?? "oral",
    duration_days: "", instructions: "",
  };
}

function doseFrom(c: MedicationCourse): DoseValues {
  const d = c.current_dose;
  return {
    product_id: "", strength: "", strength_label: d?.strength_label ?? "",
    dose_quantity: d?.dose_quantity ? String(d.dose_quantity) : "1", dose_unit: d?.dose_unit ?? "tablet",
    frequency_code: d?.frequency_code ?? "OD", doses_per_day: "", route: d?.route ?? c.default_route,
    duration_days: "", instructions: d?.instructions ?? "",
  };
}

/** Converts the form to the API's dose object. */
export function doseBody(v: DoseValues): Record<string, unknown> {
  const n = (s: string) => (s.trim() === "" ? undefined : Number(s));
  const byStrength = v.dose_unit !== "mg" && v.dose_unit !== "mcg";
  return {
    product_id: byStrength && v.product_id ? v.product_id : undefined,
    strength: byStrength && !v.product_id ? n(v.strength) : undefined,
    strength_label: byStrength && !v.product_id && v.strength_label.trim() ? v.strength_label.trim() : undefined,
    dose_quantity: Number(v.dose_quantity),
    dose_unit: v.dose_unit,
    frequency_code: v.frequency_code,
    doses_per_day: ["SOS", "other"].includes(v.frequency_code) ? n(v.doses_per_day) : undefined,
    route: v.route || undefined,
    duration_days: n(v.duration_days),
    instructions: v.instructions.trim() || undefined,
  };
}

function DoseForm({ v, set, products, unit, idPrefix }: {
  v: DoseValues; set: (v: DoseValues) => void; products: Drug["products"]; unit: string; idPrefix: string;
}) {
  const f = (k: keyof DoseValues) => ({
    id: `${idPrefix}-${k}`, className: "input", value: v[k],
    onChange: (e: { target: { value: string } }) => set({ ...v, [k]: e.target.value }),
  });
  const byStrength = v.dose_unit !== "mg" && v.dose_unit !== "mcg";
  return (
    <div className="form-grid">
      {byStrength && products.length > 0 && (
        <Field label="Strength" htmlFor={`${idPrefix}-product_id`} className="span-2">
          <select {...f("product_id")}>
            {products.map((p) => (
              <option key={p.product_id} value={p.product_id}>
                {p.strength_label}{p.brand_name !== "Generic" ? ` (${p.brand_name})` : ""}
              </option>
            ))}
            <option value="">Other strength…</option>
          </select>
        </Field>
      )}
      {byStrength && (!products.length || !v.product_id) && (
        <>
          <Field label={`Strength per ${v.dose_unit} (${unit})`} htmlFor={`${idPrefix}-strength`} className="span-2">
            <input inputMode="decimal" {...f("strength")} placeholder="e.g. 5" />
          </Field>
          <Field label="Label as printed" htmlFor={`${idPrefix}-strength_label`} className="span-2" hint="Optional">
            <input {...f("strength_label")} placeholder="e.g. 49/51 mg" />
          </Field>
        </>
      )}
      <Field label="Dose" htmlFor={`${idPrefix}-dose_quantity`} className="span-1">
        <input inputMode="decimal" {...f("dose_quantity")} />
      </Field>
      <Field label="Unit" htmlFor={`${idPrefix}-dose_unit`} className="span-1">
        <select {...f("dose_unit")}>{DOSE_UNITS.map((u) => <option key={u} value={u}>{u}</option>)}</select>
      </Field>
      <Field label="How often" htmlFor={`${idPrefix}-frequency_code`} className="span-2">
        <select {...f("frequency_code")}>{FREQUENCIES.map(([c, l]) => <option key={c} value={c}>{c} · {l}</option>)}</select>
      </Field>
      {["SOS", "other"].includes(v.frequency_code) && (
        <Field label="Doses per day (usual)" htmlFor={`${idPrefix}-doses_per_day`} className="span-2">
          <input inputMode="decimal" {...f("doses_per_day")} />
        </Field>
      )}
      <Field label="Route" htmlFor={`${idPrefix}-route`} className="span-1">
        <select {...f("route")}>{ROUTES.map((r) => <option key={r} value={r}>{r}</option>)}</select>
      </Field>
      <Field label="Days" htmlFor={`${idPrefix}-duration_days`} className="span-1" hint="Empty = ongoing">
        <input inputMode="numeric" {...f("duration_days")} />
      </Field>
      <Field label="Instructions" htmlFor={`${idPrefix}-instructions`} className="span-4">
        <input {...f("instructions")} placeholder="e.g. after breakfast" />
      </Field>
    </div>
  );
}

function ReasonPicker({ reasons, code, text, setCode, setText, idPrefix, required }: {
  reasons: Concept[]; code: string; text: string; setCode: (s: string) => void; setText: (s: string) => void;
  idPrefix: string; required?: boolean;
}) {
  return (
    <div className="form-grid">
      <Field label="Reason" htmlFor={`${idPrefix}-reason`} required={required} className="span-3">
        <select id={`${idPrefix}-reason`} className="input" value={code} onChange={(e) => setCode(e.target.value)}>
          <option value="">—</option>
          {reasons.map((r) => <option key={r.concept_code} value={r.concept_code}>{r.display_name}</option>)}
        </select>
      </Field>
      <Field label="Details" htmlFor={`${idPrefix}-reason_text`} className="span-3">
        <input id={`${idPrefix}-reason_text`} className="input" value={text} onChange={(e) => setText(e.target.value)} />
      </Field>
    </div>
  );
}

function DrugSearch({ onPick }: { onPick: (d: Drug) => void }) {
  const { api } = useSession();
  const [q, setQ] = useState("");
  const [items, setItems] = useState<Drug[]>([]);
  useEffect(() => {
    if (q.trim().length < 2) {
      setItems([]);
      return;
    }
    const ctrl = new AbortController();
    const t = setTimeout(() => {
      api<{ items: Drug[] }>("/drugs", { query: { q: q.trim(), limit: 8 }, signal: ctrl.signal })
        .then((r) => setItems(r.data.items)).catch(() => undefined);
    }, 200);
    return () => {
      clearTimeout(t);
      ctrl.abort();
    };
  }, [q, api]);
  return (
    <div className="typeahead">
      <Field label="Medicine" htmlFor="drug-search" required>
        <input id="drug-search" className="input" value={q} onChange={(e) => setQ(e.target.value)} autoFocus
          placeholder="Generic or brand name" autoComplete="off" />
      </Field>
      {items.length > 0 && (
        <ul className="typeahead-list" role="listbox" aria-label="Matching medicines">
          {items.map((d) => (
            <li key={d.drug_code}>
              <button type="button" role="option" aria-selected={false} onClick={() => onPick(d)}>
                <strong>{d.generic_name}</strong>
                <span className="small muted"> {d.classes.map((c) => c.replace(/_/g, " ").toLowerCase()).join(", ")}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

type Action = { kind: "add" } | { kind: "change" | "hold" | "stop"; course: MedicationCourse } | null;

export function MedicationPanel({ patientId, encounterId, canPrescribe, onChanged }: {
  patientId: string; encounterId?: string; canPrescribe: boolean; onChanged?: () => void;
}) {
  const { api } = useSession();
  const [courses, setCourses] = useState<MedicationCourse[] | null>(null);
  const [reasons, setReasons] = useState<Concept[]>([]);
  const [showStopped, setShowStopped] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  const [action, setAction] = useState<Action>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [drug, setDrug] = useState<Drug | null>(null);
  const [dose, setDose] = useState<DoseValues>(emptyDose());
  const [reasonCode, setReasonCode] = useState("");
  const [reasonText, setReasonText] = useState("");
  const [source, setSource] = useState("this_centre");
  const [indication, setIndication] = useState("");
  const panelRef = useRef<HTMLDivElement>(null);

  const load = useCallback(async () => {
    try {
      const r = await api<{ items: MedicationCourse[] }>(`/patients/${patientId}/medications`, {
        query: { include_stopped: true } });
      setCourses(r.data.items);
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not load medicines");
    }
  }, [api, patientId]);

  useEffect(() => {
    void load();
    if (canPrescribe) {
      api<{ items: Concept[] }>("/concepts", { query: { domain: "reason" } }).then((r) => setReasons(r.data.items))
        .catch(() => undefined);
    }
  }, [load, api, canPrescribe]);

  const begin = (a: Action) => {
    setError(null);
    setAction(a);
    setReasonCode("");
    setReasonText("");
    setDrug(null);
    setSource("this_centre");
    setIndication("");
    if (a && a.kind === "change") setDose(doseFrom(a.course));
    setTimeout(() => panelRef.current?.scrollIntoView({ block: "nearest", behavior: "smooth" }), 0);
  };

  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
      setAction(null);
      await load();
      onChanged?.();
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not save the medicine");
    } finally {
      setBusy(false);
    }
  };

  const courseEvent = (course: MedicationCourse, body: Record<string, unknown>) =>
    run(() => api(`/medication-courses/${course.course_id}/events`, {
      method: "POST", body: { ...body, encounter_id: encounterId } }));

  const reasonBody = { reason_code: reasonCode || undefined, reason_text: reasonText.trim() || undefined };
  if (!courses) return error ? <ErrorBanner message={error} /> : <Loading />;
  const current = courses.filter((c) => c.status === "active" || c.status === "on_hold");
  const stopped = courses.filter((c) => c.status === "stopped");

  return (
    <div className="stack" style={{ gap: 12 }}>
      {error && <ErrorBanner message={error} />}
      {current.length === 0 && <div className="muted">No current medicines.</div>}
      <ul className="plain med-list">
        {[...current, ...(showStopped ? stopped : [])].map((c) => (
          <li key={c.course_id} className="med-item" data-status={c.status}>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div className="row" style={{ gap: 6 }}>
                <strong>{c.generic_name}</strong>
                {c.status !== "active" && <StatusBadge status={c.status} />}
                {c.current_dose?.prescriber_source && c.current_dose.prescriber_source !== "this_centre" && (
                  <span className="badge">{c.current_dose.prescriber_source.replace(/_/g, " ")}</span>
                )}
              </div>
              <div className="small">{courseLine(c)}</div>
              <div className="small muted">
                Since {formatDate(c.started_on)}{c.stopped_on ? ` · stopped ${formatDate(c.stopped_on)}` : ""}
                {c.current_dose?.instructions ? ` · ${c.current_dose.instructions}` : ""}
                {" · "}
                <button type="button" className="link-button" onClick={() => setOpen(open === c.course_id ? null : c.course_id)}
                  aria-expanded={open === c.course_id}>
                  {open === c.course_id ? "hide history" : "history"}
                </button>
              </div>
              {open === c.course_id && (
                <ol className="history">
                  {c.events?.map((e) => (
                    <li key={e.medication_event_id} className={e.voided ? "voided" : undefined}>
                      <span className="mono small">{formatDate(e.effective_date)}</span> {eventLabel(e.event_type)}
                      {doseLine(e) ? ` · ${doseLine(e)}` : ""}
                      {e.daily_dose ? ` (${dailyDose(e.daily_dose, c.reference_unit)})` : ""}
                      {e.reason || e.reason_text ? ` · ${[e.reason, e.reason_text].filter(Boolean).join(": ")}` : ""}
                      {e.prescribed_by_name ? ` · ${e.prescribed_by_name}` : ""}
                      {e.voided && " · voided"}
                    </li>
                  ))}
                </ol>
              )}
            </div>
            {canPrescribe && c.status !== "stopped" && (
              <div className="row med-actions">
                {c.status === "active" && <button type="button" className="btn btn-sm" onClick={() => begin({ kind: "change", course: c })}>Change dose</button>}
                {c.status === "active" && encounterId && (
                  <button type="button" className="btn btn-sm" disabled={busy} title="Confirm the patient continues this dose"
                    onClick={() => void courseEvent(c, { event_type: "reconcile_continue" })}>Continue</button>
                )}
                {c.status === "active" && <button type="button" className="btn btn-sm" onClick={() => begin({ kind: "hold", course: c })}>Hold</button>}
                {c.status === "on_hold" && (
                  <button type="button" className="btn btn-sm" disabled={busy} onClick={() => void courseEvent(c, { event_type: "resume" })}>Resume</button>
                )}
                <button type="button" className="btn btn-sm btn-danger" onClick={() => begin({ kind: "stop", course: c })}>Stop</button>
              </div>
            )}
            {canPrescribe && c.status === "stopped" && (
              <div className="row med-actions">
                <button type="button" className="btn btn-sm" disabled={busy} onClick={() => void courseEvent(c, { event_type: "resume" })}>Restart</button>
              </div>
            )}
          </li>
        ))}
      </ul>
      <div className="row" style={{ justifyContent: "space-between" }}>
        {stopped.length > 0 ? (
          <button type="button" className="link-button small" onClick={() => setShowStopped((s) => !s)}>
            {showStopped ? "Hide stopped medicines" : `Show ${stopped.length} stopped`}
          </button>
        ) : <span />}
        {canPrescribe && !action && (
          <button type="button" className="btn btn-primary btn-sm" onClick={() => begin({ kind: "add" })}>Add medicine</button>
        )}
      </div>

      <div ref={panelRef}>
        {action?.kind === "add" && (
          <div className="subpanel stack">
            <h3>Add medicine</h3>
            {!drug ? (
              <DrugSearch onPick={(d) => {
                setDrug(d);
                setDose(emptyDose(d));
              }} />
            ) : (
              <>
                <div className="row" style={{ justifyContent: "space-between" }}>
                  <strong>{drug.generic_name}</strong>
                  <button type="button" className="link-button small" onClick={() => setDrug(null)}>change medicine</button>
                </div>
                <DoseForm v={dose} set={setDose} products={drug.products} unit={drug.reference_unit} idPrefix="add" />
                <div className="form-grid">
                  <Field label="Prescribed by" htmlFor="add-source" className="span-3">
                    <select id="add-source" className="input" value={source} onChange={(e) => setSource(e.target.value)}>
                      <option value="this_centre">Prescribed here today</option>
                      <option value="external">Already taking: prescribed elsewhere</option>
                      <option value="patient_reported">Already taking: patient reported</option>
                    </select>
                  </Field>
                  <Field label="Indication" htmlFor="add-indication" className="span-3">
                    <input id="add-indication" className="input" value={indication} onChange={(e) => setIndication(e.target.value)} />
                  </Field>
                </div>
              </>
            )}
            <div className="row" style={{ justifyContent: "flex-end" }}>
              <button type="button" className="btn" onClick={() => setAction(null)}>Cancel</button>
              <button type="button" className="btn btn-primary" disabled={!drug || busy}
                onClick={() => drug && void run(() => api(`/patients/${patientId}/medications`, {
                  method: "POST",
                  body: { drug_code: drug.drug_code, ...doseBody(dose), prescriber_source: source,
                    indication: indication.trim() || undefined, encounter_id: encounterId },
                }))}>
                {busy ? "Saving…" : "Add"}
              </button>
            </div>
          </div>
        )}
        {action?.kind === "change" && (
          <div className="subpanel stack">
            <h3>Change dose: {action.course.generic_name}</h3>
            <div className="small muted">Now: {courseLine(action.course) || "no dose recorded"}</div>
            <DoseForm v={dose} set={setDose} products={[]} unit={action.course.reference_unit} idPrefix="chg" />
            <ReasonPicker reasons={reasons} code={reasonCode} text={reasonText} setCode={setReasonCode}
              setText={setReasonText} idPrefix="chg" />
            <div className="row" style={{ justifyContent: "flex-end" }}>
              <button type="button" className="btn" onClick={() => setAction(null)}>Cancel</button>
              <button type="button" className="btn btn-primary" disabled={busy}
                onClick={() => void courseEvent(action.course, { event_type: "dose_change", dose: doseBody(dose), ...reasonBody })}>
                {busy ? "Saving…" : "Save new dose"}
              </button>
            </div>
          </div>
        )}
        {(action?.kind === "hold" || action?.kind === "stop") && (
          <div className="subpanel stack">
            <h3>{action.kind === "hold" ? "Hold" : "Stop"} {action.course.generic_name}</h3>
            <ReasonPicker reasons={reasons} code={reasonCode} text={reasonText} setCode={setReasonCode}
              setText={setReasonText} idPrefix="stop" required />
            <div className="row" style={{ justifyContent: "flex-end" }}>
              <button type="button" className="btn" onClick={() => setAction(null)}>Cancel</button>
              <button type="button" className={`btn ${action.kind === "stop" ? "btn-danger" : "btn-primary"}`}
                disabled={busy || (!reasonCode && !reasonText.trim())}
                onClick={() => void courseEvent(action.course, {
                  event_type: action.kind === "hold" ? "hold" : "discontinue", ...reasonBody })}>
                {action.kind === "hold" ? "Hold medicine" : "Stop medicine"}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
