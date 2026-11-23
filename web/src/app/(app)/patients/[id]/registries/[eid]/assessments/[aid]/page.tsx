"use client";
import Link from "next/link";
import { useParams, useSearchParams } from "next/navigation";
import { Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { GdmtPanel, LipidTargetsPanel } from "@/components/RegistryPanels";
import { ErrorBanner, Loading, StatusBadge } from "@/components/ui";
import { ApiError } from "@/lib/api";
import { formatDate } from "@/lib/format";
import { humanCode, optionLabel, parseDraft, REGISTRY_NAMES, sameValue, SOURCE_LABEL, VALUE_STATUS_LABEL, valueText } from "@/lib/registry";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import type { Assessment, Enrolment, PatientOverview, PrefillResult, ValueStatus, VariableDefinition, VariableValue } from "@/lib/types";

interface Draft { status: ValueStatus; raw: string | string[] | boolean | null; unit: string | null }
type Row = Assessment["variables"][number];

function draftOf(d: VariableDefinition, v: VariableValue | null): Draft {
  if (!v) return { status: "present", raw: d.data_type === "multi_coded" ? [] : d.data_type === "boolean" ? null : "", unit: d.unit };
  if (v.value_status !== "present") return { status: v.value_status, raw: d.data_type === "multi_coded" ? [] : "", unit: d.unit };
  const raw = v.value === null ? "" : d.data_type === "multi_coded" ? (v.value as string[])
    : d.data_type === "boolean" ? (v.value as boolean) : String(v.value);
  return { status: "present", raw, unit: d.unit };
}

/** What would be sent for this row, or null when nothing changed. */
function change(row: Row, draft: Draft): { body: Record<string, unknown> } | { error: string } | null {
  const { definition: d, value: v } = row;
  if (draft.status !== "present") {
    if (v && v.value_status === draft.status) return null;
    return { body: { variable_code: d.variable_code, value_status: draft.status, row_version: v?.row_version } };
  }
  const parsed = parseDraft(d, draft.raw);
  if (parsed === undefined) return null;          // blank: nothing to save (clearing needs a status)
  if ("error" in parsed) return { error: parsed.error };
  const unitChanged = draft.unit && draft.unit !== d.unit;
  if (v && v.value_status === "present" && !unitChanged && sameValue(v.value, parsed.value)) return null;
  return { body: { variable_code: d.variable_code, value_status: "present", value: parsed.value,
    unit: unitChanged ? draft.unit : undefined, row_version: v?.row_version } };
}

function Input({ d, draft, set, disabled }: { d: VariableDefinition; draft: Draft; set: (x: Draft) => void; disabled: boolean }) {
  const id = `var-${d.variable_code}`;
  const raw = draft.raw;
  if (draft.status !== "present") return <span className="muted small">{VALUE_STATUS_LABEL[draft.status]}</span>;
  switch (d.data_type) {
    case "boolean":
      return (
        <span className="segmented" role="group" aria-label={d.variable_label}>
          {[true, false].map((b) => (
            <button key={String(b)} type="button" aria-pressed={raw === b} disabled={disabled} onClick={() => set({ ...draft, raw: b })}>
              {b ? "Yes" : "No"}
            </button>
          ))}
        </span>
      );
    case "coded":
      return (
        <select id={id} className="input" value={String(raw ?? "")} disabled={disabled} onChange={(e) => set({ ...draft, raw: e.target.value })}>
          <option value="">—</option>
          {d.allowed_values?.map((a) => <option key={a.code} value={a.code}>{optionLabel(a)}</option>)}
        </select>
      );
    case "multi_coded": {
      const list = (raw as string[]) ?? [];
      return (
        <div className="chips" role="group" aria-label={d.variable_label}>
          {d.allowed_values?.map((a) => {
            const on = list.includes(a.code);
            return (
              <button key={a.code} type="button" className="chip" aria-pressed={on} disabled={disabled}
                onClick={() => set({ ...draft, raw: on ? list.filter((x) => x !== a.code) : [...list, a.code] })}>
                {optionLabel(a)}
              </button>
            );
          })}
        </div>
      );
    }
    case "date":
      return <input id={id} type="date" className="input" value={String(raw ?? "")} disabled={disabled} onChange={(e) => set({ ...draft, raw: e.target.value })} />;
    case "numeric":
    case "integer": {
      const units = d.accepted_units?.length ? d.accepted_units : d.unit ? [d.unit] : [];
      return (
        <span className="row" style={{ gap: 6, flexWrap: "nowrap" }}>
          <input id={id} className="input" inputMode="decimal" value={String(raw ?? "")} disabled={disabled}
            onChange={(e) => set({ ...draft, raw: e.target.value })} style={{ maxWidth: 140 }} />
          {units.length > 1 ? (
            <select className="input" aria-label={`${d.variable_label} unit`} value={draft.unit ?? d.unit ?? ""} disabled={disabled}
              onChange={(e) => set({ ...draft, unit: e.target.value })} style={{ width: "auto" }}>
              {units.map((u) => <option key={u}>{u}</option>)}
            </select>
          ) : d.unit ? <span className="small muted">{d.unit}</span> : null}
        </span>
      );
    }
    default:
      return <input id={id} className="input" value={String(raw ?? "")} disabled={disabled} onChange={(e) => set({ ...draft, raw: e.target.value })} />;
  }
}

function VariableRow({ row, draft, set, locked, error, onVerify }: {
  row: Row; draft: Draft; set: (x: Draft) => void; locked: boolean; error?: string;
  onVerify: (code: string, status: "verified" | "queried", query?: string) => void;
}) {
  const { definition: d, value: v } = row;
  const missing = d.requirement === "mandatory" && !v;
  const [asking, setAsking] = useState(false);
  const [query, setQuery] = useState("");
  return (
    <li className="var-row" data-missing={missing || undefined} id={`row-${d.variable_code}`}>
      <div className="var-label">
        <label htmlFor={`var-${d.variable_code}`}>
          {d.variable_label}{d.requirement === "mandatory" && <span className="req" aria-hidden>*</span>}
        </label>
        {missing && <span className="missing-tag">required</span>}
        <div className="small muted">
          {d.condition_text ? `${d.condition_text}` : d.requirement === "conditional" ? "When it applies" : ""}
        </div>
      </div>
      <div className="var-input">
        {locked ? <span>{valueText(d, v) || <span className="muted">—</span>}</span> : <Input d={d} draft={draft} set={set} disabled={locked} />}
        {error && <div className="err small">{error}</div>}
      </div>
      <div className="var-meta">
        {v && (
          <>
            <span className={`badge ${v.source_kind === "entered" ? "" : "badge-info"}`} title={v.source_table ?? undefined}>
              {SOURCE_LABEL[v.source_kind] ?? v.source_kind}
            </span>
            <span className={`badge ${v.verification_status === "verified" ? "badge-ok" : v.verification_status === "queried" ? "badge-danger" : "badge-warn"}`}>
              {v.verification_status}
            </span>
            {!locked && v.verification_status !== "verified" && (
              <button type="button" className="link-button small" onClick={() => onVerify(d.variable_code, "verified")}>Verify</button>
            )}
            {!locked && v.verification_status === "unverified" && (
              <button type="button" className="link-button small" onClick={() => setAsking(true)}>Query</button>
            )}
          </>
        )}
        {!locked && (
          <select className="input status-select" aria-label={`${d.variable_label} status`} value={draft.status}
            onChange={(e) => set({ ...draft, status: e.target.value as ValueStatus })}>
            {Object.entries(VALUE_STATUS_LABEL).map(([c, l]) => <option key={c} value={c}>{l}</option>)}
          </select>
        )}
      </div>
      {asking && (
        <div className="var-query row">
          <input className="input" aria-label={`What needs checking in ${d.variable_label}`} value={query} placeholder="What needs checking?"
            onChange={(e) => setQuery(e.target.value)} style={{ flex: 1, minWidth: 180 }} />
          <button type="button" className="btn btn-sm" onClick={() => setAsking(false)}>Cancel</button>
          <button type="button" className="btn btn-sm btn-primary" disabled={query.trim().length < 3}
            onClick={() => { onVerify(d.variable_code, "queried", query.trim()); setAsking(false); setQuery(""); }}>Send query</button>
        </div>
      )}
    </li>
  );
}

function AssessmentScreen() {
  const { id, eid, aid } = useParams<{ id: string; eid: string; aid: string }>();
  const params = useSearchParams();
  const { api, selection } = useSession();
  const role = selection?.role;
  const [a, setA] = useState<Assessment | null>(null);
  const [enrolment, setEnrolment] = useState<Enrolment | null>(null);
  const [patient, setPatient] = useState<PatientOverview | null>(null);
  const [drafts, setDrafts] = useState<Record<string, Draft>>({});
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({});
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<ApiError | null>(null);
  const [notice, setNotice] = useState<string | null>(params.get("prefilled") ? "Values found in the chart are filled in and marked unverified. Check them against the source." : null);
  const [prefill, setPrefill] = useState<PrefillResult | null>(null);
  const [busy, setBusy] = useState(false);
  const [missedReason, setMissedReason] = useState("");
  const [showMissed, setShowMissed] = useState(false);
  const [unlocking, setUnlocking] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const [unlockReason, setUnlockReason] = useState("");

  const load = useCallback(async () => {
    const r = await api<Assessment>(`/assessments/${aid}`);
    setA(r.data);
    setRefresh((n) => n + 1);
    setDrafts(Object.fromEntries(r.data.variables.map((row) => [row.definition.variable_code, draftOf(row.definition, row.value)])));
    setFieldErrors({});
    return r.data;
  }, [api, aid]);

  useEffect(() => {
    (async () => {
      try {
        await load();
        const [e, p] = await Promise.all([api<Enrolment>(`/enrolments/${eid}`), api<PatientOverview>(`/patients/${id}`)]);
        setEnrolment(e.data);
        setPatient(p.data);
      } catch (err) {
        setLoadError(err instanceof ApiError ? err : new ApiError(0, "NETWORK", "Could not load the visit"));
      }
    })();
  }, [api, id, eid, load]);

  const rows = useMemo(() => {
    const seen = new Set<string>();
    return (a?.variables ?? []).filter((r) => !seen.has(r.definition.variable_code) && seen.add(r.definition.variable_code));
  }, [a]);
  const groups = useMemo(() => {
    const m = new Map<string, Row[]>();
    for (const r of rows) m.set(r.definition.category, [...(m.get(r.definition.category) ?? []), r]);
    return [...m.entries()];
  }, [rows]);

  const changes = rows.map((r) => [r, drafts[r.definition.variable_code] ? change(r, drafts[r.definition.variable_code]) : null] as const)
    .filter(([, c]) => c !== null);
  const invalid = changes.filter(([, c]) => c && "error" in c);
  const bodies = changes.flatMap(([, c]) => (c && "body" in c ? [c.body] : []));
  const overwriting = changes.some(([r, c]) => r.value && c && "body" in c);
  const locked = !!a?.locked_at;

  const save = async () => {
    if (!bodies.length) return;
    setBusy(true);
    setError(null);
    setFieldErrors({});
    try {
      await api(`/assessments/${aid}/values`, { method: "PUT", body: { values: bodies }, changeReason: overwriting ? reason.trim() : undefined });
      setReason("");
      await load();
      setNotice(`Saved ${bodies.length} value${bodies.length === 1 ? "" : "s"}.`);
    } catch (e) {
      if (e instanceof ApiError && e.errors?.length) {
        setFieldErrors(Object.fromEntries(e.errors.map((x) => [x.variable_code ?? x.field ?? "", x.message ?? x.rule ?? "Not accepted"])));
      }
      setError(e instanceof ApiError ? e.userMessage : "Could not save");
    } finally {
      setBusy(false);
    }
  };

  const runPrefill = async () => {
    setBusy(true);
    setError(null);
    try {
      const r = await api<PrefillResult>(`/assessments/${aid}/prefill`, { method: "POST" });
      setPrefill(r.data);
      await load();
      setNotice(r.data.filled.length ? `Filled ${r.data.filled.length} value${r.data.filled.length === 1 ? "" : "s"} from the chart. Check them against the source.`
        : "Nothing new found in the chart for this visit.");
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not fill from the chart");
    } finally {
      setBusy(false);
    }
  };

  const verify = async (code: string, status: "verified" | "queried", query?: string) => {
    const row = rows.find((r) => r.definition.variable_code === code);
    if (!row?.value) return;
    try {
      await api(`/assessments/${aid}/values/${code}/verification`, {
        method: "PUT", ifMatch: `"${row.value.row_version}"`, body: { verification_status: status, query_text: query },
      });
      await load();
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not update verification");
    }
  };

  const verifyAll = async () => {
    setBusy(true);
    setError(null);
    try {
      for (const r of rows) {
        if (r.value && r.value.verification_status === "unverified") {
          await api(`/assessments/${aid}/values/${r.definition.variable_code}/verification`, {
            method: "PUT", ifMatch: `"${r.value.row_version}"`, body: { verification_status: "verified" },
          });
        }
      }
      await load();
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not verify");
      await load();
    } finally {
      setBusy(false);
    }
  };

  const complete = async (status: "complete" | "missed" | "not_applicable") => {
    if (!a) return;
    setBusy(true);
    setError(null);
    try {
      await api(`/assessments/${aid}/complete`, { method: "POST", ifMatch: `"${a.row_version}"`,
        body: { completion_status: status, missed_reason: status === "complete" ? undefined : missedReason.trim() } });
      setShowMissed(false);
      await load();
      setNotice(status === "complete" ? "Visit marked complete." : "Visit recorded as missed.");
    } catch (e) {
      if (e instanceof ApiError && e.errors?.length) {
        setFieldErrors(Object.fromEntries(e.errors.map((x) => [x.variable_code ?? x.field ?? "", x.message ?? "Required"])));
      }
      setError(e instanceof ApiError ? e.userMessage : "Could not complete the visit");
    } finally {
      setBusy(false);
    }
  };

  const lock = async (on: boolean, why?: string) => {
    if (!a) return;
    setBusy(true);
    setError(null);
    try {
      await api(`/assessments/${aid}/lock`, { method: on ? "POST" : "DELETE", ifMatch: `"${a.row_version}"`, changeReason: why });
      setUnlocking(false);
      setUnlockReason("");
      await load();
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not change the lock");
    } finally {
      setBusy(false);
    }
  };

  if (loadError) return <ErrorBanner message={loadError.status === 404 ? "This visit is not at this centre." : loadError.userMessage} />;
  if (!a || !enrolment || !patient) return <Loading />;
  const unverified = rows.filter((r) => r.value?.verification_status === "unverified").length;
  const notAutomated = prefill?.skipped.filter((s) => s.reason === "not_automated_yet") ?? [];
  const filled = rows.filter((r) => r.value).length;

  return (
    <>
      <div className="breadcrumb">
        <Link href="/patients">Patients</Link> / <Link href={`/patients/${id}`}>{patient.patient.local_patient_code}</Link> /{" "}
        <Link href={`/patients/${id}/registries/${eid}`}>{REGISTRY_NAMES[enrolment.registry_code]} registry</Link> / {a.visit_code}
      </div>
      <section className="card consult-head">
        <div style={{ minWidth: 0 }}>
          <div className="row" style={{ gap: 10 }}>
            <h1>{patient.patient.display_name}</h1>
            <StatusBadge status={a.completion_status} />
            {locked && <span className="badge badge-info">locked</span>}
          </div>
          <div className="small muted">
            {REGISTRY_NAMES[enrolment.registry_code]} · {a.visit_code} ({humanCode(a.assessment_type)}) · {formatDate(a.assessment_date)}
            {a.days_from_index != null ? ` · day ${a.days_from_index}` : ""}
            {a.within_window === false ? " · outside the visit window" : ""}
          </div>
          <div className="small" style={{ marginTop: 4 }}>
            {filled} of {rows.length} filled · <span className={a.mandatory_missing.length ? "text-danger" : ""}>{a.mandatory_missing.length} required missing</span> · {unverified} unverified
          </div>
        </div>
        <div className="row consult-actions">
          {!locked && (
            <>
              <button type="button" className="btn" disabled={busy} onClick={() => void runPrefill()}>Fill from chart</button>
              {unverified > 0 && <button type="button" className="btn" disabled={busy} onClick={() => void verifyAll()}>Verify all ({unverified})</button>}
              <button type="button" className="btn btn-primary" disabled={busy || !bodies.length || invalid.length > 0 || (overwriting && reason.trim().length < 3)}
                onClick={() => void save()}>{bodies.length ? `Save ${bodies.length}` : "Saved"}</button>
            </>
          )}
          {!locked && can(role, "registry.lock") && a.completion_status !== "partial" && (
            <button type="button" className="btn" disabled={busy} onClick={() => void lock(true)}>Lock</button>
          )}
          {locked && can(role, "registry.unlock") && !unlocking && <button type="button" className="btn" onClick={() => setUnlocking(true)}>Unlock</button>}
          {unlocking && (
            <>
              <input className="input" aria-label="Reason for unlocking" placeholder="Reason for unlocking" value={unlockReason}
                onChange={(e) => setUnlockReason(e.target.value)} style={{ width: 220 }} />
              <button type="button" className="btn" onClick={() => setUnlocking(false)}>Cancel</button>
              <button type="button" className="btn btn-primary" disabled={busy || unlockReason.trim().length < 3}
                onClick={() => void lock(false, unlockReason.trim())}>Unlock</button>
            </>
          )}
        </div>
      </section>
      {error && <div style={{ marginBottom: 12 }}><ErrorBanner message={error} /></div>}
      {notice && <div className="banner banner-info" role="status" style={{ marginBottom: 12 }}>{notice}</div>}
      {notAutomated.length > 0 && (
        <div className="banner banner-warn" style={{ marginBottom: 12 }}>
          Not filled automatically yet, enter by hand: {notAutomated.map((s) => rows.find((r) => r.definition.variable_code === s.variable_code)?.definition.variable_label ?? s.variable_code).join(", ")}.
        </div>
      )}
      {!locked && overwriting && (
        <div className="card" style={{ padding: 12, marginBottom: 12 }}>
          <label htmlFor="change-reason" className="small"><strong>Reason for changing saved values</strong></label>
          <input id="change-reason" className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Corrected from the discharge summary" />
        </div>
      )}

      <div className="consult-layout">
        <div className="stack consult-main">
          {groups.map(([category, list]) => (
            <section key={category} className="card">
              <div className="card-head"><h2>{category}</h2>
                <span className="small muted">{list.filter((r) => r.value).length}/{list.length}</span></div>
              <ul className="plain var-list">
                {list.map((r) => (
                  <VariableRow key={r.definition.variable_code} row={r} locked={locked}
                    draft={drafts[r.definition.variable_code]} error={fieldErrors[r.definition.variable_code]}
                    set={(x) => setDrafts({ ...drafts, [r.definition.variable_code]: x })} onVerify={(c, st, q) => void verify(c, st, q)} />
                ))}
              </ul>
            </section>
          ))}
          {!locked && (
            <section className="card">
              <div className="card-head"><h2>Finish the visit</h2></div>
              <div className="card-body stack" style={{ gap: 10 }}>
                {a.mandatory_missing.length > 0 && (
                  <div className="small">
                    Still required:{" "}
                    {a.mandatory_missing.map((c, i) => (
                      <span key={c}>{i > 0 && ", "}<a href={`#row-${c}`}>{rows.find((r) => r.definition.variable_code === c)?.definition.variable_label ?? c}</a></span>
                    ))}. Enter a value or mark why it is missing.
                  </div>
                )}
                <div className="row">
                  <button type="button" className="btn btn-primary" disabled={busy || bodies.length > 0 || a.mandatory_missing.length > 0}
                    title={bodies.length ? "Save your changes first" : undefined} onClick={() => void complete("complete")}>Mark complete</button>
                  {!showMissed ? (
                    <button type="button" className="btn" onClick={() => setShowMissed(true)}>Visit did not happen</button>
                  ) : (
                    <>
                      <input className="input" style={{ flex: 1, minWidth: 200 }} aria-label="Why the visit was missed" value={missedReason}
                        placeholder="Why the visit was missed" onChange={(e) => setMissedReason(e.target.value)} />
                      <button type="button" className="btn btn-danger" disabled={missedReason.trim().length < 3} onClick={() => void complete("missed")}>Record missed</button>
                    </>
                  )}
                </div>
              </div>
            </section>
          )}
        </div>
        <aside className="stack consult-aside-plain">
          {enrolment.registry_code === "HF" && <GdmtPanel assessmentId={aid} locked={locked} refreshKey={refresh} />}
          {enrolment.registry_code === "LIPID" && <LipidTargetsPanel assessmentId={aid} locked={locked} refreshKey={refresh} />}
        </aside>
      </div>
    </>
  );
}

export default function AssessmentPage() {
  return (
    <Suspense fallback={<Loading />}>
      <AssessmentScreen />
    </Suspense>
  );
}
