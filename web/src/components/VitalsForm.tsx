"use client";
import { useState } from "react";
import { ApiError } from "@/lib/api";
import { useSession } from "@/lib/session";
import type { VitalsRow } from "@/lib/types";
import { ErrorBanner, Field } from "./ui";

const FIELDS: { key: string; label: string; unit?: string; className?: string }[] = [
  { key: "systolic_bp", label: "Systolic", unit: "mmHg" },
  { key: "diastolic_bp", label: "Diastolic", unit: "mmHg" },
  { key: "heart_rate", label: "Heart rate", unit: "/min" },
  { key: "respiratory_rate", label: "Resp. rate", unit: "/min" },
  { key: "spo2", label: "SpO₂", unit: "%" },
  { key: "temperature_c", label: "Temp.", unit: "°C" },
  { key: "weight_kg", label: "Weight", unit: "kg" },
  { key: "height_cm", label: "Height", unit: "cm" },
  { key: "waist_cm", label: "Waist", unit: "cm" },
];

export function vitalsLine(v: VitalsRow | null | undefined): string {
  if (!v) return "—";
  const p: string[] = [];
  if (v.systolic_bp) p.push(`BP ${v.systolic_bp}/${v.diastolic_bp ?? "?"}`);
  if (v.heart_rate) p.push(`HR ${v.heart_rate}${v.pulse_rhythm === "irregular" ? " irreg." : ""}`);
  if (v.respiratory_rate) p.push(`RR ${v.respiratory_rate}`);
  if (v.spo2) p.push(`SpO₂ ${v.spo2}%`);
  if (v.temperature_c) p.push(`T ${v.temperature_c}°C`);
  if (v.weight_kg) p.push(`Wt ${v.weight_kg} kg`);
  if (v.bmi) p.push(`BMI ${v.bmi}`);
  if (v.waist_cm) p.push(`Waist ${v.waist_cm} cm`);
  return p.join(" · ") || "—";
}

export function VitalsForm({ patientId, encounterId, onSaved, onCancel }: {
  patientId: string; encounterId?: string; onSaved: (v: VitalsRow) => void; onCancel?: () => void;
}) {
  const { api } = useSession();
  const [v, setV] = useState<Record<string, string>>({ pulse_rhythm: "", bp_position: "sitting" });
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const save = async () => {
    const body: Record<string, unknown> = { encounter_id: encounterId };
    for (const f of FIELDS) if (v[f.key]?.trim()) body[f.key] = Number(v[f.key]);
    if (v.pulse_rhythm) body.pulse_rhythm = v.pulse_rhythm;
    if (body.systolic_bp) body.bp_position = v.bp_position;
    if (Object.keys(body).length <= 2 && !FIELDS.some((f) => body[f.key] !== undefined)) {
      setError("Enter at least one measurement.");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const r = await api<VitalsRow>(`/patients/${patientId}/vitals`, { method: "POST", body });
      setV({ pulse_rhythm: "", bp_position: "sitting" });
      onSaved(r.data);
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not save vitals");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="stack" style={{ gap: 12 }}>
      {error && <ErrorBanner message={error} />}
      <div className="vitals-grid">
        {FIELDS.map((f) => (
          <Field key={f.key} label={`${f.label}${f.unit ? ` (${f.unit})` : ""}`} htmlFor={`v-${f.key}`}>
            <input id={`v-${f.key}`} className="input" inputMode="decimal" value={v[f.key] ?? ""}
              onChange={(e) => setV({ ...v, [f.key]: e.target.value })} />
          </Field>
        ))}
        <Field label="Pulse" htmlFor="v-pulse_rhythm">
          <select id="v-pulse_rhythm" className="input" value={v.pulse_rhythm}
            onChange={(e) => setV({ ...v, pulse_rhythm: e.target.value })}>
            <option value="">—</option><option value="regular">Regular</option><option value="irregular">Irregular</option>
          </select>
        </Field>
        <Field label="BP taken" htmlFor="v-bp_position">
          <select id="v-bp_position" className="input" value={v.bp_position}
            onChange={(e) => setV({ ...v, bp_position: e.target.value })}>
            <option value="sitting">Sitting</option><option value="supine">Supine</option><option value="standing">Standing</option>
          </select>
        </Field>
      </div>
      <div className="row" style={{ justifyContent: "flex-end" }}>
        {onCancel && <button type="button" className="btn" onClick={onCancel}>Cancel</button>}
        <button type="button" className="btn btn-primary" onClick={() => void save()} disabled={busy}>
          {busy ? "Saving…" : "Record vitals"}
        </button>
      </div>
    </div>
  );
}
