"use client";
import Link from "next/link";
import { formatDate, humanise } from "@/lib/format";
import { courseLine } from "@/lib/meds";
import type { ClinicalSummary } from "@/lib/types";
import { vitalsLine } from "./VitalsForm";

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="summary-section">
      <h3>{title}</h3>
      {children}
    </section>
  );
}

/** The record beside a new consultation: last visit, medicines, problems and latest results. */
export function ClinicalSummaryPanel({ summary, patientId, currentEncounterId }: {
  summary: ClinicalSummary; patientId: string; currentEncounterId?: string;
}) {
  const last = summary.last_signed_encounter && summary.last_signed_encounter.encounter_id !== currentEncounterId
    ? summary.last_signed_encounter : null;
  const meds = summary.medications.filter((m) => m.status === "active" || m.status === "on_hold");
  return (
    <div className="summary">
      <Section title="Last consultation">
        {last ? (
          <div className="small stack" style={{ gap: 4 }}>
            <div>
              <Link href={`/patients/${patientId}/consultations/${last.encounter_id}`}>
                {formatDate(last.encounter_start)}
              </Link>
              {" · "}{humanise(last.encounter_type)}{last.clinician_name ? ` · ${last.clinician_name}` : ""}
            </div>
            {last.complaints.length > 0 && <div className="muted">{last.complaints.map((c) => c.display_name).join(", ")}</div>}
            {last.clinical_assessment?.nyha_class && <div>NYHA {last.clinical_assessment.nyha_class}</div>}
            {last.assessment && <div><span className="muted">Assessment:</span> {last.assessment}</div>}
            {last.plan && <div><span className="muted">Plan:</span> {last.plan}</div>}
            {last.follow_up_date && <div className="muted">Follow-up was due {formatDate(last.follow_up_date)}</div>}
          </div>
        ) : <div className="small muted">None signed yet.</div>}
      </Section>
      <Section title="Allergies">
        {summary.allergies.length ? (
          <div className="row" style={{ gap: 4 }}>
            {summary.allergies.map((a) => <span key={a.allergy_id} className="badge badge-danger">{a.allergen_text}</span>)}
          </div>
        ) : <div className="small muted">None recorded</div>}
      </Section>
      <Section title="Current medicines">
        {meds.length ? (
          <ul className="summary-list">
            {meds.map((m) => (
              <li key={m.course_id}>
                <strong>{m.generic_name}</strong>{m.status === "on_hold" ? " (held)" : ""}
                <div className="muted">{courseLine(m)}</div>
              </li>
            ))}
          </ul>
        ) : <div className="small muted">None</div>}
      </Section>
      <Section title="Problems">
        {summary.diagnoses.length ? (
          <ul className="summary-list">
            {summary.diagnoses.map((d) => (
              <li key={d.diagnosis_id}>
                {d.diagnosis_text}{d.certainty === "suspected" ? " (suspected)" : ""}
                {d.icd10_code && <span className="muted mono"> {d.icd10_code}</span>}
              </li>
            ))}
          </ul>
        ) : <div className="small muted">None recorded</div>}
      </Section>
      <Section title="Latest vitals">
        <div className="small">{vitalsLine(summary.latest_vitals)}</div>
        {summary.latest_vitals && <div className="small muted">{formatDate(summary.latest_vitals.measured_at)}</div>}
      </Section>
      <Section title="Latest results">
        {summary.latest_echo || summary.latest_ecg || summary.latest_labs.length ? (
          <table className="results">
            <tbody>
              {summary.latest_echo && (
                <tr>
                  <th>LVEF</th>
                  <td>{summary.latest_echo.lvef ?? "—"}%{summary.latest_echo.lvef_method ? ` (${humanise(summary.latest_echo.lvef_method)})` : ""}</td>
                  <td>{formatDate(summary.latest_echo.performed_on)}</td>
                </tr>
              )}
              {summary.latest_ecg && (
                <tr>
                  <th>ECG</th>
                  <td>{humanise(summary.latest_ecg.rhythm)}{summary.latest_ecg.qrs_ms ? `, QRS ${summary.latest_ecg.qrs_ms} ms` : ""}</td>
                  <td>{formatDate(summary.latest_ecg.performed_on)}</td>
                </tr>
              )}
              {summary.latest_labs.map((l) => (
                <tr key={l.analyte_code}>
                  <th title={l.analyte_name}>{l.analyte_name}</th>
                  <td>
                    {l.comparator !== "=" ? l.comparator : ""}{l.value_reported ?? "—"} {l.unit_reported}
                    {l.verification_status === "unverified" && <span className="badge" title="Not yet verified"> unverified</span>}
                  </td>
                  <td>{formatDate(l.collected_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <div className="small muted">No results recorded</div>}
      </Section>
    </div>
  );
}
