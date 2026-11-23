// Which centre and role the user is acting as.  Kept per browser tab
// (sessionStorage), and always checked against the user's current memberships.
import type { Me, Membership } from "./types";

export interface Selection {
  centreId: string;
  role: string;
}

const KEY = "cemr.selection";

export function loadSelection(): Selection | null {
  try {
    const raw = window.sessionStorage.getItem(KEY);
    if (!raw) return null;
    const s = JSON.parse(raw) as Selection;
    return typeof s?.centreId === "string" && typeof s?.role === "string" ? s : null;
  } catch {
    return null;
  }
}

export function saveSelection(s: Selection | null): void {
  try {
    if (s) window.sessionStorage.setItem(KEY, JSON.stringify(s));
    else window.sessionStorage.removeItem(KEY);
  } catch {
    /* storage blocked: the user picks again next time */
  }
}

export function isValidSelection(me: Me, s: Selection | null): s is Selection {
  return !!s && me.centres.some((c) => c.centre_id === s.centreId && c.roles.includes(s.role));
}

/** The only possible choice, when there is exactly one centre with one role. */
export function onlyChoice(me: Me): Selection | null {
  if (me.centres.length !== 1 || me.centres[0].roles.length !== 1) return null;
  return { centreId: me.centres[0].centre_id, role: me.centres[0].roles[0] };
}

export function membershipFor(me: Me | null, s: Selection | null): Membership | null {
  if (!me || !s) return null;
  return me.centres.find((c) => c.centre_id === s.centreId) ?? null;
}
