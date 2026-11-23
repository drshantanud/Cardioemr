"use client";
import { useCallback, useEffect, useState } from "react";
import { ApiError } from "@/lib/api";
import { formatDate } from "@/lib/format";
import { humanCode } from "@/lib/registry";
import { useSession } from "@/lib/session";
import type { Gdmt, GdmtPillar, LipidTargets } from "@/lib/types";
import { Card, ErrorBanner, Loading } from "./ui";

const PILLAR_LABEL: Record<string, string> = { RASI: "ARNI / ACEI / ARB", BB: "Beta-blocker", MRA: "MRA", SGLT2I: "SGLT2 inhibitor" };
const STATUS_LABEL: Record<string, [string, string]> = {
  at_target: ["at target", "badge-ok"], below_target_uptitrating: ["below target", "badge-warn"],
  below_target_max_tolerated: ["max tolerated", "badge-info"], not_prescribed: ["not prescribed", "badge-danger"],
  not_indicated: ["not indicated", ""],
};
export const GDMT_REASONS: [string, string][] = [
  ["contraindication", "Contraindicated"], ["intolerance", "Intolerance"], ["hypotension", "Hypotension"],
  ["hyperkalaemia", "Hyperkalaemia"], ["renal_dysfunction", "Renal dysfunction"], ["bradycardia", "Bradycardia"],
  ["worsening_hf", "Worsening HF"], ["patient_refusal", "Patient declined"], ["financial", "Cost"],
  ["drug_unavailable", "Not available"], ["titration_in_progress", "Titration in progress"],
  ["recently_initiated", "Recently started"], ["not_indicated_for_phenotype", "Not indicated for phenotype"], ["other", "Other"],
];

function needsReason(p: GdmtPillar): boolean {
  return p.eligible && p.dose_status !== "at_target";
}

/** The four HF pillars on the assessment date, with a reason for each one not at target. */
export function GdmtPanel({ assessmentId, locked, refreshKey }: { assessmentId: string; locked: boolean; refreshKey?: number }) {
  const { api } = useSession();
  const [g, setG] = useState<Gdmt | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [waiting, setWaiting] = useState<string | null>(null);
  const [added, setAdded] = useState<Record<string, { code: string; detail: string }>>({});
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      setG((await api<Gdmt>(`/assessments/${assessmentId}/hf/gdmt`)).data);
      setError(null);
      setWaiting(null);
    } catch (e) {
      setG(null);
      if (e instanceof ApiError && e.status === 422) {
        setWaiting("Needs the HF phenotype for this visit. Enter it (or the LVEF) in the form and save; this updates itself.");
      } else {
        setError(e instanceof ApiError ? e.userMessage : "Could not work out GDMT");
      }
    }
  }, [api, assessmentId]);
  useEffect(() => { void load(); }, [load, refreshKey]);

  const save = async () => {
    if (!g) return;
    setBusy(true);
    setError(null);
    const reasons = g.pillars.flatMap((p) => p.reasons.map((r) => ({ pillar: p.pillar, reason_code: r })));
    for (const [pillar, a] of Object.entries(added)) {
      if (a.code) reasons.push({ pillar: pillar as GdmtPillar["pillar"], reason_code: a.code, ...(a.detail ? { detail: a.detail } : {}) } as never);
    }
    try {
      setG((await api<Gdmt>(`/assessments/${assessmentId}/hf/gdmt`, { method: "PUT", body: { reasons } })).data);
      setAdded({});
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not save");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card title="Guideline-directed therapy" flush actions={g && <span className="small muted">{g.rule_set}{g.rule_set_status !== "active" ? " (draft rules)" : ""}</span>}>
      {error && <div className="card-body"><ErrorBanner message={error} /></div>}
      {waiting && <div className="card-body small muted">{waiting}</div>}
      {!g && !error && !waiting && <Loading />}
      {g && (
        <>
          <div className="card-body small">
            {g.hf_phenotype} on {formatDate(g.as_of)}: <strong>{g.pillars_on_treatment}</strong> of {g.pillars_eligible} eligible pillars prescribed,{" "}
            <strong>{g.pillars_at_target}</strong> at target dose{g.stored ? "" : " (not saved for this visit yet)"}.
          </div>
          <table className="list gdmt">
            <thead><tr><th>Pillar</th><th>Now</th><th>Target</th><th>Status</th><th>Reason</th></tr></thead>
            <tbody>
              {g.pillars.map((p) => {
                const [label, tone] = STATUS_LABEL[p.dose_status] ?? [humanCode(p.dose_status), ""];
                const a = added[p.pillar] ?? { code: "", detail: "" };
                return (
                  <tr key={p.pillar}>
                    <td data-label="Pillar"><strong>{PILLAR_LABEL[p.pillar]}</strong>{p.drug_code && <div className="small muted">{humanCode(p.drug_code.toLowerCase())}</div>}</td>
                    <td data-label="Now">{p.daily_dose != null ? `${p.daily_dose} mg/day` : "—"}</td>
                    <td data-label="Target">{p.target_daily_dose != null ? `${p.target_daily_dose} mg/day` : "—"}{p.pct_of_target != null ? <div className="small muted">{Math.round(p.pct_of_target)}%</div> : null}</td>
                    <td data-label="Status"><span className={`badge ${tone}`}>{label}</span></td>
                    <td data-label="Reason">
                      {p.reasons.map((r) => <span key={r} className="badge" style={{ marginRight: 4 }}>{GDMT_REASONS.find(([c]) => c === r)?.[1] ?? r}</span>)}
                      {!locked && needsReason(p) && (
                        <span className="row" style={{ gap: 4, marginTop: p.reasons.length ? 4 : 0 }}>
                          <select className="input" aria-label={`Reason for ${PILLAR_LABEL[p.pillar]}`} value={a.code} style={{ minWidth: 150 }}
                            onChange={(e) => setAdded({ ...added, [p.pillar]: { ...a, code: e.target.value } })}>
                            <option value="">{p.reasons.length ? "Add a reason…" : "Why not at target?"}</option>
                            {GDMT_REASONS.filter(([c]) => !p.reasons.includes(c)).map(([c, l]) => <option key={c} value={c}>{l}</option>)}
                          </select>
                          {a.code === "other" && (
                            <input className="input" aria-label={`Other reason for ${PILLAR_LABEL[p.pillar]}`} value={a.detail} placeholder="Say why"
                              onChange={(e) => setAdded({ ...added, [p.pillar]: { ...a, detail: e.target.value } })} />
                          )}
                        </span>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          {!locked && (
            <div className="card-body row" style={{ justifyContent: "space-between" }}>
              <span className="small muted">Reasons are kept once saved; add more at any time.</span>
              <button type="button" className="btn btn-sm btn-primary" disabled={busy || Object.values(added).some((a) => a.code === "other" && !a.detail.trim())}
                onClick={() => void save()}>{g.stored ? "Save reasons" : "Save for this visit"}</button>
            </div>
          )}
        </>
      )}
    </Card>
  );
}

/** LDL-C against the protocol's guidelines, once a risk category is chosen for each. */
/** Form questions the targets panel fills (risk category and LDL-C goal under each guideline). */
export const LIPID_PANEL_VARIABLES = ["risk_category", "ldl_target", "lai_risk_category", "ldl_target_lai"];

export function LipidTargetsPanel({ assessmentId, locked, refreshKey, onSaved }: {
  assessmentId: string; locked: boolean; refreshKey?: number; onSaved?: (formValues: string[]) => void;
}) {
  const { api } = useSession();
  const [t, setT] = useState<LipidTargets | null>(null);
  const [choice, setChoice] = useState<Record<string, string>>({});
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [replacesTyped, setReplacesTyped] = useState(false);

  const load = useCallback(async () => {
    try {
      const r = (await api<LipidTargets>(`/assessments/${assessmentId}/lipid/targets`)).data;
      setT(r);
      setChoice(Object.fromEntries(r.items.map((i) => [i.rule_set_code, i.risk_category])));
    } catch (e) {
      setError(e instanceof ApiError ? e.userMessage : "Could not load lipid targets");
    }
  }, [api, assessmentId]);
  useEffect(() => { void load(); }, [load, refreshKey]);

  if (!t) return <Card title="LDL-C targets">{error ? <ErrorBanner message={error} /> : <Loading />}</Card>;
  const stored = Object.fromEntries(t.items.map((i) => [i.rule_set_code, i]));
  const changed = Object.entries(choice).filter(([k, v]) => v && stored[k]?.risk_category !== v);
  // a reason is needed to change a saved category, or to replace an answer already typed on the form
  const recategorising = changed.some(([k]) => stored[k]) || replacesTyped;

  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ items: LipidTargets["items"]; form_values: string[] }>(`/assessments/${assessmentId}/lipid/targets`, {
        method: "PUT", changeReason: recategorising ? reason.trim() : undefined,
        body: { categories: changed.map(([rule_set_code, risk_category]) => ({ rule_set_code, risk_category })) },
      });
      setT({ ...t, items: r.data.items });
      setReason("");
      setReplacesTyped(false);
      if (r.data.form_values.length) onSaved?.(r.data.form_values);
    } catch (e) {
      if (e instanceof ApiError && e.status === 428 && !recategorising) {
        setReplacesTyped(true);
        setError("The form already has a different answer for this. Give a reason to replace it.");
      } else {
        setError(e instanceof ApiError ? e.userMessage : "Could not save");
      }
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card title="LDL-C targets" flush>
      {error && <div className="card-body"><ErrorBanner message={error} /></div>}
      <ul className="plain">
        {t.guidelines.map((g) => {
          const row = stored[g.rule_set_code];
          return (
            <li key={g.rule_set_code} style={{ flexWrap: "wrap" }}>
              <span style={{ minWidth: 0 }}>
                <strong>{g.rule_set_code.replace(/_/g, " ")}</strong>
                <span className="small muted"> · {g.is_primary ? "primary" : "secondary"}{g.status !== "active" ? " · draft rules" : ""}</span>
                <br />
                {row ? (
                  <span className="small">
                    LDL-C {row.ldl_mg_dl != null ? `${row.ldl_mg_dl} mg/dL` : "not recorded"} against &lt;{row.ldl_target_mg_dl} mg/dL
                    {row.ldl_pct_reduction ? ` · ${Math.round(row.ldl_pct_reduction)}% lower than baseline` : ""}{" "}
                    {row.target_met === true ? <span className="badge badge-ok">target met</span>
                      : row.target_met === false ? <span className="badge badge-danger">not at target</span> : null}
                  </span>
                ) : <span className="small muted">Choose the risk category to see the target.</span>}
              </span>
              {!locked && (
                <select className="input" style={{ width: "auto", minWidth: 180 }} aria-label={`Risk category under ${g.rule_set_code}`}
                  value={choice[g.rule_set_code] ?? ""} onChange={(e) => setChoice({ ...choice, [g.rule_set_code]: e.target.value })}>
                  <option value="">Risk category…</option>
                  {g.categories.map((c) => <option key={c.risk_category} value={c.risk_category}>{humanCode(c.risk_category)} (&lt;{c.ldl_target_mg_dl})</option>)}
                </select>
              )}
            </li>
          );
        })}
      </ul>
      {!locked && changed.length > 0 && (
        <div className="card-body row" style={{ justifyContent: "flex-end" }}>
          {recategorising && (
            <input className="input" style={{ flex: 1, minWidth: 200 }} aria-label="Reason for changing the risk category"
              placeholder={replacesTyped ? "Reason for replacing the form's answer" : "Reason for changing the category"} value={reason} onChange={(e) => setReason(e.target.value)} />
          )}
          <button type="button" className="btn btn-sm btn-primary" disabled={busy || (recategorising && reason.trim().length < 3)} onClick={() => void save()}>
            Save categories
          </button>
        </div>
      )}
    </Card>
  );
}
