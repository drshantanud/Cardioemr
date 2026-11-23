"use client";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useState } from "react";
import { FIELDS, PatientForm, toBody, valuesFrom, type PatientFormValues } from "@/components/PatientForm";
import { ErrorBanner, Field, Loading } from "@/components/ui";
import { ApiError } from "@/lib/api";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import type { Patient } from "@/lib/types";
import { usePatient } from "@/lib/usePatient";

export default function EditPatientPage() {
  const { id } = useParams<{ id: string }>();
  const router = useRouter();
  const { api, selection } = useSession();
  const { data, etag, error: loadError, reload } = usePatient(id);
  const [reason, setReason] = useState("");
  const [reasonError, setReasonError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  if (!can(selection?.role, "patients.edit")) return <ErrorBanner message="Your role cannot change patient details." />;
  if (loadError) return <ErrorBanner message={loadError.userMessage} />;
  if (!data || !etag) return <Loading />;
  const initial = valuesFrom(data.patient);

  const submit = async (v: PatientFormValues) => {
    if (reason.trim().length < 3) {
      setReasonError("Say briefly why the details are changing");
      document.getElementById("change_reason")?.focus();
      return;
    }
    setReasonError(null);
    // Send only what changed, so a concurrent edit to another field is not overwritten silently.
    const before = toBody(initial, "dob");
    const after = toBody(v, "dob");
    const changes: Record<string, unknown> = {};
    for (const f of FIELDS) if (f !== "age_years" && before[f] !== after[f]) changes[f] = after[f];
    if ("date_of_birth" in changes) changes.dob_precision = "day";
    if (Object.keys(changes).length === 0) {
      router.push(`/patients/${id}`);
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await api<Patient>(`/patients/${encodeURIComponent(id)}`, {
        method: "PATCH", body: changes, ifMatch: etag, changeReason: reason.trim(),
      });
      router.push(`/patients/${id}`);
    } catch (e) {
      setBusy(false);
      if (e instanceof ApiError && e.code === "STALE_VERSION") {
        setError(e.userMessage);
        void reload();
      } else {
        setError(e instanceof ApiError ? e.userMessage : "Could not save");
      }
    }
  };

  return (
    <>
      <div className="breadcrumb">
        <Link href="/patients">Patients</Link> / <Link href={`/patients/${id}`}>{data.patient.local_patient_code}</Link> / Edit
      </div>
      <div className="page-head">
        <div>
          <h1>Edit {data.patient.display_name}</h1>
          <p>Every change is kept in the audit trail with its reason.</p>
        </div>
      </div>
      <PatientForm
        key={etag}
        initial={initial}
        allowAge={false}
        busy={busy}
        onSubmit={(v) => void submit(v)}
        banner={error ? <ErrorBanner message={error} /> : undefined}
        footer={
          <>
            <Field label="Reason for change" htmlFor="change_reason" required error={reasonError ?? undefined}>
              <input id="change_reason" className="input" value={reason} maxLength={500}
                placeholder="e.g. New mobile number" onChange={(e) => setReason(e.target.value)}
                aria-invalid={reasonError ? true : undefined} style={{ minWidth: 260 }} />
            </Field>
            <span style={{ flex: 1 }} />
            <Link className="btn" href={`/patients/${id}`} style={{ alignSelf: "flex-end" }}>Cancel</Link>
          </>
        }
      />
    </>
  );
}
