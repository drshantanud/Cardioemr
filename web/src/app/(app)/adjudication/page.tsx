"use client";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { Suspense, useCallback, useEffect, useState } from "react";
import { Card, ErrorBanner, Field, Loading } from "@/components/ui";
import { ApiError } from "@/lib/api";
import {
  ADJ_STATUS, classificationsFor, decides, EVENT_OPTIONS, EVENT_TYPES, eventDate, label,
} from "@/lib/cad";
import { formatDate, formatDateTime } from "@/lib/format";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import type { Adjudication, Classification, EventWithAdjudications, Registry } from "@/lib/types";

const QUEUE_STATUSES = ["pending", "in_review", "insufficient_data", "adjudicated", "not_an_event"] as const;
type QueueStatus = (typeof QUEUE_STATUSES)[number];

function Decision({ a, classifications, onSaved }: {
  a: Adjudication; classifications: Classification[]; onSaved: (a: Adjudication) => void;
}) {
  const { api, selection, me, membership } = useSession();
  const role = selection?.role;
  const [classification, setClassification] = useState(a.classification ?? "");
  const [meets, setMeets] = useState<"" | "yes" | "no">(a.meets_endpoint == null ? "" : a.meets_endpoint ? "yes" : "no");
  const [committee, setCommittee] = useState(a.committee_reference ?? "");
  const [notes, setNotes] = useState(a.notes ?? "");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const codes = classificationsFor(classifications, a.classification_system);
  const auto = decides(a.qualifying_classifications);
  const decided = a.adjudication_status === "adjudicated" || a.adjudication_status === "not_an_event";
  const mine = me && a.event.reported_by === me.user_id;
  const canDecide = can(role, "adjudication.decide") && !mine && a.event.event_status !== "entered_in_error"
    && a.adjudication_status !== "event_withdrawn";
  const autoMeets = auto && classification ? a.qualifying_classifications!.includes(classification) : null;

  const submit = async (status: Adjudication["adjudication_status"]) => {
    if (status === "adjudicated" && !classification && !meets) {
      setError(auto ? "Choose the classification." : "Choose the classification or say whether it meets the endpoint.");
      return;
    }
    if (decided && reason.trim().length < 3) {
      setError("Give a reason for changing a decision.");
      document.getElementById("adj-reason")?.focus();
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const r = await api<Adjudication>(`/events/${a.event_id}/adjudications/${a.adjudication_id}`, {
        method: "PUT", ifMatch: `"${a.row_version}"`, changeReason: decided ? reason.trim() : undefined,
        body: {
          adjudication_status: status, endpoint_code: a.endpoint_code ?? undefined,
          classification: status === "adjudicated" ? classification || null : classification || null,
          meets_endpoint: status === "adjudicated" && !auto && meets ? meets === "yes" : null,
          committee_reference: committee.trim() || null, notes: notes.trim() || null,
        },
      });
      setReason("");
      onSaved(r.data);
    } catch (e) {
      setError(e instanceof ApiError ? (e.status === 412 ? "Someone else changed this decision. Reload the queue." : e.userMessage) : "Could not save");
    } finally {
      setBusy(false);
    }
  };

  const ev = a.event;
  return (
    <Card title={`${a.endpoint_label ?? a.endpoint_code} · ${a.protocol_code}`}>
      <div className="stack" style={{ gap: 12 }}>
        <dl className="facts">
          <dt>Subject</dt>
          <dd>
            <span className="mono">{a.study_subject_code ?? "—"}</span> · {a.centre_code}
            {a.patient_id && <> · <Link href={`/patients/${a.patient_id}/events/${a.event_id}`}>open record</Link></>}
          </dd>
          <dt>Event</dt>
          <dd>
            {label(EVENT_TYPES, a.event_type)} · {eventDate(a.event_date, ev.event_date_precision)}
            {a.event_day != null ? ` · day ${a.event_day} after enrolment` : ""}
          </dd>
          {ev.death_cause && <><dt>Reported cause</dt><dd>{label(EVENT_OPTIONS.death_cause, ev.death_cause)}{ev.death_cv_mode ? ` · ${label(EVENT_OPTIONS.death_cv_mode, ev.death_cv_mode)}` : ""}</dd></>}
          {ev.mi_type && <><dt>Reported MI type</dt><dd>{ev.mi_type}</dd></>}
          {ev.stroke_type && <><dt>Reported stroke type</dt><dd>{ev.stroke_type}</dd></>}
          {ev.bleeding_site && <><dt>Bleeding site</dt><dd>{ev.bleeding_site}</dd></>}
          <dt>Hospital stay</dt>
          <dd>{ev.hospitalised ? `${ev.admission_date ? formatDate(ev.admission_date) : "?"} to ${ev.discharge_date ? formatDate(ev.discharge_date) : "?"}` : ev.hospitalised === false ? "Not admitted" : "—"}{ev.facility_name ? ` · ${ev.facility_name}` : ""}</dd>
          <dt>Severity, outcome</dt><dd>{label(EVENT_OPTIONS.severity, ev.severity) || "—"}, {label(EVENT_OPTIONS.outcome, ev.outcome) || "—"}</dd>
          <dt>Source</dt><dd>{label(EVENT_OPTIONS.source, ev.source)} · reported {formatDateTime(ev.reported_at, membership?.timezone)}</dd>
          <dt>Description</dt><dd>{ev.description ?? "—"}</dd>
          {decided && (
            <><dt>Decision</dt><dd>
              {label(ADJ_STATUS, a.adjudication_status)}{a.classification ? ` · ${codes.find((c) => c.code === a.classification)?.label ?? a.classification}` : ""}
              {a.meets_endpoint != null ? ` · ${a.meets_endpoint ? "meets" : "does not meet"} the endpoint` : ""}
              {a.adjudicated_at ? ` · ${formatDateTime(a.adjudicated_at, membership?.timezone)}` : ""}
            </dd></>
          )}
        </dl>
        {mine && <div className="banner banner-info">You reported this event, so someone else must adjudicate it.</div>}
        {a.event.event_status === "entered_in_error" && <div className="banner banner-warn">The event was marked entered in error. This adjudication is closed.</div>}
        {canDecide && (
          <>
            {error && <ErrorBanner message={error} />}
            <div className="form-grid">
              {codes.length > 0 && (
                <Field label={`Classification (${a.classification_system})`} htmlFor="adj-class" className="span-3"
                  hint={auto && classification ? (autoMeets ? "Meets the endpoint" : "Does not meet the endpoint") : undefined}>
                  <select id="adj-class" className="input" value={classification} onChange={(e) => setClassification(e.target.value)}>
                    <option value="">Choose…</option>
                    {codes.map((c) => <option key={c.code} value={c.code}>{c.label}</option>)}
                  </select>
                </Field>
              )}
              {!auto && (
                <Field label="Meets the endpoint" htmlFor="adj-meets" className="span-3">
                  <select id="adj-meets" className="input" value={meets} onChange={(e) => setMeets(e.target.value as typeof meets)}>
                    <option value="">—</option><option value="yes">Yes</option><option value="no">No</option>
                  </select>
                </Field>
              )}
              <Field label="Committee reference" htmlFor="adj-cref" className="span-3" hint="Meeting or minutes reference, if any">
                <input id="adj-cref" className="input" value={committee} onChange={(e) => setCommittee(e.target.value)} />
              </Field>
              <Field label="Notes" htmlFor="adj-notes" className="span-6">
                <textarea id="adj-notes" className="input" rows={3} value={notes} onChange={(e) => setNotes(e.target.value)} />
              </Field>
              {decided && (
                <Field label="Reason for changing the decision" htmlFor="adj-reason" required className="span-6">
                  <input id="adj-reason" className="input" value={reason} onChange={(e) => setReason(e.target.value)} />
                </Field>
              )}
            </div>
            <div className="row" style={{ justifyContent: "flex-end", flexWrap: "wrap" }}>
              {a.adjudication_status !== "in_review" && !decided && (
                <button type="button" className="btn btn-sm" disabled={busy} onClick={() => void submit("in_review")}>Mark in review</button>
              )}
              <button type="button" className="btn btn-sm" disabled={busy} onClick={() => void submit("insufficient_data")}>Needs more data</button>
              <button type="button" className="btn btn-sm" disabled={busy} onClick={() => void submit("not_an_event")}>Not an event</button>
              <button type="button" className="btn btn-sm btn-primary" disabled={busy} onClick={() => void submit("adjudicated")}>Save decision</button>
            </div>
          </>
        )}
      </div>
    </Card>
  );
}

function Queue() {
  const { api, selection } = useSession();
  const role = selection?.role;
  const params = useSearchParams();
  const router = useRouter();
  const [protocols, setProtocols] = useState<{ protocol_id: string; label: string }[]>([]);
  const [protocolId, setProtocolId] = useState("");
  const [status, setStatus] = useState<QueueStatus>("pending");
  const [items, setItems] = useState<Adjudication[] | null>(null);
  const [cursor, setCursor] = useState<string | null>(null);
  const [selected, setSelected] = useState<Adjudication | null>(null);
  const [classifications, setClassifications] = useState<Classification[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);

  useEffect(() => {
    api<{ items: Registry[] }>("/registries").then((r) => {
      const list = r.data.items.flatMap((g) => g.protocols.map((p) => ({ protocol_id: p.protocol_id, label: `${p.protocol_code} v${p.protocol_version} · ${g.registry_name}` })));
      setProtocols(list);
      setProtocolId((cur) => cur || list[0]?.protocol_id || "");
    }).catch((e) => setError(e instanceof ApiError ? e.userMessage : "Could not load the registries"));
    api<{ items: Classification[] }>("/adjudication-classifications").then((r) => setClassifications(r.data.items)).catch(() => undefined);
  }, [api]);

  // Deep link from an event: open that adjudication whatever its queue.
  const item = params.get("item");
  const eventId = params.get("event");
  useEffect(() => {
    if (!item || !eventId) return;
    api<EventWithAdjudications>(`/events/${eventId}`).then((r) => {
      const a = r.data.adjudications.find((x) => x.adjudication_id === item);
      if (a) setSelected(a);
    }).catch(() => undefined);
  }, [api, item, eventId]);

  const load = useCallback(async (after?: string | null) => {
    if (!protocolId) return;
    setError(null);
    try {
      const r = await api<{ items: Adjudication[]; next_cursor: string | null }>(`/protocols/${protocolId}/adjudication-queue`, {
        query: { status, limit: 50, cursor: after ?? undefined },
      });
      setItems((cur) => (after && cur ? [...cur, ...r.data.items] : r.data.items));
      setCursor(r.data.next_cursor);
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not load the queue");
    }
  }, [api, protocolId, status]);
  useEffect(() => { setItems(null); void load(); }, [load]);

  useEffect(() => {
    if (selected && window.matchMedia("(max-width: 960px)").matches) {
      document.getElementById("adj-decision")?.scrollIntoView({ behavior: "smooth", block: "start" });
    }
  }, [selected]);

  const onSaved = (a: Adjudication) => {
    setSaved(`${a.endpoint_label ?? a.endpoint_code} for ${a.study_subject_code ?? "the subject"}: ${label(ADJ_STATUS, a.adjudication_status).toLowerCase()}.`);
    setSelected(null);
    if (item) router.replace("/adjudication");
    void load();
  };

  if (!can(role, "adjudication.read")) return <ErrorBanner message="Your role does not include event adjudication." />;
  return (
    <>
      <div className="page-head">
        <div>
          <h1>Adjudication</h1>
          <p>Registry outcomes waiting for a decision. Subjects are shown by study code.</p>
        </div>
      </div>
      {error && <div style={{ marginBottom: 16 }}><ErrorBanner message={error} /></div>}
      {saved && <div className="banner banner-info" role="status" style={{ marginBottom: 16 }}>Saved: {saved}</div>}
      <div className="row adj-filters">
        <Field label="Registry protocol" htmlFor="adj-protocol" className="adj-protocol">
          <select id="adj-protocol" className="input" value={protocolId} onChange={(e) => { setProtocolId(e.target.value); setSelected(null); }}>
            {protocols.map((p) => <option key={p.protocol_id} value={p.protocol_id}>{p.label}</option>)}
          </select>
        </Field>
        <div className="segmented" role="group" aria-label="Queue">
          {QUEUE_STATUSES.map((s) => (
            <button key={s} type="button" aria-pressed={status === s} onClick={() => { setStatus(s); setSelected(null); }}>
              {label(ADJ_STATUS, s)}
            </button>
          ))}
        </div>
      </div>
      <div className="adj-layout">
        <Card flush>
          {items === null ? <Loading /> : items.length === 0 ? (
            <div className="empty">Nothing here.</div>
          ) : (
            <ul className="plain adj-list">
              {items.map((a) => (
                <li key={a.adjudication_id} aria-current={selected?.adjudication_id === a.adjudication_id || undefined}>
                  <button type="button" className="adj-item" onClick={() => setSelected(a)}>
                    <span>
                      <strong>{a.endpoint_label ?? a.endpoint_code}</strong>
                      <br />
                      <span className="small muted">
                        <span className="mono">{a.study_subject_code ?? "—"}</span> · {a.centre_code} · {label(EVENT_TYPES, a.event_type)} ·{" "}
                        {eventDate(a.event_date, a.event.event_date_precision)}{a.event_day != null ? ` (day ${a.event_day})` : ""}
                      </span>
                    </span>
                    {a.classification && <span className="badge">{a.classification_system} {a.classification}</span>}
                  </button>
                </li>
              ))}
            </ul>
          )}
          {cursor && <div className="card-body"><button type="button" className="btn btn-sm" onClick={() => void load(cursor)}>Show more</button></div>}
        </Card>
        <div id="adj-decision">
          {selected ? (
            <Decision key={`${selected.adjudication_id}-${selected.row_version}`} a={selected} classifications={classifications} onSaved={onSaved} />
          ) : (
            <Card><div className="small muted">Choose an outcome from the list to review it.</div></Card>
          )}
        </div>
      </div>
    </>
  );
}

export default function AdjudicationPage() {
  return (
    <Suspense fallback={<Loading />}>
      <Queue />
    </Suspense>
  );
}
