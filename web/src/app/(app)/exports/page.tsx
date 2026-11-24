"use client";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Card, ErrorBanner, Field, Loading } from "@/components/ui";
import { ApiError, apiPathOf, newIdempotencyKey } from "@/lib/api";
import {
  byCategory, DEIDENTIFICATION, ENROLMENT_STATUSES, EXPORT_STATUS, exportBody, FORMATS, newExport, saveBlob, validateExport,
  type ExportDraft,
} from "@/lib/exports";
import { formatDateTime } from "@/lib/format";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import type { DictionaryItem, ExportJob, Protocol } from "@/lib/types";
import { useProtocols, type ProtocolChoice } from "@/lib/useProtocols";

function Chips({ label, options, value, onChange }: { label: string; options: [string, string][]; value: string[]; onChange: (v: string[]) => void }) {
  return (
    <div className="chips" role="group" aria-label={label}>
      {options.map(([c, l]) => {
        const on = value.includes(c);
        return (
          <button key={c} type="button" className="chip" aria-pressed={on} onClick={() => onChange(on ? value.filter((x) => x !== c) : [...value, c])}>{l}</button>
        );
      })}
    </div>
  );
}

function RequestForm({ protocols, initialProtocol, onDone, onCancel }: {
  protocols: ProtocolChoice[]; initialProtocol: string; onDone: (j: ExportJob) => void; onCancel: () => void;
}) {
  const { api } = useSession();
  const [d, setD] = useState<ExportDraft>(newExport(initialProtocol));
  const [protocol, setProtocol] = useState<Protocol | null>(null);
  const [dict, setDict] = useState<DictionaryItem[] | null>(null);
  const [search, setSearch] = useState("");
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const key = useRef<string | null>(null);
  const up = <K extends keyof ExportDraft>(k: K) => (v: ExportDraft[K]) => setD((x) => ({ ...x, [k]: v }));

  useEffect(() => {
    if (!d.protocol_id) return;
    setDict(null);
    api<Protocol>(`/protocols/${d.protocol_id}`).then((r) => setProtocol(r.data)).catch(() => setProtocol(null));
    api<{ items: DictionaryItem[] }>(`/protocols/${d.protocol_id}/data-dictionary`).then((r) => setDict(r.data.items))
      .catch((e) => setError(e instanceof ApiError ? e.userMessage : "Could not load the data dictionary"));
  }, [api, d.protocol_id]);

  const groups = useMemo(() => {
    const q = search.trim().toLowerCase();
    const items = (dict ?? []).filter((i) => !q || i.variable_label.toLowerCase().includes(q) || i.variable_code.includes(q));
    return byCategory(items);
  }, [dict, search]);

  const toggleAll = (codes: string[], on: boolean) =>
    up("variable_codes")(on ? [...new Set([...d.variable_codes, ...codes])] : d.variable_codes.filter((c) => !codes.includes(c)));

  const submit = async () => {
    const errs = validateExport(d);
    setErrors(errs);
    if (Object.keys(errs).length) { setError("Some answers need attention."); return; }
    setBusy(true);
    setError(null);
    key.current ??= newIdempotencyKey();
    try {
      const r = await api<ExportJob>("/exports", { method: "POST", body: exportBody(d), idempotencyKey: key.current });
      onDone(r.data);
    } catch (e) {
      key.current = null;
      setError(e instanceof ApiError ? e.userMessage : "Could not send the request");
      setBusy(false);
    }
  };

  return (
    <Card title="Request an export">
      <div className="stack">
        {error && <ErrorBanner message={error} />}
        <div className="form-grid">
          <Field label="Registry protocol" htmlFor="ex-protocol" required error={errors.protocol_id} className="span-3">
            <select id="ex-protocol" className="input" value={d.protocol_id}
              onChange={(e) => setD({ ...d, protocol_id: e.target.value, variable_codes: [], visit_codes: [] })}>
              {protocols.map((p) => <option key={p.protocol_id} value={p.protocol_id}>{p.label}</option>)}
            </select>
          </Field>
          <Field label="File" htmlFor="ex-format" className="span-3">
            <select id="ex-format" className="input" value={d.file_format} onChange={(e) => up("file_format")(e.target.value as ExportDraft["file_format"])}>
              {FORMATS.map(([c, l]) => <option key={c} value={c}>{l}</option>)}
            </select>
          </Field>
          <Field label="Purpose" htmlFor="ex-purpose" required error={errors.purpose} className="span-6"
            hint="The analysis this is for, as the approving PI and the audit trail will read it">
            <textarea id="ex-purpose" className="input" rows={2} value={d.purpose} onChange={(e) => up("purpose")(e.target.value)} />
          </Field>
        </div>
        <fieldset className="plain-fieldset">
          <legend className="label">De-identification</legend>
          <div className="stack" style={{ gap: 8 }}>
            {DEIDENTIFICATION.map(([c, l, help]) => (
              <label key={c} className="radio-card">
                <input type="radio" name="deid" value={c} checked={d.deidentification === c} onChange={() => up("deidentification")(c)} />
                <span><strong>{l}</strong><br /><span className="small muted">{help}</span></span>
              </label>
            ))}
          </div>
        </fieldset>
        <div className="form-grid">
          <div className="field span-6">
            <span className="label">Visits</span>
            <Chips label="Visits" options={(protocol?.visits ?? []).map((v) => [v.visit_code, v.visit_label])} value={d.visit_codes} onChange={up("visit_codes")} />
            <span className="hint">None chosen means every visit.</span>
          </div>
          <div className="field span-6">
            <span className="label">Participants</span>
            <Chips label="Participants" options={ENROLMENT_STATUSES} value={d.enrolment_status} onChange={up("enrolment_status")} />
            <span className="hint">None chosen means everyone enrolled.</span>
          </div>
          <Field label="Enrolled from (year)" htmlFor="ex-from" error={errors.index_year_from} className="span-2">
            <input id="ex-from" className="input" inputMode="numeric" value={d.index_year_from} onChange={(e) => up("index_year_from")(e.target.value)} />
          </Field>
          <Field label="Enrolled to (year)" htmlFor="ex-to" error={errors.index_year_to} className="span-2">
            <input id="ex-to" className="input" inputMode="numeric" value={d.index_year_to} onChange={(e) => up("index_year_to")(e.target.value)} />
          </Field>
          <label className="check span-2 align-end">
            <input type="checkbox" checked={d.include_data_dictionary} onChange={(e) => up("include_data_dictionary")(e.target.checked)} /> Include the data dictionary
          </label>
        </div>
        <div className="field">
          <span className="label">Variables<span className="req" aria-hidden>*</span> <span className="muted small">({d.variable_codes.length} chosen)</span></span>
          <input className="input" placeholder="Search variables" aria-label="Search variables" value={search} onChange={(e) => setSearch(e.target.value)} />
          {errors.variable_codes && <span className="err">{errors.variable_codes}</span>}
          {dict === null ? <Loading /> : (
            <div className="var-picker">
              {groups.map(([cat, items]) => {
                const codes = items.map((i) => i.variable_code);
                const all = codes.every((c) => d.variable_codes.includes(c));
                return (
                  <details key={cat} className="var-group" open={!!search}>
                    <summary>
                      <span>{cat} <span className="small muted">{codes.filter((c) => d.variable_codes.includes(c)).length}/{codes.length}</span></span>
                      <button type="button" className="link-button small" onClick={(e) => { e.preventDefault(); toggleAll(codes, !all); }}>
                        {all ? "Clear" : "Choose all"}
                      </button>
                    </summary>
                    <div className="var-options">
                      {items.map((i) => (
                        <label key={i.variable_code} className="check">
                          <input type="checkbox" checked={d.variable_codes.includes(i.variable_code)}
                            onChange={(e) => toggleAll([i.variable_code], e.target.checked)} />
                          {" "}{i.variable_label}
                        </label>
                      ))}
                    </div>
                  </details>
                );
              })}
            </div>
          )}
        </div>
        <div className="row" style={{ justifyContent: "flex-end" }}>
          <button type="button" className="btn" onClick={onCancel}>Cancel</button>
          <button type="button" className="btn btn-primary" disabled={busy} onClick={() => void submit()}>{busy ? "Sending…" : "Send for approval"}</button>
        </div>
      </div>
    </Card>
  );
}

function Job({ j, protocolName, onChanged }: { j: ExportJob; protocolName: string; onChanged: (j: ExportJob) => void }) {
  const { api, download, me, selection, membership } = useSession();
  const tz = membership?.timezone;
  const mine = me?.user_id === j.requested_by;
  const [deciding, setDeciding] = useState(false);
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [status, tone] = EXPORT_STATUS[j.status];

  const decide = async (decision: "approved" | "rejected") => {
    if (decision === "rejected" && note.trim().length < 3) { setError("Say why it is rejected."); return; }
    setBusy(true);
    setError(null);
    try {
      const r = await api<ExportJob>(`/exports/${j.export_id}/decision`, {
        method: "POST", ifMatch: `"${j.row_version}"`, body: { decision, note: note.trim() || null },
      });
      setDeciding(false);
      onChanged(r.data);
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not record the decision");
    } finally {
      setBusy(false);
    }
  };

  const fetchFile = async () => {
    setBusy(true);
    setError(null);
    try {
      // a fresh signed link each time; links last 15 minutes
      const fresh = (await api<ExportJob>(`/exports/${j.export_id}`)).data;
      if (!fresh.download_url) { onChanged(fresh); throw new ApiError(409, "CONFLICT", "This export is no longer available"); }
      const f = await download(apiPathOf(fresh.download_url));
      saveBlob(f.blob, f.filename ?? `export-${j.export_id.slice(0, 8)}`);
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not download the file");
    } finally {
      setBusy(false);
    }
  };

  return (
    <li className="export-job">
      <div className="row" style={{ justifyContent: "space-between", alignItems: "flex-start", flexWrap: "wrap" }}>
        <span style={{ minWidth: 0, flex: "1 1 260px" }}>
          <strong>{protocolName}</strong> · {j.variable_codes.length} variable{j.variable_codes.length === 1 ? "" : "s"} ·{" "}
          {DEIDENTIFICATION.find(([c]) => c === j.deidentification)?.[1]} · {FORMATS.find(([c]) => c === j.file_format)?.[1]}
          <br />
          <span className="small">{j.purpose}</span>
          <br />
          <span className="small muted">
            Requested {formatDateTime(j.requested_at, tz)}{mine ? " by you" : ""}
            {j.approved_at ? ` · decided ${formatDateTime(j.approved_at, tz)}` : ""}
            {j.row_count != null ? ` · ${j.row_count} row${j.row_count === 1 ? "" : "s"}` : ""}
            {j.status === "completed" && j.expires_at ? ` · available until ${formatDateTime(j.expires_at, tz)}` : ""}
          </span>
          {j.decision_note && <><br /><span className="small">Note: {j.decision_note}</span></>}
          {j.failure_reason && <><br /><span className="small err">{j.failure_reason}</span></>}
          {j.file_sha256 && <><br /><span className="small muted mono" title="SHA-256 of the file">SHA-256 {j.file_sha256.slice(0, 16)}…</span></>}
        </span>
        <span className="row" style={{ gap: 8 }}>
          <span className={`badge ${tone}`}>{status}</span>
          {j.status === "completed" && mine && (
            <button type="button" className="btn btn-sm btn-primary" disabled={busy} onClick={() => void fetchFile()}>Download</button>
          )}
          {j.status === "requested" && !mine && can(selection?.role, "export.decide") && !deciding && (
            <button type="button" className="btn btn-sm" onClick={() => setDeciding(true)}>Review</button>
          )}
        </span>
      </div>
      {j.status === "requested" && mine && <div className="small muted">Another principal investigator must approve it.</div>}
      {j.status === "completed" && !mine && <div className="small muted">Only the person who asked for it can download the file.</div>}
      {error && <ErrorBanner message={error} />}
      {deciding && (
        <div className="subpanel stack" style={{ gap: 10 }}>
          <div className="small">
            <strong>Variables:</strong> {j.variable_codes.join(", ")}
            <br /><strong>Visits:</strong> {j.visit_codes?.join(", ") ?? "all"}
            <br /><strong>Participants:</strong> {j.cohort_filter.enrolment_status?.join(", ") ?? "everyone enrolled"}
            {j.cohort_filter.index_year_from || j.cohort_filter.index_year_to
              ? ` · enrolled ${j.cohort_filter.index_year_from ?? "…"} to ${j.cohort_filter.index_year_to ?? "…"}` : ""}
          </div>
          <Field label="Note for the requester" htmlFor={`note-${j.export_id}`} hint="Needed when you reject">
            <input id={`note-${j.export_id}`} className="input" value={note} onChange={(e) => setNote(e.target.value)} />
          </Field>
          <div className="row" style={{ justifyContent: "flex-end", flexWrap: "wrap" }}>
            <button type="button" className="btn btn-sm" onClick={() => setDeciding(false)}>Cancel</button>
            <button type="button" className="btn btn-sm btn-danger" disabled={busy} onClick={() => void decide("rejected")}>Reject</button>
            <button type="button" className="btn btn-sm btn-primary" disabled={busy} onClick={() => void decide("approved")}>Approve</button>
          </div>
        </div>
      )}
    </li>
  );
}

export default function ExportsPage() {
  const { api, selection } = useSession();
  const { protocols, protocolId } = useProtocols();
  const [jobs, setJobs] = useState<ExportJob[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [requesting, setRequesting] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setJobs((await api<{ items: ExportJob[] }>("/exports", { query: { limit: 100 } })).data.items);
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not load exports");
    }
  }, [api]);
  useEffect(() => { void load(); }, [load]);

  // While a file is being prepared, check again every few seconds.
  const preparing = jobs?.some((j) => j.status === "approved" || j.status === "running");
  useEffect(() => {
    if (!preparing) return;
    const t = setInterval(() => void load(), 3000);
    return () => clearInterval(t);
  }, [preparing, load]);

  if (!can(selection?.role, "export.request")) return <ErrorBanner message="Exports are for research coordinators and principal investigators." />;
  const name = (id: string) => protocols?.find((p) => p.protocol_id === id)?.label ?? "Protocol";
  const waiting = jobs?.filter((j) => j.status === "requested") ?? [];
  const rest = jobs?.filter((j) => j.status !== "requested") ?? [];
  const replace = (j: ExportJob) => setJobs((cur) => cur?.map((x) => (x.export_id === j.export_id ? j : x)) ?? null);

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Exports</h1>
          <p>De-identified registry data for analysis. Every export needs a second person&apos;s approval, and every download is logged.</p>
        </div>
        {!requesting && protocols && (
          <button type="button" className="btn btn-primary" onClick={() => { setRequesting(true); setNotice(null); }}>Request export</button>
        )}
      </div>
      {error && <div style={{ marginBottom: 16 }}><ErrorBanner message={error} /></div>}
      {notice && <div className="banner banner-info" role="status" style={{ marginBottom: 16 }}>{notice}</div>}
      <div className="stack">
        {requesting && protocols && (
          <RequestForm protocols={protocols} initialProtocol={protocolId} onCancel={() => setRequesting(false)}
            onDone={(j) => { setRequesting(false); setNotice("Sent for approval."); setJobs((cur) => [j, ...(cur ?? [])]); }} />
        )}
        {jobs === null ? <Loading /> : (
          <>
            <Card title={`Waiting for approval (${waiting.length})`} flush>
              {waiting.length === 0 ? <div className="empty">Nothing waiting.</div> : (
                <ul className="plain export-list">{waiting.map((j) => <Job key={j.export_id} j={j} protocolName={name(j.protocol_id)} onChanged={(x) => { replace(x); void load(); }} />)}</ul>
              )}
            </Card>
            <Card title="Earlier requests" flush>
              {rest.length === 0 ? <div className="empty">No exports yet.</div> : (
                <ul className="plain export-list">{rest.map((j) => <Job key={j.export_id} j={j} protocolName={name(j.protocol_id)} onChanged={replace} />)}</ul>
              )}
            </Card>
          </>
        )}
      </div>
    </>
  );
}
