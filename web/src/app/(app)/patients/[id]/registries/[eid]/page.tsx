"use client";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import { ConsentForm } from "@/components/ConsentForm";
import { detailsBody, EnrolDetailsForm, useEnrolDetails } from "@/components/EnrolDetailsForm";
import { Card, ErrorBanner, Field, Loading, StatusBadge } from "@/components/ui";
import { ApiError, newIdempotencyKey } from "@/lib/api";
import { ageSex, formatDate } from "@/lib/format";
import { type Answer, criteria, eligibilityFrom, humanCode, REGISTRY_NAMES, SCHEDULE_LABEL } from "@/lib/registry";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import type { AssessmentHeader, ClinicalSummary, Enrolment, PatientOverview, Protocol, ScheduleItem } from "@/lib/types";

const today = () => new Date().toLocaleDateString("en-CA");

function Eligibility({ protocol, enrolment, canDecide, onDone }: {
  protocol: Protocol; enrolment: Enrolment; canDecide: boolean; onDone: (e: Enrolment) => void;
}) {
  const { api } = useSession();
  const list = criteria(protocol);
  const [answers, setAnswers] = useState<Record<string, Answer | undefined>>({});
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const result = eligibilityFrom(list, answers);

  const submit = async (status: "eligible" | "ineligible") => {
    setBusy(true);
    setError(null);
    try {
      const r = await api<Enrolment>(`/enrolments/${enrolment.enrolment_id}/eligibility`, {
        method: "PUT", ifMatch: `"${enrolment.row_version}"`,
        body: { eligibility_status: status, checklist: list.map((c) => ({ criterion_code: c.code, answer: answers[c.code] ?? "unknown" })) },
      });
      onDone(r.data);
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not record eligibility");
      setBusy(false);
    }
  };

  return (
    <Card title="1. Eligibility">
      <div className="stack" style={{ gap: 12 }}>
        {error && <ErrorBanner message={error} />}
        <ul className="plain criteria">
          {list.map((c) => (
            <li key={c.code}>
              <span><span className="badge">{c.kind === "inclusion" ? "Include" : "Exclude"}</span> {c.label}</span>
              <span className="segmented" role="group" aria-label={c.label}>
                {(["yes", "no", "unknown"] as Answer[]).map((a) => (
                  <button key={a} type="button" aria-pressed={answers[c.code] === a} disabled={!canDecide}
                    onClick={() => setAnswers({ ...answers, [c.code]: a })}>{a === "unknown" ? "Not sure" : humanCode(a)}</button>
                ))}
              </span>
            </li>
          ))}
        </ul>
        {!canDecide ? (
          <div className="small muted">A clinician or the principal investigator confirms eligibility.</div>
        ) : (
          <div className="row" style={{ justifyContent: "space-between" }}>
            <span className="small" aria-live="polite">
              {result === "eligible" ? "Meets every criterion." : result === "ineligible" ? "Does not meet the criteria." : "Answer every criterion."}
            </span>
            <span className="row">
              <button type="button" className="btn btn-danger" disabled={busy || result !== "ineligible"} onClick={() => void submit("ineligible")}>
                Record not eligible
              </button>
              <button type="button" className="btn btn-primary" disabled={busy || result !== "eligible"} onClick={() => void submit("eligible")}>
                Confirm eligible
              </button>
            </span>
          </div>
        )}
      </div>
    </Card>
  );
}

function Enrol({ enrolment, patient, summary, canEnrol, onDone, reloadPatient }: {
  enrolment: Enrolment; patient: PatientOverview; summary: ClinicalSummary | null; canEnrol: boolean;
  onDone: (e: Enrolment) => void; reloadPatient: () => void;
}) {
  const { api, selection } = useSession();
  const consents = patient.consents.filter((c) => c.consent_type === "research_registry" && c.protocol_id === enrolment.protocol_id
    && c.consent_status === "active");
  const [consentId, setConsentId] = useState("");
  const [adding, setAdding] = useState(false);
  const [indexDate, setIndexDate] = useState(today());
  const [enrolDate, setEnrolDate] = useState(today());
  const [v, setV] = useEnrolDetails(enrolment.registry_code, summary);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const chosen = consentId || consents[0]?.consent_id || "";
  const built = detailsBody(enrolment.registry_code, v);
  const index = enrolment.registry_code === "CAD" ? (v.index_event_date as string) || indexDate : indexDate;

  const enrol = async () => {
    if ("missing" in built) return;
    setBusy(true);
    setError(null);
    try {
      const r = await api<Enrolment>(`/enrolments/${enrolment.enrolment_id}/enrol`, {
        method: "POST", ifMatch: `"${enrolment.row_version}"`,
        body: { enrolment_date: enrolDate, index_date: index, consent_id: chosen, details: built.details },
      });
      onDone(r.data);
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not enrol");
      setBusy(false);
    }
  };

  return (
    <>
      <Card title="2. Research consent">
        {consents.length > 0 ? (
          <div className="stack" style={{ gap: 8 }}>
            {consents.length > 1 ? (
              <Field label="Consent this enrolment relies on" htmlFor="en-consent">
                <select id="en-consent" className="input" value={chosen} onChange={(e) => setConsentId(e.target.value)}>
                  {consents.map((c) => <option key={c.consent_id} value={c.consent_id}>{formatDate(c.consent_date)} · form {c.consent_form_version}</option>)}
                </select>
              </Field>
            ) : (
              <div><span className="badge badge-ok">consent recorded</span> {formatDate(consents[0].consent_date)} · form {consents[0].consent_form_version}</div>
            )}
          </div>
        ) : adding ? (
          <ConsentForm patientId={enrolment.patient_id} canResearch protocols={[]} presetProtocolId={enrolment.protocol_id}
            onCancel={() => setAdding(false)} onSaved={() => { setAdding(false); reloadPatient(); }} />
        ) : (
          <div className="row" style={{ justifyContent: "space-between" }}>
            <span className="small muted">No research consent for this registry yet. Enrolment needs it.</span>
            {can(selection?.role, "consent.research") && (
              <button type="button" className="btn btn-sm btn-primary" onClick={() => setAdding(true)}>Record consent</button>
            )}
          </div>
        )}
      </Card>
      <Card title={`3. ${REGISTRY_NAMES[enrolment.registry_code]} baseline`}>
        <div className="stack" style={{ gap: 14 }}>
          {error && <ErrorBanner message={error} />}
          <div className="form-grid">
            {enrolment.registry_code !== "CAD" && (
              <Field label="Index date" htmlFor="en-index" required className="span-2"
                hint={enrolment.registry_code === "HF" ? "Visit days count from here" : undefined}>
                <input id="en-index" type="date" className="input" value={indexDate} max={today()} onChange={(e) => setIndexDate(e.target.value)} />
              </Field>
            )}
            <Field label="Enrolment date" htmlFor="en-date" className="span-2">
              <input id="en-date" type="date" className="input" value={enrolDate} max={today()} onChange={(e) => setEnrolDate(e.target.value)} />
            </Field>
          </div>
          <EnrolDetailsForm registry={enrolment.registry_code} v={v} set={setV} summary={summary} />
          {canEnrol ? (
            <div className="row" style={{ justifyContent: "space-between" }}>
              <span className="small muted" aria-live="polite">
                {!chosen ? "Record research consent first." : "missing" in built ? `Still needed: ${built.missing}.` : "Ready to enrol."}
              </span>
              <button type="button" className="btn btn-primary" disabled={busy || !chosen || "missing" in built} onClick={() => void enrol()}>
                {busy ? "Enrolling…" : "Enrol"}
              </button>
            </div>
          ) : <div className="small muted">A clinician or the principal investigator enrols the patient.</div>}
        </div>
      </Card>
    </>
  );
}

function ScheduleCard({ enrolment, assessments, onOpen, busy }: {
  enrolment: Enrolment; assessments: AssessmentHeader[]; onOpen: (s: ScheduleItem | null) => void; busy: boolean;
}) {
  const { selection } = useSession();
  const canAssess = can(selection?.role, "registry.assess");
  const byId = new Map(assessments.map((a) => [a.assessment_id, a]));
  const items = (enrolment.schedule ?? []).filter((s, i, all) =>
    s.status !== "not_due" || all.findIndex((x) => x.status === "not_due") === i || s.assessment_id);
  const extra = assessments.filter((a) => !enrolment.schedule?.some((s) => s.assessment_id === a.assessment_id));
  return (
    <Card title="Visits" flush actions={canAssess && enrolment.enrolment_status === "enrolled" ? (
      <button type="button" className="btn btn-sm" disabled={busy} onClick={() => onOpen(null)}>Unscheduled visit</button>
    ) : undefined}>
      <ul className="plain schedule">
        {items.map((s) => {
          const a = s.assessment_id ? byId.get(s.assessment_id) : undefined;
          return (
            <li key={`${s.visit_code}-${s.occurrence}`} data-status={s.status}>
              <span>
                <strong>{s.visit_code}{s.occurrence > 1 ? ` #${s.occurrence}` : ""}</strong>
                <span className="small muted"> · due {formatDate(s.target_date)} (window {formatDate(s.window_opens)} to {formatDate(s.window_closes)})</span>
                {a && <><br /><span className="small muted">Seen {formatDate(a.assessment_date)} · {humanCode(a.completion_status)}{a.locked_at ? " · locked" : ""}</span></>}
              </span>
              <span className="row" style={{ gap: 6 }}>
                <span className={`badge ${s.status === "overdue" ? "badge-danger" : s.status === "due" ? "badge-warn" : s.status === "done" ? "badge-ok" : ""}`}>
                  {SCHEDULE_LABEL[s.status]}
                </span>
                {a ? (
                  <Link className="btn btn-sm" href={`/patients/${enrolment.patient_id}/registries/${enrolment.enrolment_id}/assessments/${a.assessment_id}`}>Open</Link>
                ) : canAssess && enrolment.enrolment_status === "enrolled" && s.status !== "not_due" && (
                  <button type="button" className="btn btn-sm btn-primary" disabled={busy} onClick={() => onOpen(s)}>Start visit</button>
                )}
              </span>
            </li>
          );
        })}
        {extra.map((a) => (
          <li key={a.assessment_id}>
            <span><strong>{a.visit_code}</strong> <span className="small muted">· {humanCode(a.assessment_type)} · {formatDate(a.assessment_date)} · {humanCode(a.completion_status)}</span></span>
            <Link className="btn btn-sm" href={`/patients/${enrolment.patient_id}/registries/${enrolment.enrolment_id}/assessments/${a.assessment_id}`}>Open</Link>
          </li>
        ))}
      </ul>
    </Card>
  );
}

function StatusChange({ enrolment, onDone }: { enrolment: Enrolment; onDone: (e: Enrolment) => void }) {
  const { api } = useSession();
  const [open, setOpen] = useState(false);
  const [status, setStatus] = useState("withdrawn");
  const [date, setDate] = useState(today());
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  if (!open) return <button type="button" className="btn btn-sm btn-danger" onClick={() => setOpen(true)}>End participation</button>;
  const save = async () => {
    setError(null);
    try {
      const r = await api<Enrolment>(`/enrolments/${enrolment.enrolment_id}/status`, {
        method: "POST", ifMatch: `"${enrolment.row_version}"`, changeReason: reason.trim(),
        body: { enrolment_status: status, status_changed_on: date, withdrawal_reason: status === "withdrawn" ? reason.trim() : undefined },
      });
      onDone(r.data);
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not change the status");
    }
  };
  return (
    <div className="subpanel stack" style={{ gap: 10 }}>
      {error && <ErrorBanner message={error} />}
      <div className="form-grid">
        <Field label="New status" htmlFor="st-status" className="span-2">
          <select id="st-status" className="input" value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="withdrawn">Withdrawn</option><option value="lost_to_follow_up">Lost to follow-up</option>
            <option value="deceased">Deceased</option><option value="completed">Completed the study</option>
          </select>
        </Field>
        <Field label="From" htmlFor="st-date" className="span-2">
          <input id="st-date" type="date" className="input" value={date} max={today()} onChange={(e) => setDate(e.target.value)} />
        </Field>
        <Field label="Reason" htmlFor="st-reason" required className="span-2">
          <input id="st-reason" className="input" value={reason} onChange={(e) => setReason(e.target.value)} />
        </Field>
      </div>
      {status === "deceased" && <div className="small muted">Record the death as an event too, so it can be adjudicated.</div>}
      <div className="row" style={{ justifyContent: "flex-end" }}>
        <button type="button" className="btn btn-sm" onClick={() => setOpen(false)}>Cancel</button>
        <button type="button" className="btn btn-sm btn-danger" disabled={reason.trim().length < 3} onClick={() => void save()}>Save</button>
      </div>
    </div>
  );
}

function DetailsSummary({ details }: { details: Record<string, unknown> | null }) {
  if (!details) return null;
  const skip = new Set(["registry_code", "detail_id", "phenotype_confirmed_by", "baseline_lvef_investigation_id",
    "baseline_ldl_result_id", "lpa_result_id"]);
  const rows = Object.entries(details).filter(([k, x]) => !skip.has(k) && x !== null && x !== "" && !(Array.isArray(x) && !x.length));
  return (
    <dl className="facts">
      {rows.map(([k, x]) => (
        <div key={k} style={{ display: "contents" }}>
          <dt>{humanCode(k)}</dt>
          <dd>{Array.isArray(x) ? x.map((i) => humanCode(String(i))).join(", ") : typeof x === "boolean" ? (x ? "Yes" : "No")
            : /^\d{4}-\d{2}-\d{2}$/.test(String(x)) ? formatDate(String(x)) : humanCode(String(x))}</dd>
        </div>
      ))}
    </dl>
  );
}

export default function EnrolmentPage() {
  const { id, eid } = useParams<{ id: string; eid: string }>();
  const router = useRouter();
  const { api, selection } = useSession();
  const role = selection?.role;
  const [enrolment, setEnrolment] = useState<Enrolment | null>(null);
  const [protocol, setProtocol] = useState<Protocol | null>(null);
  const [patient, setPatient] = useState<PatientOverview | null>(null);
  const [summary, setSummary] = useState<ClinicalSummary | null>(null);
  const [assessments, setAssessments] = useState<AssessmentHeader[]>([]);
  const [error, setError] = useState<ApiError | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const keys = useRef<Record<string, string>>({});

  const loadPatient = useCallback(async () => {
    setPatient((await api<PatientOverview>(`/patients/${id}`)).data);
  }, [api, id]);
  const loadAssessments = useCallback(async () => {
    setAssessments((await api<{ items: AssessmentHeader[] }>(`/enrolments/${eid}/assessments`)).data.items);
  }, [api, eid]);

  useEffect(() => {
    (async () => {
      try {
        const e = (await api<Enrolment>(`/enrolments/${eid}`)).data;
        setEnrolment(e);
        const [p] = await Promise.all([api<Protocol>(`/protocols/${e.protocol_id}`), loadPatient(), loadAssessments()]);
        setProtocol(p.data);
        api<ClinicalSummary>(`/patients/${id}/clinical-summary`).then((r) => setSummary(r.data)).catch(() => undefined);
      } catch (err) {
        setError(err instanceof ApiError ? err : new ApiError(0, "NETWORK", "Could not load the enrolment"));
      }
    })();
  }, [api, id, eid, loadPatient, loadAssessments]);

  const openVisit = async (s: ScheduleItem | null) => {
    if (!enrolment) return;
    setBusy(true);
    setActionError(null);
    const k = s ? `${s.visit_code}-${s.occurrence}` : "unscheduled";
    keys.current[k] ??= newIdempotencyKey();
    try {
      const r = await api<AssessmentHeader>(`/enrolments/${eid}/assessments`, {
        method: "POST", idempotencyKey: keys.current[k],
        body: s
          ? { visit_code: s.visit_code, assessment_type: s.visit_code === "BL" ? "baseline" : "scheduled", assessment_date: today(), prefill: true }
          : { visit_code: "UNSCHED", assessment_type: "unscheduled", assessment_date: today(), prefill: true },
      });
      router.push(`/patients/${id}/registries/${eid}/assessments/${r.data.assessment_id}?prefilled=1`);
    } catch (e) {
      delete keys.current[k];
      setActionError(e instanceof ApiError ? e.userMessage : "Could not open the visit");
      setBusy(false);
    }
  };

  if (error) {
    return (
      <>
        <div className="breadcrumb"><Link href="/patients">Patients</Link> / <Link href={`/patients/${id}`}>Patient</Link></div>
        <ErrorBanner message={error.status === 404 ? "This enrolment is not at this centre." : error.userMessage} />
      </>
    );
  }
  if (!enrolment || !protocol || !patient) return <Loading />;
  const p = patient.patient;
  const screening = enrolment.enrolment_status === "screening";

  return (
    <>
      <div className="breadcrumb">
        <Link href="/patients">Patients</Link> / <Link href={`/patients/${id}`}>{p.local_patient_code}</Link> / {REGISTRY_NAMES[enrolment.registry_code]} registry
      </div>
      <section className="card patient-header">
        <div>
          <div className="row" style={{ gap: 10 }}>
            <h1>{p.display_name}</h1>
            <span className="muted">{ageSex(p.age_years, p.sex, p.dob_precision === "estimated_from_age")}</span>
          </div>
          <div className="meta">
            <span>{REGISTRY_NAMES[enrolment.registry_code]} registry · {protocol.protocol_code} v{protocol.protocol_version}</span>
            {enrolment.study_subject_code && <span className="mono">{enrolment.study_subject_code}</span>}
            {enrolment.index_date && <span>Index {formatDate(enrolment.index_date)}</span>}
            <StatusBadge status={enrolment.enrolment_status} />
          </div>
        </div>
        {enrolment.enrolment_status === "enrolled" && can(role, "registry.enrol") && (
          <StatusChange enrolment={enrolment} onDone={setEnrolment} />
        )}
      </section>
      {actionError && <div style={{ marginBottom: 12 }}><ErrorBanner message={actionError} /></div>}

      {screening && (
        <div className="stack">
          {enrolment.eligibility_status === "pending_review" ? (
            <Eligibility protocol={protocol} enrolment={enrolment} canDecide={can(role, "registry.enrol")} onDone={setEnrolment} />
          ) : (
            <Card title="1. Eligibility"><span className="badge badge-ok">eligible</span> <span className="small muted">Confirmed.</span></Card>
          )}
          {enrolment.eligibility_status === "eligible" && (
            <Enrol enrolment={enrolment} patient={patient} summary={summary} canEnrol={can(role, "registry.enrol")}
              onDone={(e) => { setEnrolment(e); void loadAssessments(); }} reloadPatient={() => void loadPatient()} />
          )}
        </div>
      )}

      {enrolment.enrolment_status === "screen_failed" && (
        <div className="banner banner-warn">Did not meet the eligibility criteria on {formatDate(enrolment.status_changed_on)}.</div>
      )}

      {!screening && enrolment.enrolment_status !== "screen_failed" && (
        <div className="grid-2">
          <ScheduleCard enrolment={enrolment} assessments={assessments} onOpen={(s) => void openVisit(s)} busy={busy} />
          <Card title="Baseline at enrolment">
            <DetailsSummary details={enrolment.details} />
          </Card>
        </div>
      )}
    </>
  );
}
