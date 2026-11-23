import type { ReactNode } from "react";

export function Loading({ label = "Loading…" }: { label?: string }) {
  return (
    <div className="loading" role="status">
      <span className="spinner" aria-hidden /> {label}
    </div>
  );
}

export function ErrorBanner({ message, action }: { message: string; action?: ReactNode }) {
  return (
    <div className="banner banner-error" role="alert">
      <div style={{ flex: 1 }}>{message}</div>
      {action}
    </div>
  );
}

export function Card({ title, actions, children, flush }: { title?: ReactNode; actions?: ReactNode; children: ReactNode; flush?: boolean }) {
  return (
    <section className="card">
      {(title || actions) && (
        <div className="card-head">
          {title && <h2>{title}</h2>}
          {actions}
        </div>
      )}
      <div className={`card-body${flush ? " flush" : ""}`}>{children}</div>
    </section>
  );
}

export function Field({
  label, htmlFor, required, hint, error, className, children,
}: {
  label: string; htmlFor: string; required?: boolean; hint?: string; error?: string; className?: string; children: ReactNode;
}) {
  return (
    <div className={`field ${className ?? ""}`}>
      <label htmlFor={htmlFor}>
        {label}
        {required && <span className="req" aria-hidden>*</span>}
      </label>
      {children}
      {error ? <span className="err" id={`${htmlFor}-err`}>{error}</span> : hint ? <span className="hint">{hint}</span> : null}
    </div>
  );
}

export function SearchIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
      <circle cx="11" cy="11" r="7" />
      <path d="m20 20-3.5-3.5" />
    </svg>
  );
}

export function StatusBadge({ status }: { status: string }) {
  const tone: Record<string, string> = {
    active: "badge-ok", enrolled: "badge-ok", signed: "badge-ok", eligible: "badge-ok",
    draft: "badge-warn", screening: "badge-info", pending_review: "badge-warn", open: "badge-info",
    withdrawn: "badge-danger", refused: "badge-danger", deceased: "badge-danger", ineligible: "badge-danger",
    entered_in_error: "badge-danger", expired: "badge-warn",
  };
  return <span className={`badge ${tone[status] ?? ""}`}>{status.replace(/_/g, " ")}</span>;
}
