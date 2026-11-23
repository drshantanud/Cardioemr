"use client";
import { usePathname, useRouter } from "next/navigation";
import { useEffect } from "react";
import type { ReactNode } from "react";
import { AppShell } from "@/components/AppShell";
import { ErrorBanner, Loading } from "@/components/ui";
import { useSession } from "@/lib/session";

/** Every page in this group needs a signed-in user acting at a chosen centre. */
export default function SignedInLayout({ children }: { children: ReactNode }) {
  const { status, error, signOut } = useSession();
  const router = useRouter();
  const pathname = usePathname();

  useEffect(() => {
    const here = encodeURIComponent(pathname + window.location.search);
    if (status === "signed_out") router.replace(`/login?returnTo=${here}`);
    if (status === "choose") router.replace(`/select-centre?returnTo=${here}`);
  }, [status, pathname, router]);

  if (status === "ready") return <AppShell>{children}</AppShell>;
  if (status === "no_account" || status === "error") {
    return (
      <div className="centre-page">
        <div className="centre-box stack">
          <ErrorBanner
            message={status === "no_account"
              ? "You signed in, but there is no active CardioEMR account for you. Ask your centre administrator to add you."
              : error ?? "Something went wrong."}
          />
          <div className="row">
            {status === "error" && <button className="btn" onClick={() => window.location.reload()}>Try again</button>}
            <button className="btn" onClick={() => void signOut()}>Sign out</button>
          </div>
        </div>
      </div>
    );
  }
  return (
    <div className="centre-page">
      <Loading />
    </div>
  );
}
