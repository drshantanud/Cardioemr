// Display formats.  Dates read as "14 Mar 1968" (day month year, as Indian
// clinical notes write them); times use the centre's time zone.
import type { DobPrecision, Sex } from "./types";

const DATE = new Intl.DateTimeFormat("en-IN", { day: "2-digit", month: "short", year: "numeric", timeZone: "UTC" });

/** A calendar date from the API (YYYY-MM-DD), shown without time-zone shifts. */
export function formatDate(iso: string | null | undefined): string {
  if (!iso) return "—";
  const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
  if (!y || !m || !d) return iso;
  return DATE.format(new Date(Date.UTC(y, m - 1, d)));
}

export function formatDateTime(iso: string | null | undefined, timeZone = "Asia/Kolkata"): string {
  if (!iso) return "—";
  const dt = new Date(iso);
  if (Number.isNaN(dt.getTime())) return iso;
  return new Intl.DateTimeFormat("en-IN", {
    day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", hour12: true, timeZone,
  }).format(dt);
}

export function formatDob(iso: string | null, precision: DobPrecision): string {
  if (!iso) return "—";
  if (precision === "estimated_from_age") return `about ${iso.slice(0, 4)} (from age)`;
  if (precision === "year") return iso.slice(0, 4);
  if (precision === "month") return formatDate(iso).replace(/^\d{2} /, "");
  return formatDate(iso);
}

const SEX_SHORT: Record<Sex, string> = { male: "M", female: "F", other: "O", unknown: "?" };
export const SEX_LABEL: Record<Sex, string> = { male: "Male", female: "Female", other: "Other", unknown: "Not known" };

export function ageSex(age: number | null, sex: Sex, estimated = false): string {
  const a = age === null ? "age ?" : `${estimated ? "~" : ""}${age} y`;
  return `${a} · ${SEX_SHORT[sex] ?? "?"}`;
}

/** 10-digit Indian mobiles as "98220 00001"; anything else unchanged. */
export function formatMobile(m: string | null | undefined): string {
  if (!m) return "—";
  const digits = m.replace(/\D/g, "");
  const local = digits.length === 12 && digits.startsWith("91") ? digits.slice(2) : digits;
  if (local.length === 10) return `${local.slice(0, 5)} ${local.slice(5)}`;
  return m;
}

export function humanise(code: string | null | undefined): string {
  if (!code) return "—";
  const s = code.replace(/_/g, " ");
  return s.charAt(0).toUpperCase() + s.slice(1);
}

export const STATES: [string, string][] = [
  ["AN", "Andaman and Nicobar Islands"], ["AP", "Andhra Pradesh"], ["AR", "Arunachal Pradesh"], ["AS", "Assam"],
  ["BR", "Bihar"], ["CH", "Chandigarh"], ["CT", "Chhattisgarh"], ["DD", "Daman and Diu"], ["DL", "Delhi"],
  ["DN", "Dadra and Nagar Haveli"], ["GA", "Goa"], ["GJ", "Gujarat"], ["HP", "Himachal Pradesh"], ["HR", "Haryana"],
  ["JH", "Jharkhand"], ["JK", "Jammu and Kashmir"], ["KA", "Karnataka"], ["KL", "Kerala"], ["LA", "Ladakh"],
  ["LD", "Lakshadweep"], ["MH", "Maharashtra"], ["ML", "Meghalaya"], ["MN", "Manipur"], ["MP", "Madhya Pradesh"],
  ["MZ", "Mizoram"], ["NL", "Nagaland"], ["OR", "Odisha"], ["PB", "Punjab"], ["PY", "Puducherry"],
  ["RJ", "Rajasthan"], ["SK", "Sikkim"], ["TG", "Telangana"], ["TN", "Tamil Nadu"], ["TR", "Tripura"],
  ["UP", "Uttar Pradesh"], ["UT", "Uttarakhand"], ["WB", "West Bengal"],
];

export function stateName(code: string | null | undefined): string {
  return STATES.find(([c]) => c === code)?.[1] ?? code ?? "—";
}

export const REFERRAL_SOURCES: [string, string][] = [
  ["self", "Self"], ["physician", "Physician"], ["cardiologist", "Cardiologist"], ["hospital", "Hospital"],
  ["camp", "Health camp"], ["insurer", "Insurer"], ["other", "Other"],
];
