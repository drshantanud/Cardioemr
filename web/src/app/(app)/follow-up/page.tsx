"use client";
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { Card, ErrorBanner, Field, Loading } from "@/components/ui";
import { ApiError } from "@/lib/api";
import { formatDate, formatMobile } from "@/lib/format";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import { closesText } from "@/lib/reports";
import type { FollowUpItem, FollowUpReport } from "@/lib/types";
import { useProtocols } from "@/lib/useProtocols";

const HORIZONS = [7, 14, 30, 60];

function Group({ title, tone, items, today }: { title: string; tone: string; items: FollowUpItem[]; today: string }) {
  return (
    <Card title={<>{title} <span className={`badge ${tone}`}>{items.length}</span></>} flush>
      {items.length === 0 ? <div className="empty">None.</div> : (
        <ul className="plain">
          {items.map((i) => (
            <li key={`${i.enrolment_id}-${i.visit_code}-${i.occurrence}`} style={{ flexWrap: "wrap" }}>
              <span style={{ minWidth: 0, flex: "1 1 240px" }}>
                <Link href={`/patients/${i.patient_id}/registries/${i.enrolment_id}`}>{i.patient_name}</Link>
                <span className="small muted mono"> {i.local_patient_code}</span>
                <br />
                <span className="small">
                  {i.visit_label ?? i.visit_code}{i.occurrence > 1 ? ` (${i.occurrence})` : ""} · {formatDate(i.window_opens)} to {formatDate(i.window_closes)}
                </span>
                <br />
                <span className={`small ${i.status === "overdue" ? "err" : "muted"}`}>{closesText(i, today)}</span>
              </span>
              {i.mobile && <a className="btn btn-sm" href={`tel:${i.mobile}`}>Call {formatMobile(i.mobile)}</a>}
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}

export default function FollowUpPage() {
  const { api, selection } = useSession();
  const { protocols, protocolId, setProtocolId, error: pError } = useProtocols();
  const [within, setWithin] = useState(14);
  const [report, setReport] = useState<FollowUpReport | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!protocolId) return;
    setReport(null);
    setError(null);
    try {
      setReport((await api<FollowUpReport>(`/protocols/${protocolId}/follow-up-due`, { query: { within_days: within } })).data);
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not load the report");
    }
  }, [api, protocolId, within]);
  useEffect(() => { void load(); }, [load]);

  if (!can(selection?.role, "report.follow_up")) return <ErrorBanner message="Your role does not include follow-up reports." />;
  const by = (s: FollowUpItem["status"]) => report?.items.filter((i) => i.status === s) ?? [];
  return (
    <>
      <div className="page-head">
        <div>
          <h1>Follow-up</h1>
          <p>Registry visits to arrange at this centre{report ? `, as of ${formatDate(report.as_of)}` : ""}. Patients who have died are left out.</p>
        </div>
      </div>
      {(error || pError) && <div style={{ marginBottom: 16 }}><ErrorBanner message={(error || pError)!} /></div>}
      <div className="row report-filters">
        <Field label="Registry protocol" htmlFor="fu-protocol" className="report-protocol">
          <select id="fu-protocol" className="input" value={protocolId} onChange={(e) => setProtocolId(e.target.value)}>
            {(protocols ?? []).map((p) => <option key={p.protocol_id} value={p.protocol_id}>{p.label}</option>)}
          </select>
        </Field>
        <div className="field">
          <span className="label">Windows opening within</span>
          <div className="segmented" role="group" aria-label="Windows opening within">
            {HORIZONS.map((d) => (
              <button key={d} type="button" aria-pressed={within === d} onClick={() => setWithin(d)}>{d} days</button>
            ))}
          </div>
        </div>
      </div>
      {!report ? (!error && <Loading />) : (
        <div className="stack">
          <Group title="Overdue" tone="badge-danger" items={by("overdue")} today={report.as_of} />
          <Group title="Due now" tone="badge-warn" items={by("due")} today={report.as_of} />
          <Group title={`Opening in the next ${report.within_days} days`} tone="badge-info" items={by("not_due")} today={report.as_of} />
        </div>
      )}
    </>
  );
}
