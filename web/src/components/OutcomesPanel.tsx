"use client";
import Link from "next/link";
import { useEffect, useState } from "react";
import { eventDate, eventLine, label, lesionLine, PCI_OPTIONS } from "@/lib/cad";
import { formatDate } from "@/lib/format";
import { can } from "@/lib/roles";
import { useSession } from "@/lib/session";
import type { ClinicalEvent, PciProcedure } from "@/lib/types";
import { Card, Loading, StatusBadge } from "./ui";

/** PCI procedures and clinical events on the patient's record. */
export function OutcomesPanel({ patientId }: { patientId: string }) {
  const { api, selection } = useSession();
  const role = selection?.role;
  const [procs, setProcs] = useState<PciProcedure[] | null>(null);
  const [events, setEvents] = useState<ClinicalEvent[] | null>(null);

  useEffect(() => {
    if (can(role, "pci.read")) {
      api<{ items: PciProcedure[] }>(`/patients/${patientId}/pci-procedures`).then((r) => setProcs(r.data.items)).catch(() => setProcs([]));
    }
    if (can(role, "event.read")) {
      api<{ items: ClinicalEvent[] }>(`/patients/${patientId}/events`).then((r) => setEvents(r.data.items)).catch(() => setEvents([]));
    }
  }, [api, patientId, role]);

  if (!can(role, "pci.read") && !can(role, "event.read")) return null;
  return (
    <>
      {can(role, "pci.read") && (
        <Card title="PCI procedures" flush actions={can(role, "pci.write") ? (
          <Link className="btn btn-sm" href={`/patients/${patientId}/pci/new`}>Record PCI</Link>
        ) : undefined}>
          {procs === null ? <Loading /> : procs.length === 0 ? <div className="empty">No PCI recorded.</div> : (
            <ul className="plain">
              {procs.map((p) => (
                <li key={p.procedure_id}>
                  <span style={{ minWidth: 0 }}>
                    <Link href={`/patients/${patientId}/pci/${p.procedure_id}`}>{formatDate(p.procedure_date)} · {label(PCI_OPTIONS.indication, p.indication)}</Link>
                    <br />
                    <span className="small muted">{p.lesions.map(lesionLine).join("; ")}</span>
                  </span>
                  {p.status !== "final" && <StatusBadge status={p.status} />}
                </li>
              ))}
            </ul>
          )}
        </Card>
      )}
      {can(role, "event.read") && (
        <Card title="Clinical events" flush actions={can(role, "event.report") ? (
          <Link className="btn btn-sm" href={`/patients/${patientId}/events/new`}>Report event</Link>
        ) : undefined}>
          {events === null ? <Loading /> : events.length === 0 ? <div className="empty">No events reported.</div> : (
            <ul className="plain">
              {[...events].reverse().map((e) => (
                <li key={e.event_id}>
                  <span>
                    <Link href={`/patients/${patientId}/events/${e.event_id}`}>{eventLine(e)}</Link>
                    <br />
                    <span className="small muted">{eventDate(e.event_date, e.event_date_precision)}{e.is_historical ? " · past history" : ""}</span>
                  </span>
                  {e.status === "source_verified" && <span className="badge badge-ok">source verified</span>}
                </li>
              ))}
            </ul>
          )}
        </Card>
      )}
    </>
  );
}
