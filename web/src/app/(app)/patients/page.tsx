"use client";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { Suspense, useEffect, useState } from "react";
import { ErrorBanner, Loading, SearchIcon } from "@/components/ui";
import { ApiError } from "@/lib/api";
import { ageSex, formatDate, formatMobile } from "@/lib/format";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import type { PatientList, PatientSummary } from "@/lib/types";

const PAGE = 25;

function usePatients(q: string) {
  const { api } = useSession();
  const [items, setItems] = useState<PatientSummary[]>([]);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchPage = async (offset: number, signal?: AbortSignal) => {
    setLoading(true);
    setError(null);
    try {
      const { data } = await api<PatientList>("/patients", { query: { q: q || undefined, limit: PAGE, offset }, signal });
      setItems((prev) => (offset === 0 ? data.items : [...prev, ...data.items]));
      setHasMore(data.has_more);
    } catch (e) {
      if ((e as Error).name === "AbortError") return;
      setError(e instanceof ApiError ? e.userMessage : "Could not load patients");
    } finally {
      if (!signal?.aborted) setLoading(false);
    }
  };

  useEffect(() => {
    const ctrl = new AbortController();
    const t = setTimeout(() => void fetchPage(0, ctrl.signal), q ? 250 : 0);
    return () => {
      clearTimeout(t);
      ctrl.abort();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q, api]);

  return { items, hasMore, loading, error, more: () => fetchPage(items.length) };
}

function Patients() {
  const { selection, membership } = useSession();
  const router = useRouter();
  const params = useSearchParams();
  const [q, setQ] = useState(params.get("q") ?? "");
  const { items, hasMore, loading, error, more } = usePatients(q.trim());

  useEffect(() => {
    const url = q ? `/patients?q=${encodeURIComponent(q)}` : "/patients";
    window.history.replaceState(null, "", url);
  }, [q]);

  const open = (p: PatientSummary) => router.push(`/patients/${p.patient_id}`);

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Patients</h1>
          <p>Registered at {membership?.centre_name}</p>
        </div>
        {can(selection?.role, "patients.register") && (
          <Link className="btn btn-primary" href="/patients/new">Register patient</Link>
        )}
      </div>

      <div className="row" style={{ marginBottom: 16 }}>
        <label className="search">
          <span className="sr-only">Search patients</span>
          <SearchIcon />
          <input className="input" type="search" placeholder="Name, patient ID or mobile" value={q} autoFocus
            onChange={(e) => setQ(e.target.value)} autoComplete="off" spellCheck={false} />
        </label>
      </div>

      {error && <ErrorBanner message={error} />}

      <div className="card">
        {items.length === 0 && !loading && !error && (
          <div className="empty">
            {q ? <>No patient matches “{q}” at this centre.</> : <>No patients registered at this centre yet.</>}
          </div>
        )}
        {items.length > 0 && (
          <>
            <table className="list patients-table">
              <thead>
                <tr>
                  <th>Patient ID</th>
                  <th>Name</th>
                  <th>Age · sex</th>
                  <th>Mobile</th>
                  <th>City</th>
                  <th>Registered</th>
                </tr>
              </thead>
              <tbody>
                {items.map((p) => (
                  <tr key={p.patient_id} onClick={() => open(p)}>
                    <td className="mono">{p.local_patient_code}</td>
                    <td>
                      <Link href={`/patients/${p.patient_id}`} onClick={(e) => e.stopPropagation()}>
                        <strong>{p.display_name}</strong>
                      </Link>
                      {p.status !== "active" && <span className="badge badge-warn" style={{ marginLeft: 8 }}>{p.status}</span>}
                    </td>
                    <td>{ageSex(p.age_years, p.sex, p.dob_precision === "estimated_from_age")}</td>
                    <td>{formatMobile(p.mobile)}</td>
                    <td>{p.city ?? "—"}</td>
                    <td>{formatDate(p.registration_date)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <div className="patient-cards">
              {items.map((p) => (
                <Link key={p.patient_id} href={`/patients/${p.patient_id}`} className="patient-card">
                  <div className="row" style={{ justifyContent: "space-between" }}>
                    <strong>{p.display_name}</strong>
                    <span className="mono small muted">{p.local_patient_code}</span>
                  </div>
                  <div className="small muted">
                    {ageSex(p.age_years, p.sex, p.dob_precision === "estimated_from_age")} · {formatMobile(p.mobile)}
                    {p.city ? ` · ${p.city}` : ""}
                  </div>
                </Link>
              ))}
            </div>
          </>
        )}
        {loading && <div style={{ padding: "0 16px" }}><Loading /></div>}
      </div>
      {hasMore && !loading && (
        <div className="row" style={{ justifyContent: "center", marginTop: 16 }}>
          <button className="btn" onClick={() => void more()}>Show more</button>
        </div>
      )}
    </>
  );
}

export default function PatientsPage() {
  return (
    <Suspense fallback={<Loading />}>
      <Patients />
    </Suspense>
  );
}
