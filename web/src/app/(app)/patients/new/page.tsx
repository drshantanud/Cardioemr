"use client";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useRef, useState } from "react";
import { PatientForm, emptyValues, toBody, type PatientFormValues } from "@/components/PatientForm";
import { ErrorBanner } from "@/components/ui";
import { ApiError, newIdempotencyKey } from "@/lib/api";
import { formatDate, formatMobile } from "@/lib/format";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import type { DuplicateCandidate, Patient } from "@/lib/types";

export default function NewPatientPage() {
  const { api, selection, membership } = useSession();
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [duplicates, setDuplicates] = useState<DuplicateCandidate[] | null>(null);
  const last = useRef<{ body: string; key: string } | null>(null);
  const pending = useRef<Record<string, unknown> | null>(null);

  if (!can(selection?.role, "patients.register")) {
    return <ErrorBanner message="Your role cannot register patients." />;
  }

  const send = async (body: Record<string, unknown>) => {
    // Same body, same key: a double click or a retry after a lost response registers the patient once.
    const json = JSON.stringify(body);
    if (last.current?.body !== json) last.current = { body: json, key: newIdempotencyKey() };
    setBusy(true);
    setError(null);
    try {
      const { data } = await api<Patient>("/patients", { method: "POST", body, idempotencyKey: last.current.key });
      router.replace(`/patients/${data.patient_id}?registered=1`);
    } catch (e) {
      if (e instanceof ApiError && e.code === "POSSIBLE_DUPLICATE") {
        pending.current = body;
        setDuplicates((e.current as DuplicateCandidate[]) ?? []);
        window.scrollTo({ top: 0, behavior: "smooth" });
      } else {
        setError(e instanceof ApiError ? e.userMessage : "Could not register the patient");
      }
      setBusy(false);
    }
  };

  const submit = (v: PatientFormValues, mode: "dob" | "age") => {
    setDuplicates(null);
    void send(toBody(v, mode));
  };

  const banner = (
    <>
      {error && <ErrorBanner message={error} />}
      {duplicates && (
        <div className="banner banner-warn" role="alert">
          <div className="stack" style={{ gap: 10, flex: 1 }}>
            <div>
              <strong>This may be a patient already registered here.</strong> Check before creating a second record.
            </div>
            <ul className="plain card" style={{ background: "var(--surface)" }}>
              {duplicates.map((d) => (
                <li key={d.patient_id}>
                  <span>
                    <strong>{d.display_name}</strong>{" "}
                    <span className="mono small muted">{d.local_patient_code}</span>
                    <br />
                    <span className="small muted">Born {formatDate(d.date_of_birth)} · {formatMobile(d.mobile)}</span>
                  </span>
                  <Link className="btn btn-sm" href={`/patients/${d.patient_id}`}>Open</Link>
                </li>
              ))}
            </ul>
            <div className="row">
              <button type="button" className="btn" disabled={busy}
                onClick={() => pending.current && void send({ ...pending.current, confirm_not_duplicate: true })}>
                Different person, register anyway
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );

  return (
    <>
      <div className="breadcrumb"><Link href="/patients">Patients</Link> / Register</div>
      <div className="page-head">
        <div>
          <h1>Register patient</h1>
          <p>A patient ID for {membership?.centre_code} is created when you save.</p>
        </div>
      </div>
      <PatientForm initial={emptyValues()} allowAge onSubmit={submit} busy={busy}
        banner={error || duplicates ? banner : undefined}
        footer={<Link className="btn" href="/patients">Cancel</Link>} />
    </>
  );
}
