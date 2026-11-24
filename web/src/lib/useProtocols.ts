"use client";
import { useEffect, useState } from "react";
import { ApiError } from "./api";
import { useSession } from "./session";
import type { Registry } from "./types";

export interface ProtocolChoice { protocol_id: string; protocol_code: string; label: string; registry_code: string }

const KEY = "cemr.protocol";

/** Registry protocols for a picker, remembering the last one chosen on this device. */
export function useProtocols() {
  const { api } = useSession();
  const [protocols, setProtocols] = useState<ProtocolChoice[] | null>(null);
  const [protocolId, setProtocolIdState] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api<{ items: Registry[] }>("/registries").then((r) => {
      const list = r.data.items.flatMap((g) => g.protocols.map((p) => ({
        protocol_id: p.protocol_id, protocol_code: p.protocol_code, registry_code: g.registry_code,
        label: `${p.protocol_code} v${p.protocol_version} · ${g.registry_name}`,
      })));
      setProtocols(list);
      let saved = "";
      try { saved = localStorage.getItem(KEY) ?? ""; } catch { /* storage unavailable */ }
      setProtocolIdState((cur) => cur || (list.some((p) => p.protocol_id === saved) ? saved : list[0]?.protocol_id ?? ""));
    }).catch((e) => setError(e instanceof ApiError ? e.userMessage : "Could not load the registries"));
  }, [api]);

  const setProtocolId = (id: string) => {
    setProtocolIdState(id);
    try { localStorage.setItem(KEY, id); } catch { /* storage unavailable */ }
  };
  return { protocols, protocolId, setProtocolId, error };
}
