"use client";
import { useEffect, useState } from "react";
import { ErrorBanner, Loading } from "@/components/ui";
import { completeSignIn } from "@/lib/auth";

// The code can be exchanged once; React may run effects twice in development.
let pending: Promise<string> | null = null;

export default function Callback() {
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    pending ??= completeSignIn();
    pending
      .then((returnTo) => window.location.replace(returnTo))   // full load so the session starts fresh
      .catch(() => setError("Sign-in did not complete. Please try again."));
  }, []);
  return (
    <div className="centre-page">
      <div className="centre-box">
        {error ? (
          <div className="stack">
            <ErrorBanner message={error} />
            <a className="btn" href="/login">Back to sign in</a>
          </div>
        ) : (
          <Loading label="Signing you in…" />
        )}
      </div>
    </div>
  );
}
