"use client";
import { useEffect, useState } from "react";
import { ApiError } from "@/lib/api";
import { useSession } from "@/lib/session";
import type { Concept, Diagnosis } from "@/lib/types";
import { ErrorBanner, Field } from "./ui";

export const ROLE_LABELS: Record<string, string> = {
  working: "Working", final: "Final", comorbidity: "Comorbidity", past_history: "Past history", complication: "Complication",
};

export function DiagnosisForm({ patientId, encounterId, defaultRole = "final", onSaved, onCancel }: {
  patientId: string; encounterId?: string; defaultRole?: string; onSaved: (d: Diagnosis) => void; onCancel?: () => void;
}) {
  const { api } = useSession();
  const [concepts, setConcepts] = useState<Concept[]>([]);
  const [code, setCode] = useState("");
  const [text, setText] = useState("");
  const [icd, setIcd] = useState("");
  const [role, setRole] = useState(defaultRole);
  const [certainty, setCertainty] = useState("confirmed");
  const [principal, setPrincipal] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    api<{ items: Concept[] }>("/concepts", { query: { domain: "diagnosis" } }).then((r) => setConcepts(r.data.items))
      .catch(() => undefined);
  }, [api]);

  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      const r = await api<Diagnosis>(`/patients/${patientId}/diagnoses`, {
        method: "POST",
        body: {
          concept_code: code || undefined, diagnosis_text: text.trim() || undefined, icd10_code: icd.trim().toUpperCase() || undefined,
          diagnosis_role: role, certainty, is_principal: principal, encounter_id: encounterId,
        },
      });
      setCode(""); setText(""); setIcd(""); setPrincipal(false);
      onSaved(r.data);
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not save the diagnosis");
    } finally {
      setBusy(false);
    }
  };

  const chosen = concepts.find((c) => c.concept_code === code);
  return (
    <div className="stack" style={{ gap: 12 }}>
      {error && <ErrorBanner message={error} />}
      <div className="form-grid">
        <Field label="Diagnosis" htmlFor="dx-code" className="span-3"
          hint={chosen?.registry_triggers.length ? `Prompts screening for ${chosen.registry_triggers.join(", ")} registry` : undefined}>
          <select id="dx-code" className="input" value={code} onChange={(e) => setCode(e.target.value)}>
            <option value="">Other (type below)…</option>
            {concepts.map((c) => (
              <option key={c.concept_code} value={c.concept_code}>{c.display_name}{c.icd10_code ? ` · ${c.icd10_code}` : ""}</option>
            ))}
          </select>
        </Field>
        <Field label={code ? "Wording (optional)" : "Diagnosis as written"} htmlFor="dx-text" className="span-3">
          <input id="dx-text" className="input" value={text} onChange={(e) => setText(e.target.value)}
            placeholder={chosen ? chosen.display_name : "e.g. Moderate mitral regurgitation"} />
        </Field>
        {!code && (
          <Field label="ICD-10" htmlFor="dx-icd" className="span-2" hint="Needed unless it is a working diagnosis">
            <input id="dx-icd" className="input" value={icd} onChange={(e) => setIcd(e.target.value)} placeholder="e.g. I34.0" />
          </Field>
        )}
        <Field label="Type" htmlFor="dx-role" className="span-2">
          <select id="dx-role" className="input" value={role} onChange={(e) => setRole(e.target.value)}>
            {Object.entries(ROLE_LABELS).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
          </select>
        </Field>
        <Field label="Certainty" htmlFor="dx-certainty" className="span-1">
          <select id="dx-certainty" className="input" value={certainty} onChange={(e) => setCertainty(e.target.value)}>
            <option value="confirmed">Confirmed</option><option value="suspected">Suspected</option>
          </select>
        </Field>
        <label className="check span-1" style={{ alignSelf: "end" }}>
          <input type="checkbox" checked={principal} onChange={(e) => setPrincipal(e.target.checked)} /> Principal
        </label>
      </div>
      <div className="row" style={{ justifyContent: "flex-end" }}>
        {onCancel && <button type="button" className="btn" onClick={onCancel}>Cancel</button>}
        <button type="button" className="btn btn-primary" onClick={() => void save()} disabled={busy || (!code && !text.trim())}>
          {busy ? "Saving…" : "Add diagnosis"}
        </button>
      </div>
    </div>
  );
}
