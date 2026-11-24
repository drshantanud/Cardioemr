"use client";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { PciForm } from "@/components/PciForm";
import { Card, ErrorBanner, Field, Loading, StatusBadge } from "@/components/ui";
import { ApiError, newIdempotencyKey } from "@/lib/api";
import {
  label, lesionLine, newPci, pciBody, pciDraftOf, PCI_OPTIONS, stentLine, validatePci, type PciDraft, type PciErrors,
} from "@/lib/cad";
import { formatDate } from "@/lib/format";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import type { PciProcedure } from "@/lib/types";
import { usePatient } from "@/lib/usePatient";

const today = () => new Date().toLocaleDateString("en-CA");

function Summary({ p }: { p: PciProcedure }) {
  const yes = (v: boolean | null) => (v == null ? "—" : v ? "Yes" : "No");
  return (
    <div className="stack">
      <Card title="Procedure">
        <dl className="facts">
          <dt>Date</dt><dd>{formatDate(p.procedure_date)}</dd>
          <dt>Indication</dt><dd>{label(PCI_OPTIONS.indication, p.indication)}{p.urgency ? ` · ${label(PCI_OPTIONS.urgency, p.urgency)}` : ""}</dd>
          <dt>Access</dt><dd>{label(PCI_OPTIONS.access_site, p.access_site) || "—"}</dd>
          <dt>Imaging</dt><dd>{label(PCI_OPTIONS.imaging_guidance, p.imaging_guidance)}</dd>
          <dt>Physiology</dt><dd>{label(PCI_OPTIONS.physiology, p.physiology)}</dd>
          <dt>Mechanical support</dt><dd>{label(PCI_OPTIONS.mechanical_support, p.mechanical_support) || "—"}</dd>
          <dt>Operator</dt><dd>{p.operator_name ?? "—"}{p.performed_at_facility ? ` · ${p.performed_at_facility}` : ""}</dd>
          <dt>Contrast, fluoroscopy</dt>
          <dd>{p.contrast_ml != null ? `${p.contrast_ml} mL` : "—"}, {p.fluoroscopy_min != null ? `${p.fluoroscopy_min} min` : "—"}</dd>
          <dt>Procedural success</dt><dd>{yes(p.procedural_success)}</dd>
          <dt>Complications</dt><dd>{p.complications?.length ? p.complications.map((c) => label(PCI_OPTIONS.complications, c)).join(", ") : "—"}</dd>
        </dl>
      </Card>
      <Card title="Lesions" flush>
        <ul className="plain">
          {p.lesions.map((l) => (
            <li key={l.lesion_number} style={{ flexDirection: "column", alignItems: "stretch" }}>
              <span><strong>Lesion {l.lesion_number}</strong> · {lesionLine(l)}</span>
              {l.lesion_preparation?.length ? (
                <span className="small muted">Preparation: {l.lesion_preparation.map((x) => label(PCI_OPTIONS.lesion_preparation, x)).join(", ")}</span>
              ) : null}
              {l.final_timi_flow != null && <span className="small muted">Final TIMI {l.final_timi_flow}</span>}
              {l.stents.map((s) => <span key={s.sequence_number} className="small">Stent {s.sequence_number}: {stentLine(s)}</span>)}
            </li>
          ))}
        </ul>
      </Card>
    </div>
  );
}

export default function PciPage() {
  const { id, pid } = useParams<{ id: string; pid: string }>();
  const isNew = pid === "new";
  const router = useRouter();
  const { api, selection } = useSession();
  const { data: patient } = usePatient(id);
  const role = selection?.role;
  const [proc, setProc] = useState<PciProcedure | null>(null);
  const [etag, setEtag] = useState<string | null>(null);
  const [draft, setDraft] = useState<PciDraft | null>(isNew ? newPci(today()) : null);
  const [editing, setEditing] = useState(isNew);
  const [errors, setErrors] = useState<PciErrors>({});
  const [error, setError] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [withdrawing, setWithdrawing] = useState(false);
  const key = useRef<string | null>(null);

  useEffect(() => {
    if (isNew) return;
    api<PciProcedure>(`/pci-procedures/${pid}`)
      .then((r) => { setProc(r.data); setEtag(r.etag); setDraft(pciDraftOf(r.data)); })
      .catch((e) => setError(e instanceof ApiError ? e.userMessage : "Could not load the procedure"));
  }, [api, pid, isNew]);

  const needsReason = !isNew && proc?.status !== "draft";

  const save = async (status?: PciDraft["status"]) => {
    if (!draft) return;
    const d = status ? { ...draft, status } : draft;
    const errs = validatePci(d, today());
    setErrors(errs);
    if (Object.keys(errs).length) {
      setError("Some answers need attention.");
      document.querySelector<HTMLElement>("[aria-invalid='true']")?.focus();
      return;
    }
    if (needsReason && reason.trim().length < 3) {
      setError("Give a reason for changing a recorded procedure.");
      document.getElementById("pci-reason")?.focus();
      return;
    }
    setBusy(true);
    setError(null);
    try {
      if (isNew) {
        key.current ??= newIdempotencyKey();
        const r = await api<PciProcedure>(`/patients/${id}/pci-procedures`, { method: "POST", body: pciBody(d), idempotencyKey: key.current });
        router.replace(`/patients/${id}/pci/${r.data.procedure_id}?saved=1`);
        return;
      }
      const r = await api<PciProcedure>(`/pci-procedures/${pid}`, {
        method: "PUT", body: pciBody(d), ifMatch: etag ?? undefined, changeReason: needsReason ? reason.trim() : undefined,
      });
      setProc(r.data);
      setEtag(r.etag);
      setDraft(pciDraftOf(r.data));
      setEditing(false);
      setWithdrawing(false);
      setReason("");
    } catch (e) {
      key.current = null;
      setError(e instanceof ApiError ? (e.status === 412 ? "Someone else changed this procedure. Reload to see their version." : e.userMessage) : "Could not save");
    } finally {
      setBusy(false);
    }
  };

  const name = patient?.patient.display_name;
  const crumbs = (
    <div className="breadcrumb">
      <Link href="/patients">Patients</Link> / <Link href={`/patients/${id}`}>{name ?? "Patient"}</Link> / PCI
    </div>
  );
  if (!isNew && !proc) return <>{crumbs}{error ? <ErrorBanner message={error} /> : <Loading />}</>;

  return (
    <>
      {crumbs}
      <div className="page-head">
        <div>
          <h1>{isNew ? "Record PCI" : `PCI on ${formatDate(proc!.procedure_date)}`}</h1>
          {proc && <p><StatusBadge status={proc.status} /> {proc.lesions.length} lesion{proc.lesions.length === 1 ? "" : "s"}</p>}
        </div>
        {!isNew && !editing && can(role, "pci.write") && proc!.status !== "entered_in_error" && (
          <div className="row">
            <button type="button" className="btn" onClick={() => setWithdrawing(true)}>Mark entered in error</button>
            <button type="button" className="btn btn-primary" onClick={() => setEditing(true)}>Edit</button>
          </div>
        )}
      </div>
      {error && <div style={{ marginBottom: 16 }}><ErrorBanner message={error} /></div>}

      {withdrawing && !editing && (
        <div className="subpanel stack" style={{ gap: 12, marginBottom: 16 }}>
          <h3>Mark this procedure entered in error</h3>
          <p className="small muted">It stays in the record for audit, but leaves the patient&apos;s history and registry counts.</p>
          <Field label="Reason" htmlFor="pci-reason" required>
            <input id="pci-reason" className="input" value={reason} onChange={(e) => setReason(e.target.value)} />
          </Field>
          <div className="row">
            <button type="button" className="btn" onClick={() => setWithdrawing(false)}>Cancel</button>
            <button type="button" className="btn btn-danger" disabled={busy || reason.trim().length < 3} onClick={() => void save("entered_in_error")}>
              Mark entered in error
            </button>
          </div>
        </div>
      )}

      {editing && draft ? (
        <>
          <PciForm draft={draft} set={setDraft} errors={errors} today={today()} />
          <div className="form-actions">
            {needsReason && (
              <Field label="Reason for the change" htmlFor="pci-reason" required className="span-6">
                <input id="pci-reason" className="input" value={reason} onChange={(e) => setReason(e.target.value)} />
              </Field>
            )}
            {isNew ? <Link className="btn" href={`/patients/${id}`}>Cancel</Link> : (
              <button type="button" className="btn" onClick={() => { setEditing(false); setDraft(pciDraftOf(proc!)); setErrors({}); setError(null); }}>
                Cancel
              </button>
            )}
            {(isNew || proc?.status === "draft") && (
              <button type="button" className="btn" disabled={busy} onClick={() => void save("draft")}>Save as draft</button>
            )}
            <button type="button" className="btn btn-primary" disabled={busy} onClick={() => void save("final")}>
              {busy ? "Saving…" : "Save procedure"}
            </button>
          </div>
        </>
      ) : proc ? <Summary p={proc} /> : null}
    </>
  );
}
