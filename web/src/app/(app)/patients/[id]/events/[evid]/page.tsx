"use client";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { EventForm } from "@/components/EventForm";
import { Card, ErrorBanner, Field, Loading, StatusBadge } from "@/components/ui";
import { ApiError, newIdempotencyKey } from "@/lib/api";
import {
  ADJ_STATUS, EVENT_OPTIONS, EVENT_TYPES, eventBody, eventDate, eventDraftOf, eventLine, label, newEvent, validateEvent,
  type EventDraft,
} from "@/lib/cad";
import { formatDate, formatDateTime } from "@/lib/format";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import type { EventWithAdjudications, PciProcedure } from "@/lib/types";
import { usePatient } from "@/lib/usePatient";

const today = () => new Date().toLocaleDateString("en-CA");

export default function EventPage() {
  const { id, evid } = useParams<{ id: string; evid: string }>();
  const isNew = evid === "new";
  const router = useRouter();
  const { api, selection, me, membership } = useSession();
  const { data: patient } = usePatient(id);
  const role = selection?.role;
  const [data, setData] = useState<EventWithAdjudications | null>(null);
  const [etag, setEtag] = useState<string | null>(null);
  const [procedures, setProcedures] = useState<PciProcedure[]>([]);
  const [draft, setDraft] = useState<EventDraft>(newEvent(today()));
  const [editing, setEditing] = useState(isNew);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [withdrawing, setWithdrawing] = useState(false);
  const key = useRef<string | null>(null);

  useEffect(() => {
    if (can(role, "pci.read")) {
      api<{ items: PciProcedure[] }>(`/patients/${id}/pci-procedures`)
        .then((r) => setProcedures(r.data.items.filter((p) => p.status !== "entered_in_error"))).catch(() => setProcedures([]));
    }
  }, [api, id, role]);
  useEffect(() => {
    if (isNew) return;
    api<EventWithAdjudications>(`/events/${evid}`)
      .then((r) => { setData(r.data); setEtag(r.etag); setDraft(eventDraftOf(r.data.event)); })
      .catch((e) => setError(e instanceof ApiError ? e.userMessage : "Could not load the event"));
  }, [api, evid, isNew]);

  const save = async (status?: "entered_in_error") => {
    const errs = status ? {} : validateEvent(draft, today());
    setErrors(errs);
    if (Object.keys(errs).length) {
      setError("Some answers need attention.");
      return;
    }
    if (!isNew && reason.trim().length < 3) {
      setError("Give a reason for the change.");
      document.getElementById("ev-reason")?.focus();
      return;
    }
    setBusy(true);
    setError(null);
    try {
      if (isNew) {
        key.current ??= newIdempotencyKey();
        const r = await api<EventWithAdjudications>("/events", {
          method: "POST", idempotencyKey: key.current,
          body: { patient_id: id, event_type: draft.event_type, ...eventBody(draft) },
        });
        router.replace(`/patients/${id}/events/${r.data.event.event_id}`);
        return;
      }
      const r = await api<EventWithAdjudications>(`/events/${evid}`, {
        method: "PUT", ifMatch: etag ?? undefined, changeReason: reason.trim(),
        body: { ...eventBody(draft), status: status ?? (data!.event.status === "source_verified" ? "source_verified" : "reported") },
      });
      setData(r.data);
      setEtag(r.etag);
      setDraft(eventDraftOf(r.data.event));
      setEditing(false);
      setWithdrawing(false);
      setReason("");
    } catch (e) {
      key.current = null;
      setError(e instanceof ApiError ? (e.status === 412 ? "Someone else changed this event. Reload to see their version." : e.userMessage) : "Could not save");
    } finally {
      setBusy(false);
    }
  };

  const crumbs = (
    <div className="breadcrumb">
      <Link href="/patients">Patients</Link> / <Link href={`/patients/${id}`}>{patient?.patient.display_name ?? "Patient"}</Link> / Event
    </div>
  );
  if (!isNew && !data) return <>{crumbs}{error ? <ErrorBanner message={error} /> : <Loading />}</>;
  const ev = data?.event;
  const mine = ev && me && ev.reported_by === me.user_id;

  return (
    <>
      {crumbs}
      <div className="page-head">
        <div>
          <h1>{isNew ? "Report an event" : eventLine(ev!)}</h1>
          {ev && (
            <p>
              <StatusBadge status={ev.status} /> {eventDate(ev.event_date, ev.event_date_precision)}
              {ev.is_historical ? " · past history" : ""} · reported {formatDateTime(ev.created_at, membership?.timezone)}{mine ? " by you" : ""}
            </p>
          )}
        </div>
        {ev && !editing && ev.status !== "entered_in_error" && can(role, "event.correct") && (
          <div className="row">
            <button type="button" className="btn" onClick={() => setWithdrawing(true)}>Mark entered in error</button>
            <button type="button" className="btn btn-primary" onClick={() => setEditing(true)}>Correct details</button>
          </div>
        )}
      </div>
      {error && <div style={{ marginBottom: 16 }}><ErrorBanner message={error} /></div>}

      {withdrawing && !editing && (
        <div className="subpanel stack" style={{ gap: 12, marginBottom: 16 }}>
          <h3>Mark this event entered in error</h3>
          <p className="small muted">Its open adjudications close. To change the event type, do this and report the event again.</p>
          <Field label="Reason" htmlFor="ev-reason" required>
            <input id="ev-reason" className="input" value={reason} onChange={(e) => setReason(e.target.value)} />
          </Field>
          <div className="row">
            <button type="button" className="btn" onClick={() => setWithdrawing(false)}>Cancel</button>
            <button type="button" className="btn btn-danger" disabled={busy || reason.trim().length < 3} onClick={() => void save("entered_in_error")}>
              Mark entered in error
            </button>
          </div>
        </div>
      )}

      {editing ? (
        <Card>
          <EventForm draft={draft} set={setDraft} errors={errors} today={today()} typeFixed={!isNew} procedures={procedures} />
          {!isNew && (
            <p className="small muted" style={{ marginTop: 12 }}>
              Changing the date, hospital stay or classification details sends adjudicated outcomes back for review.
            </p>
          )}
          <div className="form-actions">
            {!isNew && (
              <Field label="Reason for the change" htmlFor="ev-reason" required className="span-6">
                <input id="ev-reason" className="input" value={reason} onChange={(e) => setReason(e.target.value)} />
              </Field>
            )}
            {isNew ? <Link className="btn" href={`/patients/${id}`}>Cancel</Link> : (
              <button type="button" className="btn" onClick={() => { setEditing(false); setDraft(eventDraftOf(ev!)); setErrors({}); setError(null); }}>Cancel</button>
            )}
            <button type="button" className="btn btn-primary" disabled={busy} onClick={() => void save()}>
              {busy ? "Saving…" : isNew ? "Report event" : "Save correction"}
            </button>
          </div>
        </Card>
      ) : ev && (
        <div className="grid-2">
          <Card title="Details">
            <dl className="facts">
              <dt>Event</dt><dd>{label(EVENT_TYPES, ev.event_type)}</dd>
              <dt>Date</dt><dd>{eventDate(ev.event_date, ev.event_date_precision)}</dd>
              {ev.death_cause && <><dt>Cause of death</dt><dd>{label(EVENT_OPTIONS.death_cause, ev.death_cause)}{ev.death_cv_mode ? ` · ${label(EVENT_OPTIONS.death_cv_mode, ev.death_cv_mode)}` : ""}</dd></>}
              {ev.mi_type && <><dt>MI type</dt><dd>{label(EVENT_OPTIONS.mi_type, ev.mi_type)}</dd></>}
              {ev.stroke_type && <><dt>Stroke type</dt><dd>{label(EVENT_OPTIONS.stroke_type, ev.stroke_type)}</dd></>}
              {ev.bleeding_site && <><dt>Bleeding site</dt><dd>{ev.bleeding_site}</dd></>}
              {ev.potassium_mmol_l != null && <><dt>Potassium</dt><dd>{ev.potassium_mmol_l} mmol/L</dd></>}
              {ev.pci_procedure_id && (
                <><dt>Related PCI</dt><dd><Link href={`/patients/${id}/pci/${ev.pci_procedure_id}`}>
                  {procedures.find((p) => p.procedure_id === ev.pci_procedure_id)?.procedure_date
                    ? formatDate(procedures.find((p) => p.procedure_id === ev.pci_procedure_id)!.procedure_date) : "Open"}
                </Link></dd></>
              )}
              <dt>Hospital stay</dt>
              <dd>{ev.hospitalised ? `${ev.admission_date ? formatDate(ev.admission_date) : "?"} to ${ev.discharge_date ? formatDate(ev.discharge_date) : "?"}` : ev.hospitalised === false ? "Not admitted" : "—"}</dd>
              <dt>Place</dt><dd>{ev.facility_name ?? "—"}</dd>
              <dt>Severity, outcome</dt><dd>{label(EVENT_OPTIONS.severity, ev.severity) || "—"}, {label(EVENT_OPTIONS.outcome, ev.outcome) || "—"}</dd>
              <dt>Source</dt><dd>{label(EVENT_OPTIONS.source, ev.source)}</dd>
              <dt>Description</dt><dd>{ev.description ?? "—"}</dd>
            </dl>
          </Card>
          {can(role, "adjudication.read") && (
            <Card title="Registry outcomes" flush>
              {data!.adjudications.length === 0 ? (
                <div className="empty">
                  {ev.is_historical ? "Past history is not adjudicated." : "This event is not an outcome in any registry the patient is enrolled in."}
                </div>
              ) : (
                <ul className="plain">
                  {data!.adjudications.map((a) => (
                    <li key={a.adjudication_id}>
                      <span>
                        {a.endpoint_label ?? a.endpoint_code}
                        <br /><span className="small muted">{a.protocol_code}{a.classification ? ` · ${a.classification_system ?? ""} ${a.classification}` : ""}
                          {a.meets_endpoint === true ? " · meets endpoint" : a.meets_endpoint === false ? " · does not meet endpoint" : ""}</span>
                      </span>
                      <span className="row" style={{ gap: 6 }}>
                        <span className={`badge ${a.adjudication_status === "adjudicated" ? "badge-ok" : a.adjudication_status === "pending" ? "badge-warn" : ""}`}>
                          {label(ADJ_STATUS, a.adjudication_status)}
                        </span>
                        {can(role, "adjudication.decide") && !mine && (
                          <Link className="small" href={`/adjudication?item=${a.adjudication_id}&event=${a.event_id}`}>Adjudicate</Link>
                        )}
                      </span>
                    </li>
                  ))}
                </ul>
              )}
              {mine && data!.adjudications.length > 0 && (
                <div className="card-body small muted">You reported this event, so another clinician or the PI adjudicates it.</div>
              )}
            </Card>
          )}
        </div>
      )}
    </>
  );
}
