"use client";
import Link from "next/link";
import { useParams, useSearchParams } from "next/navigation";
import { Suspense } from "react";
import { Card, ErrorBanner, Loading, StatusBadge } from "@/components/ui";
import {
  ageSex, formatDate, formatDateTime, formatDob, formatMobile, humanise, REFERRAL_SOURCES, SEX_LABEL, stateName,
} from "@/lib/format";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import { usePatient } from "@/lib/usePatient";

const CONSENT_LABELS: Record<string, string> = {
  clinical_care: "Clinical care",
  research_registry: "Research registry",
  cross_centre_linkage: "Cross-centre linkage",
  external_data_sharing: "External data sharing",
  ai_processing: "AI processing",
  recontact: "Re-contact",
};

function Overview() {
  const { id } = useParams<{ id: string }>();
  const params = useSearchParams();
  const { selection, membership } = useSession();
  const { data, error, reload } = usePatient(id);

  if (error) {
    return (
      <>
        <div className="breadcrumb"><Link href="/patients">Patients</Link></div>
        <ErrorBanner
          message={error.status === 404 ? "No patient with this ID is registered at this centre." : error.userMessage}
          action={error.status !== 404 ? <button className="btn btn-sm" onClick={() => void reload()}>Retry</button> : undefined}
        />
      </>
    );
  }
  if (!data) return <Loading />;
  const { patient: p, consents, allergies, recent_encounters: encounters, enrolments, registry_suggestions: suggestions } = data;
  const tz = membership?.timezone;
  const referral = REFERRAL_SOURCES.find(([c]) => c === p.referral_source)?.[1];
  const address = [p.address_line, p.city, p.district, p.state_code ? stateName(p.state_code) : null, p.pincode]
    .filter(Boolean).join(", ");

  return (
    <>
      <div className="breadcrumb"><Link href="/patients">Patients</Link> / {p.local_patient_code}</div>
      {params.get("registered") && (
        <div className="banner banner-info" role="status" style={{ marginBottom: 16 }}>
          Registered as <strong className="mono">{p.local_patient_code}</strong>.
        </div>
      )}

      <section className="card patient-header" aria-label="Patient">
        <div>
          <h1>{p.display_name}</h1>
          <div className="meta">
            <span className="mono">{p.local_patient_code}</span>
            <span>{ageSex(p.age_years, p.sex, p.dob_precision === "estimated_from_age")}</span>
            <span>Born {formatDob(p.date_of_birth, p.dob_precision)}</span>
            <span>{formatMobile(p.mobile)}</span>
            {p.status !== "active" && <StatusBadge status={p.status} />}
          </div>
          <div className="allergy-strip" aria-label="Allergies">
            {allergies.length === 0 ? (
              <span className="badge">No allergies recorded</span>
            ) : (
              allergies.map((a) => (
                <span key={a.allergy_id} className="badge badge-danger" title={a.reaction ?? undefined}>
                  Allergy: {a.allergen_text}{a.severity ? ` (${a.severity})` : ""}
                </span>
              ))
            )}
          </div>
        </div>
        {can(selection?.role, "patients.edit") && (
          <Link className="btn" href={`/patients/${p.patient_id}/edit`}>Edit details</Link>
        )}
      </section>

      <div className="grid-2">
        <div className="stack">
          <Card title="Details">
            <dl className="facts">
              <dt>Sex</dt><dd>{SEX_LABEL[p.sex]}</dd>
              <dt>Mobile</dt><dd>{formatMobile(p.mobile)}{p.alternate_mobile ? `, ${formatMobile(p.alternate_mobile)}` : ""}</dd>
              <dt>Email</dt><dd>{p.email ?? "—"}</dd>
              <dt>Address</dt><dd>{address || "—"}</dd>
              <dt>Emergency contact</dt>
              <dd>
                {p.emergency_contact_name
                  ? `${p.emergency_contact_name}${p.emergency_contact_relation ? ` (${p.emergency_contact_relation})` : ""}, ${formatMobile(p.emergency_contact_phone)}`
                  : "—"}
              </dd>
              <dt>Occupation</dt><dd>{p.occupation ?? "—"}</dd>
              <dt>Referred by</dt><dd>{referral ? `${referral}${p.referral_detail ? `: ${p.referral_detail}` : ""}` : "—"}</dd>
              <dt>ABHA number</dt><dd className="mono">{p.abha_number ?? "—"}</dd>
              <dt>Registered</dt><dd>{formatDate(p.registration_date)}</dd>
            </dl>
          </Card>
          <Card title="Consent" flush>
            {consents.length === 0 ? (
              <div className="empty">No consent recorded yet.</div>
            ) : (
              <ul className="plain">
                {consents.map((c) => (
                  <li key={c.consent_id}>
                    <span>
                      {CONSENT_LABELS[c.consent_type] ?? humanise(c.consent_type)}
                      {c.protocol_code && <span className="muted"> · {c.protocol_code}</span>}
                      <br />
                      <span className="small muted">{formatDate(c.consent_date)} · form {c.consent_form_version}</span>
                    </span>
                    <StatusBadge status={c.consent_status} />
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </div>
        <div className="stack">
          <Card title="Recent consultations" flush>
            {encounters.length === 0 ? (
              <div className="empty">No consultations recorded yet.</div>
            ) : (
              <ul className="plain">
                {encounters.map((e) => (
                  <li key={e.encounter_id}>
                    <span>
                      {humanise(e.encounter_type)}
                      <br />
                      <span className="small muted">
                        {formatDateTime(e.encounter_start, tz)}{e.clinician_name ? ` · ${e.clinician_name}` : ""}
                        {e.follow_up_date ? ` · follow-up ${formatDate(e.follow_up_date)}` : ""}
                      </span>
                    </span>
                    <StatusBadge status={e.status} />
                  </li>
                ))}
              </ul>
            )}
          </Card>
          {enrolments !== null && (
            <Card title="Registries" flush>
              {enrolments.length === 0 && (suggestions?.length ?? 0) === 0 ? (
                <div className="empty">Not in any registry.</div>
              ) : (
                <ul className="plain">
                  {enrolments.map((e) => (
                    <li key={e.enrolment_id}>
                      <span>
                        {e.registry_name} <span className="muted small">· {e.protocol_code}</span>
                        <br />
                        <span className="small muted">
                          {e.enrolment_date ? `Enrolled ${formatDate(e.enrolment_date)}` : `Screening since ${formatDate(e.screening_date)}`}
                        </span>
                      </span>
                      <StatusBadge status={e.enrolment_status} />
                    </li>
                  ))}
                  {suggestions?.map((s) => (
                    <li key={s.suggestion_id}>
                      <span>
                        {s.registry_code} registry
                        <br />
                        <span className="small muted">Suggested {formatDate(s.suggested_at)} from a diagnosis</span>
                      </span>
                      <span className="badge badge-info">eligible to screen</span>
                    </li>
                  ))}
                </ul>
              )}
            </Card>
          )}
        </div>
      </div>
    </>
  );
}

export default function PatientPage() {
  return (
    <Suspense fallback={<Loading />}>
      <Overview />
    </Suspense>
  );
}
