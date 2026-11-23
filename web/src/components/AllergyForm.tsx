"use client";
import { useState } from "react";
import { ApiError } from "@/lib/api";
import { useSession } from "@/lib/session";
import { ErrorBanner, Field } from "./ui";

const CLASSES: [string, string][] = [
  ["", "—"], ["STATIN", "Statins"], ["ACEI", "ACE inhibitors"], ["ARB", "ARBs"], ["BETA_BLOCKER", "Beta-blockers"],
  ["ANTIPLATELET", "Antiplatelets"], ["P2Y12I", "P2Y12 inhibitors"], ["ANTICOAGULANT", "Anticoagulants"],
];

export function AllergyForm({ patientId, onSaved, onCancel }: { patientId: string; onSaved: () => void; onCancel: () => void }) {
  const { api } = useSession();
  const [type, setType] = useState("drug");
  const [cls, setCls] = useState("");
  const [text, setText] = useState("");
  const [reaction, setReaction] = useState("");
  const [severity, setSeverity] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      await api(`/patients/${patientId}/allergies`, {
        method: "POST",
        body: {
          allergen_type: cls ? "drug_class" : type, drug_class_code: cls || undefined, allergen_text: text.trim(),
          reaction: reaction.trim() || undefined, severity: severity || undefined,
        },
      });
      onSaved();
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not save the allergy");
      setBusy(false);
    }
  };

  return (
    <div className="subpanel stack" style={{ gap: 12 }}>
      <h3>Add allergy</h3>
      {error && <ErrorBanner message={error} />}
      <div className="form-grid">
        <Field label="Type" htmlFor="al-type" className="span-2">
          <select id="al-type" className="input" value={type} onChange={(e) => setType(e.target.value)}>
            <option value="drug">Drug</option><option value="contrast">Contrast</option><option value="food">Food</option>
            <option value="other">Other</option>
          </select>
        </Field>
        {type === "drug" && (
          <Field label="Whole drug class" htmlFor="al-class" className="span-2" hint="Blocks prescribing any drug in it">
            <select id="al-class" className="input" value={cls} onChange={(e) => setCls(e.target.value)}>
              {CLASSES.map(([c, l]) => <option key={c} value={c}>{l}</option>)}
            </select>
          </Field>
        )}
        <Field label="Allergen" htmlFor="al-text" required className="span-2">
          <input id="al-text" className="input" value={text} onChange={(e) => setText(e.target.value)} placeholder="e.g. Penicillin" />
        </Field>
        <Field label="Reaction" htmlFor="al-reaction" className="span-4">
          <input id="al-reaction" className="input" value={reaction} onChange={(e) => setReaction(e.target.value)} />
        </Field>
        <Field label="Severity" htmlFor="al-severity" className="span-2">
          <select id="al-severity" className="input" value={severity} onChange={(e) => setSeverity(e.target.value)}>
            <option value="">—</option><option value="mild">Mild</option><option value="moderate">Moderate</option>
            <option value="severe">Severe</option><option value="anaphylaxis">Anaphylaxis</option>
          </select>
        </Field>
      </div>
      <div className="row" style={{ justifyContent: "flex-end" }}>
        <button type="button" className="btn" onClick={onCancel}>Cancel</button>
        <button type="button" className="btn btn-primary" disabled={busy || text.trim().length < 2} onClick={() => void save()}>
          {busy ? "Saving…" : "Add allergy"}
        </button>
      </div>
    </div>
  );
}
