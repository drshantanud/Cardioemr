// How medicines read on screen and on a prescription.
import type { EncounterMedEvent, MedEvent, MedicationCourse } from "./types";

export const FREQUENCIES: [string, string][] = [
  ["OD", "Once daily"], ["BD", "Twice daily"], ["TDS", "Three times daily"], ["QID", "Four times daily"],
  ["HS", "At bedtime"], ["weekly", "Once a week"], ["Q2W", "Every 2 weeks"], ["Q4W", "Every 4 weeks"],
  ["Q6M", "Every 6 months"], ["SOS", "When needed (SOS)"], ["other", "Other"],
];
export const DOSE_UNITS = ["tablet", "capsule", "mg", "mcg", "ml", "unit", "puff", "sachet", "injection"] as const;
export const ROUTES = ["oral", "sublingual", "iv", "sc", "im", "inhaled", "transdermal", "topical", "other"] as const;

const EVENT_LABELS: Record<string, string> = {
  initiate: "Started", increase: "Dose increased", decrease: "Dose reduced", change_frequency: "Frequency changed",
  switch_product: "Product changed", hold: "Held", resume: "Resumed", discontinue: "Stopped",
  reconcile_continue: "Continued", record_external: "Recorded (from elsewhere)", void: "Entry voided",
};

export function eventLabel(type: string): string {
  return EVENT_LABELS[type] ?? type.replace(/_/g, " ");
}

function num(n: number | null | undefined): string {
  if (n === null || n === undefined) return "";
  return Number(n).toLocaleString("en-IN", { maximumFractionDigits: 3 });
}

function plural(unit: string, qty: number): string {
  if (["mg", "mcg", "ml"].includes(unit)) return unit;
  return qty === 1 ? unit : `${unit}s`;
}

/** "49/51 mg · 1 tablet BD" */
export function doseLine(e: Pick<MedEvent, "strength_label" | "dose_quantity" | "dose_unit" | "frequency_code" | "route">
  | null | undefined): string {
  if (!e || e.dose_quantity === null || e.dose_quantity === undefined) return "";
  const qty = Number(e.dose_quantity);
  const amount = `${num(qty)} ${plural(e.dose_unit ?? "", qty)}`.trim();
  const unitIsStrength = e.dose_unit === "mg" || e.dose_unit === "mcg";
  const main = [unitIsStrength ? null : e.strength_label, amount].filter(Boolean).join(" · ");
  const route = e.route && e.route !== "oral" ? ` (${e.route})` : "";
  return `${main}${e.frequency_code ? ` ${e.frequency_code}` : ""}${route}`;
}

export function dailyDose(daily: number | null | undefined, unit: string): string {
  if (daily === null || daily === undefined) return "";
  return `${num(Number(daily))} ${unit}/day`;
}

/** "49/51 mg · 1 tablet BD = 200 mg/day"; just the daily dose when only that was recorded. */
export function courseLine(c: Pick<MedicationCourse, "current_dose" | "reference_unit">): string {
  const dose = doseLine(c.current_dose);
  const daily = c.current_dose?.daily_dose ? dailyDose(c.current_dose.daily_dose, c.reference_unit) : "";
  return dose && daily ? `${dose} = ${daily}` : dose || daily;
}

export function encounterEventLine(e: EncounterMedEvent): string {
  return `${eventLabel(e.event_type)}: ${e.generic_name}${doseLine(e) ? ` ${doseLine(e)}` : ""}`;
}
