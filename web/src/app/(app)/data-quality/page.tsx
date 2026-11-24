"use client";
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { Card, ErrorBanner, Field, Loading } from "@/components/ui";
import { ApiError } from "@/lib/api";
import { formatDate } from "@/lib/format";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import type { MissingDataReport, Protocol } from "@/lib/types";
import { useProtocols } from "@/lib/useProtocols";

export default function MissingDataPage() {
  const { api, selection } = useSession();
  const { protocols, protocolId, setProtocolId, error: pError } = useProtocols();
  const [protocol, setProtocol] = useState<Protocol | null>(null);
  const [visit, setVisit] = useState("");
  const [report, setReport] = useState<MissingDataReport | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!protocolId) return;
    setVisit("");
    api<Protocol>(`/protocols/${protocolId}`).then((r) => setProtocol(r.data)).catch(() => setProtocol(null));
  }, [api, protocolId]);

  const load = useCallback(async () => {
    if (!protocolId) return;
    setReport(null);
    setError(null);
    try {
      setReport((await api<MissingDataReport>(`/protocols/${protocolId}/missing-data`, { query: { visit_code: visit || undefined } })).data);
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not load the report");
    }
  }, [api, protocolId, visit]);
  useEffect(() => { void load(); }, [load]);

  if (!can(selection?.role, "report.missing_data")) return <ErrorBanner message="Your role does not include data-quality reports." />;
  const visitLabel = (code: string) => protocol?.visits.find((v) => v.visit_code === code)?.visit_label ?? code;
  const t = report?.totals;
  return (
    <>
      <div className="page-head">
        <div>
          <h1>Missing data</h1>
          <p>Required registry values still empty in visits at this centre. Missed visits are not counted.</p>
        </div>
      </div>
      {(error || pError) && <div style={{ marginBottom: 16 }}><ErrorBanner message={(error || pError)!} /></div>}
      <div className="row report-filters">
        <Field label="Registry protocol" htmlFor="md-protocol" className="report-protocol">
          <select id="md-protocol" className="input" value={protocolId} onChange={(e) => setProtocolId(e.target.value)}>
            {(protocols ?? []).map((p) => <option key={p.protocol_id} value={p.protocol_id}>{p.label}</option>)}
          </select>
        </Field>
        <Field label="Visit" htmlFor="md-visit" className="report-visit">
          <select id="md-visit" className="input" value={visit} onChange={(e) => setVisit(e.target.value)}>
            <option value="">All visits</option>
            {(protocol?.visits ?? []).map((v) => <option key={v.visit_code} value={v.visit_code}>{v.visit_label}</option>)}
          </select>
        </Field>
      </div>
      {!report || !t ? (!error && <Loading />) : (
        <div className="stack">
          <div className="stat-row" aria-label="Totals">
            <div className="stat"><span className="stat-value">{t.completeness_pct == null ? "—" : `${t.completeness_pct}%`}</span><span className="stat-label">required values filled</span></div>
            <div className="stat"><span className="stat-value">{t.missing}</span><span className="stat-label">values missing</span></div>
            <div className="stat"><span className="stat-value">{report.by_assessment.length}</span><span className="stat-label">visits with gaps, of {t.assessments}</span></div>
          </div>
          <div className="grid-2">
            <Card title="Visits to complete" flush>
              {report.by_assessment.length === 0 ? <div className="empty">Every visit has its required values.</div> : (
                <ul className="plain">
                  {report.by_assessment.map((a) => (
                    <li key={a.assessment_id}>
                      <span>
                        <Link href={`/patients/${a.patient_id}/registries/${a.enrolment_id}/assessments/${a.assessment_id}`}>
                          <span className="mono">{a.local_patient_code ?? "—"}</span> · {visitLabel(a.visit_code)}
                        </Link>
                        <br /><span className="small muted">{formatDate(a.assessment_date)}{a.completion_status !== "partial" ? ` · ${a.completion_status.replace(/_/g, " ")}` : ""}</span>
                      </span>
                      <span className="badge badge-warn">{a.missing} of {a.mandatory_values} missing</span>
                    </li>
                  ))}
                </ul>
              )}
            </Card>
            <Card title="Most often missing" flush>
              {report.items.length === 0 ? <div className="empty">Nothing missing.</div> : (
                <ul className="plain">
                  {[...report.items].sort((a, b) => b.missing - a.missing).map((v) => (
                    <li key={`${v.visit_code}-${v.variable_code}`}>
                      <span>
                        {v.variable_label}
                        <br /><span className="small muted">{visitLabel(v.visit_code)}{v.queried ? ` · ${v.queried} queried` : ""}
                          {v.recorded_as_not_available ? ` · ${v.recorded_as_not_available} recorded as not available` : ""}</span>
                      </span>
                      <span className="small">{v.missing} of {v.assessments_due}</span>
                    </li>
                  ))}
                </ul>
              )}
            </Card>
          </div>
        </div>
      )}
    </>
  );
}
