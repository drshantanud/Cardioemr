"use client";
// OpenID Connect sign-in with authorisation code + PKCE (public client, no
// secret in the browser).  Tokens live in sessionStorage: closing the tab
// ends the session on this device.
import { User, UserManager, WebStorageStateStore } from "oidc-client-ts";
import { oidcConfig } from "./config";

let manager: UserManager | null = null;

export function userManager(): UserManager {
  if (manager) return manager;
  const origin = window.location.origin;
  manager = new UserManager({
    authority: oidcConfig.authority,
    client_id: oidcConfig.clientId,
    redirect_uri: `${origin}/auth/callback`,
    post_logout_redirect_uri: `${origin}/signed-out`,
    response_type: "code",
    scope: oidcConfig.scope,
    extraQueryParams: oidcConfig.audience ? { audience: oidcConfig.audience } : undefined,
    userStore: new WebStorageStateStore({ store: window.sessionStorage }),
    automaticSilentRenew: true,
    loadUserInfo: false,
  });
  return manager;
}

export async function currentUser(): Promise<User | null> {
  const user = await userManager().getUser();
  return user && !user.expired ? user : null;
}

export async function signIn(returnTo = "/"): Promise<void> {
  await userManager().signinRedirect({ state: { returnTo } });
}

export async function completeSignIn(): Promise<string> {
  const user = await userManager().signinRedirectCallback();
  const state = user.state as { returnTo?: string } | undefined;
  return safeReturnTo(state?.returnTo);
}

export async function signOut(): Promise<void> {
  const um = userManager();
  const user = await um.getUser();
  await um.removeUser();
  try {
    await um.signoutRedirect({ id_token_hint: user?.id_token });
  } catch {
    window.location.assign("/signed-out");   // provider without an end-session endpoint
  }
}

/** Only same-origin paths, so a crafted link cannot bounce the user elsewhere. */
export function safeReturnTo(path: string | undefined | null): string {
  if (!path || !path.startsWith("/") || path.startsWith("//") || path.startsWith("/\\")) return "/";
  return path;
}
