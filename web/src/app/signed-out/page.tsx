export default function SignedOut() {
  return (
    <div className="centre-page">
      <div className="centre-box card">
        <div className="card-body stack">
          <h1>You have signed out</h1>
          <p className="muted" style={{ margin: 0 }}>Close this tab on a shared computer.</p>
          <a className="btn btn-primary" href="/login">Sign in again</a>
        </div>
      </div>
    </div>
  );
}
