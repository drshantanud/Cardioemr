// Acting roles, as the API names them (X-Acting-Role).  What each role may do
// is decided by the API and the database; this file only decides what the
// app shows, so a hidden button is never the only lock.

export type Role =
  | "assistant"
  | "nurse"
  | "clinician"
  | "research_coordinator"
  | "principal_investigator"
  | "centre_admin";

export const ROLE_LABELS: Record<Role, string> = {
  assistant: "Clinic assistant",
  nurse: "Nurse",
  clinician: "Cardiologist",
  research_coordinator: "Research coordinator",
  principal_investigator: "Principal investigator",
  centre_admin: "Centre administrator",
};

export function roleLabel(role: string): string {
  return ROLE_LABELS[role as Role] ?? role.replace(/_/g, " ");
}

const FRONT_DESK: Role[] = ["assistant", "nurse", "clinician", "research_coordinator", "principal_investigator"];
const REGISTRY: Role[] = ["clinician", "research_coordinator", "principal_investigator"];

export type Capability =
  | "patients.read" | "patients.register" | "patients.edit" | "registry.read"
  | "consult.start" | "consult.edit" | "consult.sign" | "meds.prescribe" | "vitals.record" | "diagnosis.write"
  | "allergy.write";

const CAPABILITIES: Record<Capability, Role[]> = {
  "patients.read": FRONT_DESK,
  "patients.register": FRONT_DESK,
  "patients.edit": FRONT_DESK,
  "registry.read": REGISTRY,
  "consult.start": ["clinician"],
  "consult.edit": ["clinician", "nurse"],
  "consult.sign": ["clinician"],
  "meds.prescribe": ["clinician"],
  "vitals.record": ["assistant", "nurse", "clinician"],
  "diagnosis.write": ["clinician", "nurse"],
  "allergy.write": ["assistant", "nurse", "clinician"],
};

export function can(role: string | undefined, capability: Capability): boolean {
  return !!role && CAPABILITIES[capability].includes(role as Role);
}

export interface NavItem {
  href: string;
  label: string;
  capability: Capability;
}

// Grows as each part of the app lands (consultations, registries, reports, exports).
export const NAV: NavItem[] = [{ href: "/patients", label: "Patients", capability: "patients.read" }];

export function navFor(role: string | undefined): NavItem[] {
  return NAV.filter((n) => can(role, n.capability));
}

/** Where to land after choosing a centre and role. */
export function homeFor(role: string | undefined): string {
  return navFor(role)[0]?.href ?? "/no-access";
}
