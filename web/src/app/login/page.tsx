"use client";
import { useRouter, useSearchParams } from "next/navigation";
import { Suspense, useEffect, useState } from "react";
import { ErrorBanner, Loading } from "@/components/ui";
import { safeReturnTo } from "@/lib/auth";
import { useSession } from "@/lib/session";

function Login() {
  const { status, signIn } = useSession();
  const params = useSearchParams();
  const router = useRouter();
  const returnTo = safeReturnTo(params.get("returnTo"));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (status === "ready" || status === "choose") router.replace(returnTo);
  }, [status, returnTo, router]);

  const go = async () => {
    setBusy(true);
    setError(null);
    try {
      await signIn(returnTo);
    } catch {
      setError("Could not reach the sign-in service. Check the connection and try again.");
      setBusy(false);
    }
  };

  if (status === "loading") return <Loading />;
  return (
    <div className="card">
      <div className="card-body stack">
        <div className="brand" style={{ fontSize: "1.25rem" }}>
          <span className="brand-mark" aria-hidden>♥</span> CardioEMR
        </div>
        <div>
          <h1>Sign in</h1>
          <p className="muted" style={{ margin: "6px 0 0" }}>
            Use your CardioEMR account. You will choose your centre and role next.
          </p>
        </div>
        {error && <ErrorBanner message={error} />}
        <button className="btn btn-primary" onClick={() => void go()} disabled={busy}>
          {busy ? "Opening sign-in…" : "Sign in"}
        </button>
        <p className="small muted" style={{ margin: 0 }}>
          Patient information is confidential. Every record you open is logged.
        </p>
      </div>
    </div>
  );
}

export default function LoginPage() {
  return (
    <div className="centre-page">
      <div className="centre-box">
        <Suspense fallback={<Loading />}>
          <Login />
        </Suspense>
      </div>
    </div>
  );
}
