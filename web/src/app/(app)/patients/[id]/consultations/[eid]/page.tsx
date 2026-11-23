"use client";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import { ClinicalSummaryPanel } from "@/components/ClinicalSummaryPanel";
import { DiagnosisForm, ROLE_LABELS } from "@/components/DiagnosisForm";
import { MedicationPanel } from "@/components/MedicationPanel";
import { VitalsForm, vitalsLine } from "@/components/VitalsForm";
import { Card, ErrorBanner, Field, Loading, StatusBadge } from "@/components/ui";
import { ApiError } from "@/lib/api";
import { ageSex, formatDate, formatDateTime, humanise } from "@/lib/format";
import { encounterEventLine } from "@/lib/meds";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import type {
  ClinicalAssessment, ClinicalSummary, ComplaintEntry, Concept, Encounter, NoteField, PatientOverview,
} from "@/lib/types";

const TYPES: [string, string][] = [
  ["new_consultation", "New consultation"], ["follow_up", "Follow-up"], ["registry_visit", "Registry visit"],
  ["teleconsultation", "Teleconsultation"], ["telephone", "Telephone"], ["inpatient_review", "Inpatient review"],
  ["emergency", "Emergency"], ["retrospective_entry", "Retrospective entry"],
];
const NOTE_LABELS: Record<NoteField, string> = {
  presenting_complaint: "Presenting complaint (free text)", history_present_illness: "History of present illness",
  clinical_history: "Past cardiac history, events, hospitalisations", examination_cvs: "Cardiovascular examination",
  examination_resp: "Respiratory examination", examination_other: "Other findings", assessment: "Assessment",
  plan: "Plan: investigations ordered and other actions", lifestyle_advice: "Lifestyle advice",
  patient_education: "Patient education", referral_to: "Referral",
};
const EMPTY_ASSESSMENT: ClinicalAssessment = {
  nyha_class: null, ccs_class: null, killip_class: null, jvp: null, jvp_cm: null, peripheral_oedema: null,
  pulmonary_rales: null, s3_gallop: null, orthopnoea: null, pnd: null, congestion_status: null, hf_phenotype: null,
  cv_risk_category: null,
};
type Note = Record<NoteField, string> & { encounter_type: string; follow_up_date: string };

function noteFrom(e: Encounter): Note {
  const n = { encounter_type: e.encounter_type, follow_up_date: e.follow_up_date ?? "" } as Note;
  for (const k of Object.keys(NOTE_LABELS) as NoteField[]) n[k] = e[k] ?? "";
  return n;
}

function Select({ id, label, value, options, onChange, disabled }: {
  id: string; label: string; value: string | null; options: [string, string][]; onChange: (v: string | null) => void;
  disabled?: boolean;
}) {
  return (
    <Field label={label} htmlFor={id} className="span-2">
      <select id={id} className="input" value={value ?? ""} disabled={disabled} onChange={(e) => onChange(e.target.value || null)}>
        <option value="">—</option>
        {options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
      </select>
    </Field>
  );
}

function Tri({ label, value, onChange, disabled }: { label: string; value: boolean | null; onChange: (v: boolean | null) => void; disabled?: boolean }) {
  return (
    <div className="field span-2">
      <span className="label">{label}</span>
      <div className="segmented" role="group" aria-label={label}>
        {([[true, "Yes"], [false, "No"], [null, "—"]] as [boolean | null, string][]).map(([v, l]) => (
          <button key={l} type="button" aria-pressed={value === v} disabled={disabled} onClick={() => onChange(v)}>{l}</button>
        ))}
      </div>
    </div>
  );
}

function TextArea({ field, note, set, disabled, rows = 3 }: {
  field: NoteField; note: Note; set: (f: NoteField, v: string) => void; disabled?: boolean; rows?: number;
}) {
  return (
    <Field label={NOTE_LABELS[field]} htmlFor={`n-${field}`} className="span-6">
      <textarea id={`n-${field}`} className="input" rows={rows} value={note[field]} disabled={disabled}
        onChange={(e) => set(field, e.target.value)} />
    </Field>
  );
}

function Amendable({ enc, field, canAmend, onAmended }: {
  enc: Encounter; field: NoteField; canAmend: boolean; onAmended: (e: Encounter) => void;
}) {
  const { api } = useSession();
  const amendments = enc.amendments.filter((a) => a.field_name === field);
  const current = amendments.length ? amendments[amendments.length - 1].amended_value : enc[field];
  const [editing, setEditing] = useState(false);
  const [text, setText] = useState(current ?? "");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  if (!current && !canAmend) return null;
  const save = async () => {
    setError(null);
    try {
      const r = await api<Encounter>(`/encounters/${enc.encounter_id}/amendments`, {
        method: "POST", body: { field_name: field, amended_value: text, reason: reason.trim() } });
      setEditing(false);
      onAmended(r.data);
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not save the amendment");
    }
  };
  return (
    <div className="readonly-field">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <span className="label">{NOTE_LABELS[field]}</span>
        {canAmend && !editing && (
          <button type="button" className="link-button small" onClick={() => { setText(current ?? ""); setEditing(true); }}>Amend</button>
        )}
      </div>
      {editing ? (
        <div className="stack" style={{ gap: 8 }}>
          {error && <ErrorBanner message={error} />}
          <textarea className="input" aria-label={`Amended ${NOTE_LABELS[field]}`} rows={3} value={text} onChange={(e) => setText(e.target.value)} />
          <input className="input" aria-label="Reason for amendment" placeholder="Reason for amendment (at least 5 characters)"
            value={reason} onChange={(e) => setReason(e.target.value)} />
          <div className="row" style={{ justifyContent: "flex-end" }}>
            <button type="button" className="btn btn-sm" onClick={() => setEditing(false)}>Cancel</button>
            <button type="button" className="btn btn-sm btn-primary" disabled={reason.trim().length < 5} onClick={() => void save()}>Save amendment</button>
          </div>
        </div>
      ) : (
        <div className="prewrap">{current || <span className="muted">—</span>}</div>
      )}
      {amendments.length > 0 && !editing && (
        <details className="small muted">
          <summary>Amended {amendments.length}×, last {formatDateTime(amendments[amendments.length - 1].amended_at)}</summary>
          {amendments.map((a) => (
            <div key={a.amendment_id} style={{ marginTop: 6 }}>
              {formatDateTime(a.amended_at)} · {a.amended_by_name}: “{a.reason}”. Was: <span className="prewrap">{a.previous_value || "—"}</span>
            </div>
          ))}
        </details>
      )}
    </div>
  );
}

export default function ConsultationPage() {
  const { id, eid } = useParams<{ id: string; eid: string }>();
  const { api, selection, membership } = useSession();
  const role = selection?.role;
  const [enc, setEnc] = useState<Encounter | null>(null);
  const [patient, setPatient] = useState<PatientOverview["patient"] | null>(null);
  const [summary, setSummary] = useState<ClinicalSummary | null>(null);
  const [complaintList, setComplaintList] = useState<Concept[]>([]);
  const [note, setNote] = useState<Note | null>(null);
  const [complaints, setComplaints] = useState<ComplaintEntry[]>([]);
  const [assessment, setAssessment] = useState<ClinicalAssessment>(EMPTY_ASSESSMENT);
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [savedAt, setSavedAt] = useState<Date | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<ApiError | null>(null);
  const [confirmSign, setConfirmSign] = useState(false);
  const [showVitals, setShowVitals] = useState(false);
  const [showDx, setShowDx] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const version = useRef<number>(0);
  const saveChain = useRef<Promise<unknown>>(Promise.resolve());

  const adopt = useCallback((e: Encounter, resetForm: boolean) => {
    setEnc(e);
    version.current = e.row_version;
    if (resetForm) {
      setNote(noteFrom(e));
      setComplaints(e.complaints);
      setAssessment(e.clinical_assessment ?? EMPTY_ASSESSMENT);
      setDirty(false);
    }
  }, []);

  const reloadEncounter = useCallback(async (resetForm = false) => {
    const r = await api<Encounter>(`/encounters/${eid}`);
    adopt(r.data, resetForm);
  }, [api, eid, adopt]);

  const reloadSummary = useCallback(async () => {
    const r = await api<ClinicalSummary>(`/patients/${id}/clinical-summary`);
    setSummary(r.data);
  }, [api, id]);

  useEffect(() => {
    (async () => {
      try {
        const [e, p] = await Promise.all([api<Encounter>(`/encounters/${eid}`), api<PatientOverview>(`/patients/${id}`)]);
        adopt(e.data, true);
        setPatient(p.data.patient);
        void reloadSummary().catch(() => undefined);
        api<{ items: Concept[] }>("/concepts", { query: { domain: "complaint" } }).then((r) => setComplaintList(r.data.items))
          .catch(() => undefined);
      } catch (err) {
        setLoadError(err instanceof ApiError ? err : new ApiError(0, "NETWORK", "Could not load the consultation"));
      }
    })();
  }, [api, id, eid, adopt, reloadSummary]);

  const editable = enc?.status === "draft" && can(role, "consult.edit");

  const save = useCallback(async (): Promise<boolean> => {
    if (!note || !enc) return true;
    const run = async () => {
      setSaving(true);
      setError(null);
      try {
        const n: Record<string, unknown> = { ...note, follow_up_date: note.follow_up_date || null };
        for (const k of Object.keys(NOTE_LABELS)) n[k] = (note[k as NoteField] ?? "").trim() || null;
        const r = await api<Encounter>(`/encounters/${enc.encounter_id}`, {
          method: "PUT", ifMatch: `"${version.current}"`,
          body: {
            note: n,
            complaints: complaints.map((c) => ({
              concept_code: c.concept_code, duration_value: c.duration_value, duration_unit: c.duration_value !== null ? c.duration_unit : null,
              detail: c.detail || null,
            })),
            assessment,
          },
        });
        adopt(r.data, false);
        setDirty(false);
        setSavedAt(new Date());
        return true;
      } catch (e) {
        setError(e instanceof ApiError ? e.userMessage : "Could not save");
        return false;
      } finally {
        setSaving(false);
      }
    };
    const p = saveChain.current.then(run);
    saveChain.current = p.catch(() => undefined);
    return p;
  }, [note, complaints, assessment, enc, api, adopt]);

  // Autosave a few seconds after typing stops, and warn before leaving with unsaved text.
  useEffect(() => {
    if (!dirty || !editable) return;
    const t = setTimeout(() => void save(), 2500);
    return () => clearTimeout(t);
  }, [dirty, editable, save]);
  useEffect(() => {
    const warn = (e: BeforeUnloadEvent) => {
      if (dirty) e.preventDefault();
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [dirty]);

  if (loadError) {
    return <ErrorBanner message={loadError.status === 404 ? "This consultation is not available at this centre." : loadError.userMessage} />;
  }
  if (!enc || !note || !patient) return <Loading />;

  const setField = (f: NoteField | "encounter_type" | "follow_up_date", v: string) => {
    setNote({ ...note, [f]: v });
    setDirty(true);
  };
  const setA = <K extends keyof ClinicalAssessment>(k: K, v: ClinicalAssessment[K]) => {
    setAssessment({ ...assessment, [k]: v });
    setDirty(true);
  };
  const toggleComplaint = (c: Concept) => {
    setComplaints((list) => list.some((x) => x.concept_code === c.concept_code)
      ? list.filter((x) => x.concept_code !== c.concept_code)
      : [...list, { concept_code: c.concept_code, display_name: c.display_name, duration_value: null, duration_unit: "days", detail: null }]);
    setDirty(true);
  };
  const setComplaint = (code: string, patch: Partial<ComplaintEntry>) => {
    setComplaints((list) => list.map((x) => (x.concept_code === code ? { ...x, ...patch } : x)));
    setDirty(true);
  };

  const sign = async () => {
    if (dirty && !(await save())) return;
    setError(null);
    try {
      const r = await api<Encounter>(`/encounters/${enc.encounter_id}/sign`, { method: "POST", ifMatch: `"${version.current}"` });
      adopt(r.data, true);
      setConfirmSign(false);
      setNotice("Consultation signed. It can no longer be edited; use Amend to correct it.");
      void reloadSummary();
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not sign");
    }
  };

  const signed = enc.status !== "draft";
  const canAmend = signed && enc.status !== "entered_in_error" && can(role, "consult.sign");
  const textOrReadonly = (f: NoteField, rows?: number) => signed
    ? <Amendable key={f} enc={enc} field={f} canAmend={canAmend} onAmended={(e) => adopt(e, true)} />
    : <TextArea key={f} field={f} note={note} set={setField} disabled={!editable} rows={rows} />;

  const statusLine = saving ? "Saving…" : dirty ? "Unsaved changes" : savedAt ? `Saved ${savedAt.toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit", timeZone: membership?.timezone })}` : "";

  return (
    <>
      <div className="breadcrumb">
        <Link href="/patients">Patients</Link> / <Link href={`/patients/${id}`}>{patient.local_patient_code}</Link> / Consultation
      </div>
      <section className="card consult-head">
        <div style={{ minWidth: 0 }}>
          <div className="row" style={{ gap: 10 }}>
            <h1>{patient.display_name}</h1>
            <span className="muted">{ageSex(patient.age_years, patient.sex, patient.dob_precision === "estimated_from_age")}</span>
            <StatusBadge status={enc.status} />
          </div>
          <div className="small muted">
            {humanise(enc.encounter_type)} · {formatDateTime(enc.encounter_start, membership?.timezone)} · {enc.clinician_name}
            {enc.signed_at ? ` · signed ${formatDateTime(enc.signed_at, membership?.timezone)} by ${enc.signed_by_name}` : ""}
          </div>
          {summary && summary.allergies.length > 0 && (
            <div className="allergy-strip">
              {summary.allergies.map((a) => <span key={a.allergy_id} className="badge badge-danger">Allergy: {a.allergen_text}</span>)}
            </div>
          )}
        </div>
        {editable && (
          <div className="row consult-actions">
            <span className="small muted" aria-live="polite">{statusLine}</span>
            <button type="button" className="btn" onClick={() => void save()} disabled={saving || !dirty}>Save draft</button>
            {can(role, "consult.sign") && !confirmSign && (
              <button type="button" className="btn btn-primary" onClick={() => setConfirmSign(true)}>Sign</button>
            )}
            {confirmSign && (
              <>
                <span className="small">Sign and lock this note?</span>
                <button type="button" className="btn" onClick={() => setConfirmSign(false)}>Not yet</button>
                <button type="button" className="btn btn-primary" onClick={() => void sign()}>Sign and lock</button>
              </>
            )}
          </div>
        )}
      </section>
      {error && <div style={{ marginBottom: 12 }}><ErrorBanner message={error} /></div>}
      {notice && <div className="banner banner-info" role="status" style={{ marginBottom: 12 }}>{notice}</div>}

      <div className="consult-layout">
        <details className="summary-mobile card" >
          <summary>Previous visit, medicines and results</summary>
          {summary ? <ClinicalSummaryPanel summary={summary} patientId={id} currentEncounterId={enc.encounter_id} /> : <Loading />}
        </details>

        <div className="stack consult-main">
          <Card title="Presenting complaints">
            <div className="stack" style={{ gap: 12 }}>
              {!signed && (
                <div className="form-grid">
                  <Field label="Visit type" htmlFor="enc-type" className="span-2">
                    <select id="enc-type" className="input" value={note.encounter_type} disabled={!editable}
                      onChange={(e) => setField("encounter_type", e.target.value)}>
                      {TYPES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                    </select>
                  </Field>
                </div>
              )}
              <div className="chips" role="group" aria-label="Presenting complaints">
                {(signed ? enc.complaints.map((c) => ({ concept_code: c.concept_code, display_name: c.display_name ?? c.concept_code } as Concept)) : complaintList).map((c) => {
                  const on = complaints.some((x) => x.concept_code === c.concept_code);
                  return (
                    <button key={c.concept_code} type="button" className="chip" aria-pressed={on} disabled={!editable}
                      onClick={() => toggleComplaint(c)}>{c.display_name}</button>
                  );
                })}
                {signed && enc.complaints.length === 0 && <span className="muted">None recorded</span>}
              </div>
              {complaints.length > 0 && (
                <ul className="plain complaint-details">
                  {complaints.map((c) => (
                    <li key={c.concept_code}>
                      <span style={{ minWidth: 140 }}>{c.display_name ?? complaintList.find((x) => x.concept_code === c.concept_code)?.display_name}</span>
                      {signed ? (
                        <span className="muted small">
                          {c.duration_value !== null ? `${c.duration_value} ${c.duration_unit}` : ""}{c.detail ? ` · ${c.detail}` : ""}
                        </span>
                      ) : (
                        <span className="row" style={{ gap: 6, flex: 1, justifyContent: "flex-end" }}>
                          <input className="input" style={{ width: 70 }} inputMode="decimal" aria-label={`${c.display_name} duration`}
                            placeholder="For" value={c.duration_value ?? ""} disabled={!editable}
                            onChange={(e) => setComplaint(c.concept_code, { duration_value: e.target.value === "" ? null : Number(e.target.value) })} />
                          <select className="input" style={{ width: 100 }} aria-label={`${c.display_name} duration unit`}
                            value={c.duration_unit ?? "days"} disabled={!editable}
                            onChange={(e) => setComplaint(c.concept_code, { duration_unit: e.target.value })}>
                            {["hours", "days", "weeks", "months", "years"].map((u) => <option key={u}>{u}</option>)}
                          </select>
                          <input className="input" style={{ flex: 1, minWidth: 120 }} aria-label={`${c.display_name} detail`}
                            placeholder="Detail" value={c.detail ?? ""} disabled={!editable}
                            onChange={(e) => setComplaint(c.concept_code, { detail: e.target.value })} />
                        </span>
                      )}
                    </li>
                  ))}
                </ul>
              )}
              <div className="form-grid">
                {textOrReadonly("presenting_complaint", 2)}
              </div>
            </div>
          </Card>

          <Card title="History">
            <div className="form-grid">
              {textOrReadonly("history_present_illness", 4)}
              {textOrReadonly("clinical_history", 3)}
            </div>
          </Card>

          <Card title="Examination" actions={!signed && can(role, "vitals.record") && !showVitals
            ? <button type="button" className="btn btn-sm" onClick={() => setShowVitals(true)}>Record vitals</button> : undefined}>
            <div className="stack" style={{ gap: 14 }}>
              {enc.vitals.length > 0 ? (
                <ul className="plain">
                  {enc.vitals.map((v) => (
                    <li key={v.vital_id}><span>{vitalsLine(v)}</span><span className="small muted">{formatDateTime(v.measured_at, membership?.timezone)}</span></li>
                  ))}
                </ul>
              ) : !showVitals && <div className="muted small">No vitals recorded in this consultation.</div>}
              {showVitals && (
                <div className="subpanel">
                  <VitalsForm patientId={id} encounterId={enc.encounter_id} onCancel={() => setShowVitals(false)}
                    onSaved={() => { setShowVitals(false); void reloadEncounter(); void reloadSummary(); }} />
                </div>
              )}
              <div className="form-grid">
                <Select id="a-jvp" label="JVP" value={signed ? enc.clinical_assessment?.jvp ?? null : assessment.jvp} disabled={!editable}
                  options={[["normal", "Normal"], ["raised", "Raised"], ["not_assessable", "Not assessable"]]} onChange={(v) => setA("jvp", v)} />
                <Select id="a-oedema" label="Peripheral oedema" value={signed ? enc.clinical_assessment?.peripheral_oedema ?? null : assessment.peripheral_oedema}
                  disabled={!editable}
                  options={[["none", "None"], ["ankle", "Ankle"], ["below_knee", "Below knee"], ["above_knee", "Above knee"], ["sacral", "Sacral"], ["anasarca", "Anasarca"]]}
                  onChange={(v) => setA("peripheral_oedema", v)} />
                <Select id="a-congestion" label="Congestion" value={signed ? enc.clinical_assessment?.congestion_status ?? null : assessment.congestion_status}
                  disabled={!editable}
                  options={[["euvolaemic", "Euvolaemic"], ["mild", "Mild"], ["moderate", "Moderate"], ["severe", "Severe"]]}
                  onChange={(v) => setA("congestion_status", v)} />
                <Tri label="Basal crepitations" value={signed ? enc.clinical_assessment?.pulmonary_rales ?? null : assessment.pulmonary_rales} disabled={!editable} onChange={(v) => setA("pulmonary_rales", v)} />
                <Tri label="S3" value={signed ? enc.clinical_assessment?.s3_gallop ?? null : assessment.s3_gallop} disabled={!editable} onChange={(v) => setA("s3_gallop", v)} />
                <Tri label="Orthopnoea" value={signed ? enc.clinical_assessment?.orthopnoea ?? null : assessment.orthopnoea} disabled={!editable} onChange={(v) => setA("orthopnoea", v)} />
                <Tri label="PND" value={signed ? enc.clinical_assessment?.pnd ?? null : assessment.pnd} disabled={!editable} onChange={(v) => setA("pnd", v)} />
                {textOrReadonly("examination_cvs", 2)}
                {textOrReadonly("examination_resp", 2)}
                {textOrReadonly("examination_other", 2)}
              </div>
            </div>
          </Card>

          <Card title="Classification and diagnosis" actions={!signed && can(role, "diagnosis.write") && !showDx
            ? <button type="button" className="btn btn-sm" onClick={() => setShowDx(true)}>Add diagnosis</button> : undefined}>
            <div className="stack" style={{ gap: 14 }}>
              <div className="form-grid">
                <Select id="a-nyha" label="NYHA class" value={signed ? enc.clinical_assessment?.nyha_class ?? null : assessment.nyha_class} disabled={!editable}
                  options={[["I", "I"], ["II", "II"], ["III", "III"], ["IV", "IV"]]} onChange={(v) => setA("nyha_class", v)} />
                <Select id="a-ccs" label="CCS angina class" value={signed ? enc.clinical_assessment?.ccs_class ?? null : assessment.ccs_class} disabled={!editable}
                  options={[["0", "0 (no angina)"], ["I", "I"], ["II", "II"], ["III", "III"], ["IV", "IV"]]} onChange={(v) => setA("ccs_class", v)} />
                <Select id="a-phenotype" label="HF phenotype" value={signed ? enc.clinical_assessment?.hf_phenotype ?? null : assessment.hf_phenotype} disabled={!editable}
                  options={[["HFrEF", "HFrEF"], ["HFmrEF", "HFmrEF"], ["HFpEF", "HFpEF"], ["HFimpEF", "HFimpEF"]]} onChange={(v) => setA("hf_phenotype", v)} />
                <Select id="a-risk" label="CV risk category" value={signed ? enc.clinical_assessment?.cv_risk_category ?? null : assessment.cv_risk_category} disabled={!editable}
                  options={[["low", "Low"], ["moderate", "Moderate"], ["high", "High"], ["very_high", "Very high"], ["extreme", "Extreme (LAI)"]]}
                  onChange={(v) => setA("cv_risk_category", v)} />
              </div>
              {enc.diagnoses.length > 0 && (
                <ul className="plain">
                  {enc.diagnoses.map((d) => (
                    <li key={d.diagnosis_id}>
                      <span>
                        {d.is_principal && <span className="badge badge-info" style={{ marginRight: 6 }}>principal</span>}
                        {d.diagnosis_text}{d.icd10_code && <span className="muted mono small"> {d.icd10_code}</span>}
                      </span>
                      <span className="small muted">{ROLE_LABELS[d.diagnosis_role]}{d.certainty === "suspected" ? " · suspected" : ""}</span>
                    </li>
                  ))}
                </ul>
              )}
              {showDx && (
                <div className="subpanel">
                  <DiagnosisForm patientId={id} encounterId={enc.encounter_id} onCancel={() => setShowDx(false)}
                    onSaved={(d) => {
                      setShowDx(false);
                      if (d.new_registry_suggestions?.length) {
                        setNotice(`This diagnosis makes the patient eligible to screen for the ${d.new_registry_suggestions.map((s) => s.registry_code).join(", ")} registry.`);
                      }
                      void reloadEncounter();
                      void reloadSummary();
                    }} />
                </div>
              )}
              <div className="form-grid">{textOrReadonly("assessment", 3)}</div>
            </div>
          </Card>

          <Card title="Medicines">
            {signed ? (
              enc.medication_events.length ? (
                <ul className="plain">
                  {enc.medication_events.map((m) => (
                    <li key={m.medication_event_id} className={m.voided ? "voided" : undefined}><span>{encounterEventLine(m)}</span>
                      {m.instructions && <span className="small muted">{m.instructions}</span>}</li>
                  ))}
                </ul>
              ) : <div className="muted small">No medicine changes in this consultation.</div>
            ) : (
              <>
                <MedicationPanel patientId={id} encounterId={enc.encounter_id} canPrescribe={can(role, "meds.prescribe")}
                  onChanged={() => { void reloadEncounter(); void reloadSummary(); }} />
                {enc.medication_events.length > 0 && (
                  <div className="small muted" style={{ marginTop: 12 }}>
                    Changed in this consultation: {enc.medication_events.filter((m) => !m.voided).map(encounterEventLine).join("; ")}
                  </div>
                )}
              </>
            )}
          </Card>

          <Card title="Plan">
            <div className="form-grid">
              {textOrReadonly("plan", 3)}
              {textOrReadonly("lifestyle_advice", 2)}
              {textOrReadonly("patient_education", 2)}
              {signed ? textOrReadonly("referral_to") : (
                <Field label="Referral" htmlFor="n-referral_to" className="span-4">
                  <input id="n-referral_to" className="input" value={note.referral_to} disabled={!editable}
                    onChange={(e) => setField("referral_to", e.target.value)} />
                </Field>
              )}
              {signed ? (
                <div className="readonly-field span-2"><span className="label">Follow-up</span><div>{formatDate(enc.follow_up_date)}</div></div>
              ) : (
                <Field label="Follow-up date" htmlFor="n-follow_up_date" className="span-2">
                  <input id="n-follow_up_date" type="date" className="input" value={note.follow_up_date} disabled={!editable}
                    min={new Date().toISOString().slice(0, 10)} onChange={(e) => setField("follow_up_date", e.target.value)} />
                </Field>
              )}
            </div>
          </Card>
        </div>

        <aside className="consult-aside card" aria-label="Patient record">
          {summary ? <ClinicalSummaryPanel summary={summary} patientId={id} currentEncounterId={enc.encounter_id} /> : <Loading />}
        </aside>
      </div>
    </>
  );
}
