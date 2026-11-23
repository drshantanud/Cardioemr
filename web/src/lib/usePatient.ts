"use client";
import { useCallback, useEffect, useState } from "react";
import { ApiError } from "./api";
import { useSession } from "./session";
import type { PatientOverview } from "./types";

export function usePatient(id: string) {
  const { api } = useSession();
  const [data, setData] = useState<PatientOverview | null>(null);
  const [etag, setEtag] = useState<string | null>(null);
  const [error, setError] = useState<ApiError | null>(null);

  const reload = useCallback(async () => {
    setError(null);
    try {
      const r = await api<PatientOverview>(`/patients/${encodeURIComponent(id)}`);
      setData(r.data);
      setEtag(r.etag);
    } catch (e) {
      setError(e instanceof ApiError ? e : new ApiError(0, "NETWORK", "Could not load the patient"));
    }
  }, [api, id]);

  useEffect(() => {
    void reload();
  }, [reload]);

  return { data, etag, error, reload };
}
