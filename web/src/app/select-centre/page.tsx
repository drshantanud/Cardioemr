"use client";
import { useRouter, useSearchParams } from "next/navigation";
import { Suspense, useEffect } from "react";
import { ErrorBanner, Loading } from "@/components/ui";
import { safeReturnTo } from "@/lib/auth";
import { homeFor, roleLabel } from "@/lib/roles";
import { useSession } from "@/lib/session";

function Picker() {
  const { status, me, select, signOut } = useSession();
  const router = useRouter();
  const params = useSearchParams();
  const returnTo = params.get("returnTo");

  useEffect(() => {
    if (status === "signed_out") router.replace("/login");
  }, [status, router]);

  if (status === "loading" || !me) return <Loading />;
  const choose = (centreId: string, role: string) => {
    select({ centreId, role });
    const target = safeReturnTo(returnTo);
    router.replace(target === "/" || target.startsWith("/select-centre") ? homeFor(role) : target);
  };

  return (
    <div className="card">
      <div className="card-body stack">
        <div>
          <h1>Choose where you are working</h1>
          <p className="muted" style={{ margin: "6px 0 0" }}>
            Signed in as {me.full_name}. You see only the patients of the centre you choose.
          </p>
        </div>
        {me.centres.length === 0 && (
          <ErrorBanner message="You do not hold a role at any centre yet. Ask your centre administrator to add you." />
        )}
        {me.centres.map((c) => (
          <div key={c.centre_id} className="stack" style={{ gap: 8 }}>
            <div>
              <h2>{c.centre_name}</h2>
              <div className="small muted">{c.organisation_name} · {c.centre_code}</div>
            </div>
            {c.roles.map((r) => (
              <button key={r} type="button" className="choice" onClick={() => choose(c.centre_id, r)}>
                <span>{roleLabel(r)}</span>
                <span aria-hidden>→</span>
              </button>
            ))}
          </div>
        ))}
        <button type="button" className="btn btn-ghost" onClick={() => void signOut()}>Sign out</button>
      </div>
    </div>
  );
}

export default function SelectCentrePage() {
  return (
    <div className="centre-page">
      <div className="centre-box">
        <Suspense fallback={<Loading />}>
          <Picker />
        </Suspense>
      </div>
    </div>
  );
}
