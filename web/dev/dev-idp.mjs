// A sign-in server for local development and tests ONLY.  It speaks just
// enough OpenID Connect (discovery, JWKS, authorisation code + PKCE, token,
// end session) for the web app and the API, and lets you pick one of the test
// users from backend/tests/fixtures.sql.  It has no passwords: never expose it.
//
//   node dev/dev-idp.mjs            (http://localhost:9400)
//   DEV_IDP_PORT=9400 DEV_IDP_AUDIENCE=cardioemr-api
import { createHash, randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { SignJWT, exportJWK, generateKeyPair } from "jose";

const PORT = Number(process.env.DEV_IDP_PORT ?? 9400);
const ISSUER = (process.env.DEV_IDP_ISSUER ?? `http://localhost:${PORT}`).replace(/\/$/, "") + "/";
const AUDIENCE = process.env.DEV_IDP_AUDIENCE ?? "cardioemr-api";
const TOKEN_MINUTES = Number(process.env.DEV_IDP_TOKEN_MINUTES ?? 60);
const HOST = process.env.DEV_IDP_HOST ?? "127.0.0.1";

// Subjects match iam.users.auth_subject in backend/tests/fixtures.sql.
const USERS = [
  { sub: "sub-dra", name: "Dr A", email: "dra@example.org", note: "Cardiologist, Pune Main" },
  { sub: "sub-asa", name: "Assistant A", email: "asa@example.org", note: "Clinic assistant, Pune Main" },
  { sub: "sub-nua", name: "Nurse A", email: "nua@example.org", note: "Nurse, Pune Main" },
  { sub: "sub-rca", name: "Coordinator A", email: "rca@example.org", note: "Research coordinator, Pune Main" },
  { sub: "sub-pia", name: "PI A", email: "pia@example.org", note: "Principal investigator, Pune Main" },
  { sub: "sub-drb", name: "Dr B", email: "drb@example.org", note: "Cardiologist, Mumbai Cardiology" },
  { sub: "sub-nobody", name: "No account", email: "nobody@example.org", note: "Signs in, but has no CardioEMR user" },
];

const { publicKey, privateKey } = await generateKeyPair("RS256");
const jwk = { ...(await exportJWK(publicKey)), kid: "dev-1", alg: "RS256", use: "sig" };
const codes = new Map();   // code -> { sub, clientId, redirectUri, challenge, nonce, expires }

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const b64url = (buf) => buf.toString("base64url");

function send(res, status, body, type = "application/json") {
  res.writeHead(status, {
    "Content-Type": type,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Cache-Control": "no-store",
  });
  res.end(typeof body === "string" ? body : JSON.stringify(body));
}

async function readForm(req) {
  let raw = "";
  for await (const chunk of req) raw += chunk;
  return new URLSearchParams(raw);
}

async function signAccess(user, clientId) {
  return new SignJWT({ scope: "openid profile email", client_id: clientId })
    .setProtectedHeader({ alg: "RS256", kid: jwk.kid, typ: "at+jwt" })
    .setIssuer(ISSUER).setAudience(AUDIENCE).setSubject(user.sub)
    .setIssuedAt().setExpirationTime(`${TOKEN_MINUTES}m`).setJti(b64url(randomBytes(12)))
    .sign(privateKey);
}

async function signId(user, clientId, nonce) {
  return new SignJWT({ name: user.name, email: user.email, ...(nonce ? { nonce } : {}) })
    .setProtectedHeader({ alg: "RS256", kid: jwk.kid })
    .setIssuer(ISSUER).setAudience(clientId).setSubject(user.sub)
    .setIssuedAt().setExpirationTime(`${TOKEN_MINUTES}m`)
    .sign(privateKey);
}

function pickerPage(params) {
  const hidden = ["client_id", "redirect_uri", "state", "code_challenge", "code_challenge_method", "nonce"]
    .map((k) => `<input type="hidden" name="${k}" value="${esc(params.get(k) ?? "")}">`).join("");
  const buttons = USERS.map((u) => `<button name="sub" value="${esc(u.sub)}"><b>${esc(u.name)}</b><span>${esc(u.note)}</span></button>`).join("");
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Dev sign-in</title><style>
body{font-family:system-ui,sans-serif;background:#f5f7fa;margin:0;display:grid;place-items:center;min-height:100vh;padding:16px}
main{background:#fff;border:1px solid #d9dfe7;border-radius:10px;padding:24px;max-width:420px;width:100%}
h1{font-size:1.2rem;margin:0 0 4px}p{color:#586579;margin:0 0 16px;font-size:.9rem}
button{display:flex;flex-direction:column;align-items:flex-start;width:100%;margin:0 0 8px;padding:10px 12px;border:1px solid #d9dfe7;
border-radius:8px;background:#fff;font:inherit;cursor:pointer;text-align:left}button:hover{border-color:#0b5c8e;background:#e6f0f7}
span{color:#586579;font-size:.85rem}.warn{background:#fff4e5;color:#6a3500;padding:8px 10px;border-radius:6px;font-size:.85rem}
</style></head><body><main><h1>Development sign-in</h1><p>Local testing only. Choose a test user.</p>
<form method="post" action="/authorize">${hidden}${buttons}</form><div class="warn">Not for real patient data.</div></main></body></html>`;
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", ISSUER);
  try {
    if (req.method === "OPTIONS") return send(res, 204, "");
    if (url.pathname === "/.well-known/openid-configuration") {
      return send(res, 200, {
        issuer: ISSUER,
        authorization_endpoint: `${ISSUER}authorize`,
        token_endpoint: `${ISSUER}token`,
        jwks_uri: `${ISSUER}jwks`,
        end_session_endpoint: `${ISSUER}logout`,
        response_types_supported: ["code"],
        grant_types_supported: ["authorization_code"],
        code_challenge_methods_supported: ["S256"],
        subject_types_supported: ["public"],
        id_token_signing_alg_values_supported: ["RS256"],
        scopes_supported: ["openid", "profile", "email"],
        token_endpoint_auth_methods_supported: ["none"],
      });
    }
    if (url.pathname === "/jwks") return send(res, 200, { keys: [jwk] });
    if (url.pathname === "/authorize" && req.method === "GET") {
      if (url.searchParams.get("response_type") !== "code" || url.searchParams.get("code_challenge_method") !== "S256") {
        return send(res, 400, "authorisation code with PKCE S256 only", "text/plain");
      }
      return send(res, 200, pickerPage(url.searchParams), "text/html; charset=utf-8");
    }
    if (url.pathname === "/authorize" && req.method === "POST") {
      const f = await readForm(req);
      const user = USERS.find((u) => u.sub === f.get("sub"));
      const redirectUri = f.get("redirect_uri") ?? "";
      if (!user || !/^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?\//.test(redirectUri)) {
        return send(res, 400, "unknown user or non-local redirect_uri", "text/plain");
      }
      const code = b64url(randomBytes(24));
      codes.set(code, { sub: user.sub, clientId: f.get("client_id"), redirectUri, challenge: f.get("code_challenge"),
        nonce: f.get("nonce") || null, expires: Date.now() + 60_000 });
      const to = new URL(redirectUri);
      to.searchParams.set("code", code);
      if (f.get("state")) to.searchParams.set("state", f.get("state"));
      res.writeHead(302, { Location: to.toString() });
      return res.end();
    }
    if (url.pathname === "/token" && req.method === "POST") {
      const f = await readForm(req);
      const entry = codes.get(f.get("code") ?? "");
      codes.delete(f.get("code") ?? "");
      const verifier = f.get("code_verifier") ?? "";
      const ok = entry && entry.expires > Date.now() && f.get("grant_type") === "authorization_code"
        && entry.redirectUri === f.get("redirect_uri") && entry.clientId === f.get("client_id")
        && b64url(createHash("sha256").update(verifier).digest()) === entry.challenge;
      if (!ok) return send(res, 400, { error: "invalid_grant" });
      const user = USERS.find((u) => u.sub === entry.sub);
      return send(res, 200, {
        access_token: await signAccess(user, entry.clientId),
        id_token: await signId(user, entry.clientId, entry.nonce),
        token_type: "Bearer",
        expires_in: TOKEN_MINUTES * 60,
        scope: "openid profile email",
      });
    }
    if (url.pathname === "/logout") {
      const back = url.searchParams.get("post_logout_redirect_uri");
      if (back && /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?\//.test(back)) {
        res.writeHead(302, { Location: back });
        return res.end();
      }
      return send(res, 200, "Signed out", "text/plain");
    }
    return send(res, 404, { error: "not_found" });
  } catch (e) {
    console.error(e);
    return send(res, 500, { error: "server_error" });
  }
});

server.listen(PORT, HOST, () => console.log(`dev sign-in server on ${ISSUER} (audience ${AUDIENCE})`));
