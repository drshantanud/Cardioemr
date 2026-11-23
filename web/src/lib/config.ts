// Build-time settings.  NEXT_PUBLIC_* values are inlined into the browser
// bundle, so nothing secret belongs here (a public OIDC client has no secret).
export const oidcConfig = {
  authority: process.env.NEXT_PUBLIC_OIDC_AUTHORITY ?? "http://localhost:9400",
  clientId: process.env.NEXT_PUBLIC_OIDC_CLIENT_ID ?? "cardioemr-web",
  scope: process.env.NEXT_PUBLIC_OIDC_SCOPE ?? "openid profile email",
  // Some providers (e.g. Auth0) need the API audience on the authorise request.
  audience: process.env.NEXT_PUBLIC_OIDC_AUDIENCE ?? "",
};

export const API_BASE = "/api/v1";
