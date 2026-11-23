"use client";
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { ApiError, call, type ApiResult, type CallOptions } from "./api";
import { currentUser, signIn, signOut, userManager } from "./auth";
import { isValidSelection, loadSelection, membershipFor, onlyChoice, saveSelection, type Selection } from "./selection";
import type { Me, Membership } from "./types";

export type SessionStatus = "loading" | "signed_out" | "no_account" | "choose" | "ready" | "error";

export interface Session {
  status: SessionStatus;
  me: Me | null;
  selection: Selection | null;
  membership: Membership | null;
  error: string | null;
  select(s: Selection): void;
  changeCentre(): void;
  signIn(returnTo?: string): Promise<void>;
  signOut(): Promise<void>;
  /** Calls the API as the selected centre and role. */
  api<T>(path: string, opts?: CallOptions): Promise<ApiResult<T>>;
}

const SessionContext = createContext<Session | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<SessionStatus>("loading");
  const [me, setMe] = useState<Me | null>(null);
  const [selection, setSelection] = useState<Selection | null>(null);
  const [error, setError] = useState<string | null>(null);
  const token = useRef<string | null>(null);

  const load = useCallback(async () => {
    const user = await currentUser();
    if (!user) {
      token.current = null;
      setStatus("signed_out");
      return;
    }
    token.current = user.access_token;
    try {
      const { data } = await call<Me>({ token: user.access_token }, "/me");
      setMe(data);
      const saved = loadSelection();
      const chosen = isValidSelection(data, saved) ? saved : onlyChoice(data);
      saveSelection(chosen);
      setSelection(chosen);
      setStatus(chosen ? "ready" : "choose");
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) {
        // A valid sign-in with no CardioEMR account is a different message from an expired token.
        const noAccount = e.title.startsWith("No active CardioEMR user");
        if (!noAccount) await userManager().removeUser();
        setStatus(noAccount ? "no_account" : "signed_out");
      } else {
        setError(e instanceof ApiError ? e.userMessage : "Could not load your account");
        setStatus("error");
      }
    }
  }, []);

  useEffect(() => {
    void load();
    const um = userManager();
    const onLoaded = (u: { access_token: string }) => {
      token.current = u.access_token;
    };
    const onExpired = () => {
      token.current = null;
      setStatus("signed_out");
    };
    um.events.addUserLoaded(onLoaded);
    um.events.addAccessTokenExpired(onExpired);
    um.events.addUserSignedOut(onExpired);
    return () => {
      um.events.removeUserLoaded(onLoaded);
      um.events.removeAccessTokenExpired(onExpired);
      um.events.removeUserSignedOut(onExpired);
    };
  }, [load]);

  const select = useCallback(
    (s: Selection) => {
      if (!me || !isValidSelection(me, s)) return;
      saveSelection(s);
      setSelection(s);
      setStatus("ready");
    },
    [me],
  );

  const changeCentre = useCallback(() => {
    saveSelection(null);
    setSelection(null);
    setStatus("choose");
  }, []);

  const api = useCallback(
    async <T,>(path: string, opts?: CallOptions): Promise<ApiResult<T>> => {
      if (!token.current) {
        setStatus("signed_out");
        throw new ApiError(401, "UNAUTHENTICATED", "Please sign in again");
      }
      try {
        return await call<T>({ token: token.current, centreId: selection?.centreId, role: selection?.role }, path, opts);
      } catch (e) {
        if (e instanceof ApiError && e.status === 401) setStatus("signed_out");
        if (e instanceof ApiError && e.code === "ROLE_NOT_HELD") void load();
        throw e;
      }
    },
    [selection, load],
  );

  const value = useMemo<Session>(
    () => ({
      status, me, selection, membership: membershipFor(me, selection), error, select, changeCentre, api,
      signIn: (returnTo?: string) => signIn(returnTo),
      signOut: async () => {
        saveSelection(null);
        await signOut();
      },
    }),
    [status, me, selection, error, select, changeCentre, api],
  );

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): Session {
  const s = useContext(SessionContext);
  if (!s) throw new Error("useSession outside SessionProvider");
  return s;
}
