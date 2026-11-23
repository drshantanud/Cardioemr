"use client";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { navFor, roleLabel } from "@/lib/roles";
import { useSession } from "@/lib/session";

export function AppShell({ children }: { children: ReactNode }) {
  const { me, membership, selection, signOut, changeCentre } = useSession();
  const pathname = usePathname();
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const nav = navFor(selection?.role);

  useEffect(() => setOpen(false), [pathname]);

  const switchCentre = () => {
    changeCentre();
    router.push(`/select-centre?returnTo=${encodeURIComponent(pathname)}`);
  };

  const context = membership && selection && (
    <button type="button" className="context-chip" onClick={switchCentre} title="Change centre or role">
      <strong>{membership.centre_name}</strong>
      <span>{roleLabel(selection.role)} · change</span>
    </button>
  );
  const links = nav.map((n) => (
    <Link key={n.href} href={n.href} aria-current={pathname.startsWith(n.href) ? "page" : undefined}>
      {n.label}
    </Link>
  ));

  return (
    <>
      <header className="shell-header">
        <Link href="/" className="brand">
          <span className="brand-mark" aria-hidden>♥</span> CardioEMR
        </Link>
        <nav className="shell-nav" aria-label="Main">{links}</nav>
        <div className="shell-right">
          {context}
          <span className="user-name">{me?.full_name}</span>
          <button type="button" className="btn btn-sm" onClick={() => void signOut()}>Sign out</button>
        </div>
        <button type="button" className="btn btn-ghost menu-button" aria-expanded={open} aria-controls="mobile-menu"
          onClick={() => setOpen((o) => !o)}>
          {open ? "Close" : "Menu"}
        </button>
      </header>
      <div id="mobile-menu" className="mobile-drawer" data-open={open}>
        <nav aria-label="Main (mobile)" style={{ display: "contents" }}>{links}</nav>
        {context}
        <div className="row" style={{ justifyContent: "space-between", marginTop: 8 }}>
          <span className="muted small">{me?.full_name}</span>
          <button type="button" className="btn btn-sm" onClick={() => void signOut()}>Sign out</button>
        </div>
      </div>
      <main className="page">{children}</main>
    </>
  );
}
