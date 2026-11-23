"use client";
import { useRef, useState } from "react";
import { ApiError, newIdempotencyKey } from "@/lib/api";
import { useSession } from "@/lib/session";
import type { Consent, ProtocolSummary } from "@/lib/types";
import { ErrorBanner, Field } from "./ui";

export const CONSENT_TYPES: [string, string][] = [
  ["clinical_care", "Clinical care"], ["research_registry", "Research registry"],
  ["cross_centre_linkage", "Cross-centre linkage"], ["external_data_sharing", "External data sharing"],
  ["ai_processing", "AI processing"], ["recontact", "Re-contact"],
];
const METHODS: [string, string][] = [
  ["written", "Written (signed form)"], ["electronic", "Electronic"], ["audio_video", "Audio-video recorded"],
  ["verbal_witnessed", "Verbal, witnessed"], ["waiver_approved", "Waiver approved by the ethics committee"],
];

function today(): string {
  return new Date().toLocaleDateString("en-CA");
}

/** Record a consent. Research consent names the protocol; only registry staff are offered it. */
export function ConsentForm({ patientId, protocols, canResearch, presetProtocolId, onSaved, onCancel }: {
  patientId: string; protocols: (ProtocolSummary & { registry_code: string })[]; canResearch: boolean;
  presetProtocolId?: string; onSaved: (c: Consent) => void; onCancel: () => void;
}) {
  const { api } = useSession();
  const [type, setType] = useState(presetProtocolId ? "research_registry" : canResearch ? "research_registry" : "clinical_care");
  const [protocolId, setProtocolId] = useState(presetProtocolId ?? "");
  const [form, setForm] = useState("");
  const [language, setLanguage] = useState("");
  const [date, setDate] = useState(today());
  const [method, setMethod] = useState("written");
  const [signedBy, setSignedBy] = useState("patient");
  const [lar, setLar] = useState("");
  const [larRelation, setLarRelation] = useState("");
  const [witness, setWitness] = useState("");
  const [refused, setRefused] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const key = useRef<string | null>(null);

  const types = CONSENT_TYPES.filter(([c]) => canResearch || c !== "research_registry");
  const ready = form.trim() && date && (type !== "research_registry" || protocolId)
    && (signedBy === "patient" || lar.trim()) && (method !== "verbal_witnessed" || witness.trim());

  const save = async () => {
    setBusy(true);
    setError(null);
    key.current ??= newIdempotencyKey();
    try {
      const r = await api<Consent>(`/patients/${patientId}/consents`, {
        method: "POST", idempotencyKey: key.current,
        body: {
          consent_type: type, protocol_id: type === "research_registry" ? protocolId : undefined,
          consent_form_version: form.trim(), consent_language: language.trim() || undefined, consent_date: date,
          consent_method: method, signed_by: signedBy, lar_name: signedBy === "patient" ? undefined : lar.trim(),
          lar_relation: signedBy === "patient" ? undefined : larRelation.trim() || undefined,
          witness_name: witness.trim() || undefined, consent_status: refused ? "refused" : "active",
        },
      });
      onSaved(r.data);
    } catch (e) {
      key.current = null;
      setError(e instanceof ApiError ? e.userMessage : "Could not record the consent");
      setBusy(false);
    }
  };

  return (
    <div className="subpanel stack" style={{ gap: 12 }}>
      <h3>Record consent</h3>
      {error && <ErrorBanner message={error} />}
      <div className="form-grid">
        <Field label="Consent for" htmlFor="cn-type" className="span-3">
          <select id="cn-type" className="input" value={type} onChange={(e) => setType(e.target.value)} disabled={!!presetProtocolId}>
            {types.map(([c, l]) => <option key={c} value={c}>{l}</option>)}
          </select>
        </Field>
        {type === "research_registry" && (
          <Field label="Registry protocol" htmlFor="cn-protocol" required className="span-3">
            <select id="cn-protocol" className="input" value={protocolId} onChange={(e) => setProtocolId(e.target.value)}
              disabled={!!presetProtocolId}>
              <option value="">Choose…</option>
              {protocols.map((p) => <option key={p.protocol_id} value={p.protocol_id}>{p.protocol_code} v{p.protocol_version}</option>)}
            </select>
          </Field>
        )}
        <Field label="Form version" htmlFor="cn-form" required className="span-2" hint="As printed on the approved form">
          <input id="cn-form" className="input" value={form} onChange={(e) => setForm(e.target.value)} placeholder="e.g. ICF v1.0" />
        </Field>
        <Field label="Language" htmlFor="cn-lang" className="span-2">
          <input id="cn-lang" className="input" value={language} onChange={(e) => setLanguage(e.target.value)} placeholder="e.g. Marathi" />
        </Field>
        <Field label="Date" htmlFor="cn-date" required className="span-2">
          <input id="cn-date" type="date" className="input" value={date} max={today()} onChange={(e) => setDate(e.target.value)} />
        </Field>
        <Field label="How it was taken" htmlFor="cn-method" className="span-3">
          <select id="cn-method" className="input" value={method} onChange={(e) => setMethod(e.target.value)}>
            {METHODS.map(([c, l]) => <option key={c} value={c}>{l}</option>)}
          </select>
        </Field>
        <Field label="Signed by" htmlFor="cn-signed" className="span-3">
          <select id="cn-signed" className="input" value={signedBy} onChange={(e) => setSignedBy(e.target.value)}>
            <option value="patient">The patient</option>
            <option value="legally_authorised_rep">Legally authorised representative</option>
          </select>
        </Field>
        {signedBy !== "patient" && (
          <>
            <Field label="Representative's name" htmlFor="cn-lar" required className="span-3">
              <input id="cn-lar" className="input" value={lar} onChange={(e) => setLar(e.target.value)} />
            </Field>
            <Field label="Relation to patient" htmlFor="cn-larrel" className="span-3">
              <input id="cn-larrel" className="input" value={larRelation} onChange={(e) => setLarRelation(e.target.value)} />
            </Field>
          </>
        )}
        <Field label="Witness" htmlFor="cn-witness" required={method === "verbal_witnessed"} className="span-3">
          <input id="cn-witness" className="input" value={witness} onChange={(e) => setWitness(e.target.value)} />
        </Field>
        <label className="check span-3 align-end">
          <input type="checkbox" checked={refused} onChange={(e) => setRefused(e.target.checked)} /> The patient declined
        </label>
      </div>
      <div className="row" style={{ justifyContent: "flex-end" }}>
        <button type="button" className="btn" onClick={onCancel}>Cancel</button>
        <button type="button" className="btn btn-primary" disabled={!ready || busy} onClick={() => void save()}>
          {busy ? "Saving…" : refused ? "Record refusal" : "Record consent"}
        </button>
      </div>
    </div>
  );
}

/** Withdraw an active consent; withdrawing research consent ends the enrolment that relies on it. */
export function WithdrawConsent({ consent, onDone, onCancel }: { consent: Consent; onDone: () => void; onCancel: () => void }) {
  const { api } = useSession();
  const [date, setDate] = useState(today());
  const [scope, setScope] = useState("no_further_collection");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      await api(`/consents/${consent.consent_id}/withdraw`, {
        method: "POST", ifMatch: `"${consent.row_version}"`, changeReason: reason.trim(),
        body: { withdrawal_date: date, withdrawal_scope: scope, withdrawal_reason: reason.trim() },
      });
      onDone();
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not record the withdrawal");
      setBusy(false);
    }
  };
  return (
    <div className="subpanel stack" style={{ gap: 12 }}>
      {error && <ErrorBanner message={error} />}
      {consent.consent_type === "research_registry" && (
        <div className="small">Withdrawing ends the registry enrolment that relies on this consent.</div>
      )}
      <div className="form-grid">
        <Field label="Withdrawn on" htmlFor="wd-date" className="span-2">
          <input id="wd-date" type="date" className="input" value={date} min={consent.consent_date} max={today()}
            onChange={(e) => setDate(e.target.value)} />
        </Field>
        <Field label="What the patient asked for" htmlFor="wd-scope" className="span-4">
          <select id="wd-scope" className="input" value={scope} onChange={(e) => setScope(e.target.value)}>
            <option value="no_further_contact">No further contact</option>
            <option value="no_further_collection">No further data collection</option>
            <option value="exclude_collected_data">Also exclude data already collected</option>
          </select>
        </Field>
        <Field label="Reason" htmlFor="wd-reason" required className="span-6">
          <input id="wd-reason" className="input" value={reason} onChange={(e) => setReason(e.target.value)} />
        </Field>
      </div>
      <div className="row" style={{ justifyContent: "flex-end" }}>
        <button type="button" className="btn" onClick={onCancel}>Cancel</button>
        <button type="button" className="btn btn-danger" disabled={busy || reason.trim().length < 3} onClick={() => void save()}>
          Record withdrawal
        </button>
      </div>
    </div>
  );
}
