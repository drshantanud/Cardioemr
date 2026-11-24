"use client";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { ApiError, newIdempotencyKey } from "@/lib/api";
import { formatDate } from "@/lib/format";
import { REGISTRY_NAMES } from "@/lib/registry";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import type { Enrolment, EnrolmentHeader, Registry } from "@/lib/types";
import { ErrorBanner, StatusBadge } from "./ui";

interface Suggestion { suggestion_id: string; registry_code: string; suggested_at: string; row_version: number }

/** Registries on the patient overview: enrolments, suggestions raised by diagnoses, and screening. */
export function RegistryPanel({ patientId, enrolments, registries, onChanged }: {
  patientId: string; enrolments: EnrolmentHeader[]; registries: Registry[]; onChanged: () => void;
}) {
  const { api, selection } = useSession();
  const router = useRouter();
  const role = selection?.role;
  const [suggestions, setSuggestions] = useState<Suggestion[]>([]);
  const [dismissing, setDismissing] = useState<Suggestion | null>(null);
  const [reason, setReason] = useState("");
  const [picking, setPicking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const keys = useRef<Record<string, string>>({});

  useEffect(() => {
    if (!can(role, "suggestion.read")) return;
    api<{ items: Suggestion[] }>("/registry-suggestions", { query: { patient_id: patientId, status: "open" } })
      .then((r) => setSuggestions(r.data.items)).catch(() => setSuggestions([]));
  }, [api, patientId, role, enrolments]);

  const live = new Set(enrolments.filter((e) => ["screening", "enrolled"].includes(e.enrolment_status)).map((e) => e.protocol_id));
  const protocols = registries.flatMap((r) => r.protocols
    .filter((p) => p.site_status === "active" && p.status === "active" && !live.has(p.protocol_id))
    .map((p) => ({ ...p, registry_code: r.registry_code, registry_name: r.registry_name })));

  const screen = async (protocolId: string, suggestionId?: string) => {
    setBusy(true);
    setError(null);
    const k = `${protocolId}:${suggestionId ?? ""}`;
    keys.current[k] ??= newIdempotencyKey();
    try {
      const r = await api<Enrolment>("/enrolments", {
        method: "POST", idempotencyKey: keys.current[k],
        body: { patient_id: patientId, protocol_id: protocolId, suggestion_id: suggestionId },
      });
      router.push(`/patients/${patientId}/registries/${r.data.enrolment_id}`);
    } catch (e) {
      delete keys.current[k];
      setError(e instanceof ApiError ? e.userMessage : "Could not start screening");
      setBusy(false);
    }
  };

  const dismiss = async () => {
    if (!dismissing) return;
    setBusy(true);
    setError(null);
    try {
      await api(`/registry-suggestions/${dismissing.suggestion_id}`, {
        method: "PATCH", ifMatch: `"${dismissing.row_version}"`, body: { status: "dismissed", dismiss_reason: reason.trim() },
      });
      setDismissing(null);
      setReason("");
      onChanged();
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not dismiss the suggestion");
    } finally {
      setBusy(false);
    }
  };

  const protocolFor = (code: string) => protocols.find((p) => p.registry_code === code);
  const canScreen = can(role, "registry.screen");

  return (
    <div>
      {error && <div style={{ padding: "12px 16px 0" }}><ErrorBanner message={error} /></div>}
      {enrolments.length === 0 && suggestions.length === 0 && <div className="empty">Not in any registry.</div>}
      <ul className="plain">
        {enrolments.map((e) => (
          <li key={e.enrolment_id}>
            <span>
              {can(role, "registry.screen") ? (
                <Link href={`/patients/${patientId}/registries/${e.enrolment_id}`}>{e.registry_name}</Link>
              ) : e.registry_name}
              <span className="muted small"> · {e.protocol_code}</span>
              <br />
              <span className="small muted">
                {e.enrolment_date ? `Enrolled ${formatDate(e.enrolment_date)}` : `Screening since ${formatDate(e.screening_date)}`}
              </span>
            </span>
            <StatusBadge status={e.enrolment_status} />
          </li>
        ))}
        {suggestions.map((s) => (
          <li key={s.suggestion_id} className="suggestion">
            <span>
              {REGISTRY_NAMES[s.registry_code] ?? s.registry_code} registry
              <br />
              <span className="small muted">Suggested {formatDate(s.suggested_at)} from a diagnosis</span>
            </span>
            {canScreen ? (
              <span className="row" style={{ gap: 6 }}>
                {protocolFor(s.registry_code) && (
                  <button type="button" className="btn btn-sm btn-primary" disabled={busy}
                    onClick={() => void screen(protocolFor(s.registry_code)!.protocol_id, s.suggestion_id)}>Start screening</button>
                )}
                <button type="button" className="btn btn-sm" onClick={() => setDismissing(s)}>Dismiss</button>
              </span>
            ) : <span className="badge badge-info">eligible to screen</span>}
          </li>
        ))}
      </ul>
      {dismissing && (
        <div className="card-body">
          <div className="subpanel stack" style={{ gap: 10 }}>
            <label htmlFor="dismiss-reason" className="small"><strong>Why not screen for the {REGISTRY_NAMES[dismissing.registry_code]} registry?</strong></label>
            <input id="dismiss-reason" className="input" value={reason} onChange={(e) => setReason(e.target.value)}
              placeholder="e.g. Already enrolled at another centre" />
            <div className="row" style={{ justifyContent: "flex-end" }}>
              <button type="button" className="btn btn-sm" onClick={() => setDismissing(null)}>Cancel</button>
              <button type="button" className="btn btn-sm btn-primary" disabled={busy || reason.trim().length < 3} onClick={() => void dismiss()}>Dismiss suggestion</button>
            </div>
          </div>
        </div>
      )}
      {canScreen && protocols.length > 0 && (
        <div className="card-body" style={{ borderTop: "1px solid var(--border)" }}>
          {!picking ? (
            <button type="button" className="btn btn-sm" onClick={() => setPicking(true)}>Screen for a registry</button>
          ) : (
            <div className="row">
              {protocols.map((p) => (
                <button key={p.protocol_id} type="button" className="btn btn-sm" disabled={busy}
                  onClick={() => void screen(p.protocol_id)}>{p.registry_name}</button>
              ))}
              <button type="button" className="btn btn-sm btn-ghost" onClick={() => setPicking(false)}>Cancel</button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
