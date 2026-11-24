// Export requests: labels and the request body built from the form.
import type { ExportJob } from "./types";

export const DEIDENTIFICATION: [ExportJob["deidentification"], string, string][] = [
  ["pseudonymised_relative_days", "Pseudonymised, days from enrolment",
    "Rows by study code. Dates become days from enrolment; no names, contact details, patient IDs or exact dates. Ages over 89 are written as 90."],
  ["pseudonymised_year_only", "Pseudonymised, year only",
    "As above, but date variables are kept only as the calendar year."],
  ["aggregate_only", "Counts only",
    "Counts and summaries only, no row per patient. Counts under 5 are shown as <5."],
];

export const FORMATS: [ExportJob["file_format"], string][] = [
  ["csv", "CSV tables (.zip)"], ["xlsx", "Excel workbook (.xlsx)"], ["stata_csv", "CSV for Stata (.zip)"], ["r_csv", "CSV for R (.zip)"],
  ["spss_csv", "CSV with SPSS labels (.zip)"],
];

export const ENROLMENT_STATUSES: [string, string][] = [
  ["enrolled", "Enrolled"], ["completed", "Completed"], ["withdrawn", "Withdrawn"], ["lost_to_follow_up", "Lost to follow-up"],
  ["deceased", "Deceased"],
];

export const EXPORT_STATUS: Record<ExportJob["status"], [string, string]> = {
  requested: ["Waiting for approval", "badge-warn"], approved: ["Approved, preparing", "badge-info"],
  running: ["Preparing", "badge-info"], completed: ["Ready", "badge-ok"], rejected: ["Rejected", "badge-danger"],
  failed: ["Failed", "badge-danger"], expired: ["Expired", ""],
};

export interface ExportDraft {
  protocol_id: string; purpose: string; deidentification: ExportJob["deidentification"]; file_format: ExportJob["file_format"];
  include_data_dictionary: boolean; visit_codes: string[]; variable_codes: string[]; enrolment_status: string[];
  index_year_from: string; index_year_to: string;
}

export function newExport(protocolId: string): ExportDraft {
  return {
    protocol_id: protocolId, purpose: "", deidentification: "pseudonymised_relative_days", file_format: "csv",
    include_data_dictionary: true, visit_codes: [], variable_codes: [], enrolment_status: [], index_year_from: "", index_year_to: "",
  };
}

export function validateExport(d: ExportDraft): Record<string, string> {
  const e: Record<string, string> = {};
  if (!d.protocol_id) e.protocol_id = "Choose the protocol";
  if (d.purpose.trim().length < 10) e.purpose = "Say what the data is for, in at least 10 characters";
  if (d.variable_codes.length === 0) e.variable_codes = "Choose at least one variable";
  for (const k of ["index_year_from", "index_year_to"] as const) {
    if (d[k] && !/^(20\d\d|2100)$/.test(d[k])) e[k] = "A year from 2000";
  }
  if (d.index_year_from && d.index_year_to && d.index_year_from > d.index_year_to) e.index_year_to = "Before the start year";
  return e;
}

export function exportBody(d: ExportDraft): Record<string, unknown> {
  const cohort: Record<string, unknown> = {};
  if (d.enrolment_status.length) cohort.enrolment_status = d.enrolment_status;
  if (d.index_year_from) cohort.index_year_from = Number(d.index_year_from);
  if (d.index_year_to) cohort.index_year_to = Number(d.index_year_to);
  return {
    protocol_id: d.protocol_id, purpose: d.purpose.trim(), deidentification: d.deidentification, file_format: d.file_format,
    include_data_dictionary: d.include_data_dictionary, visit_codes: d.visit_codes.length ? d.visit_codes : null,
    variable_codes: d.variable_codes, cohort_filter: cohort,
  };
}

/** Group dictionary variables by category, each variable once (the dictionary lists one row per visit). */
export function byCategory<T extends { variable_code: string; category: string | null }>(items: T[]): [string, T[]][] {
  const seen = new Set<string>();
  const groups = new Map<string, T[]>();
  for (const i of items) {
    if (seen.has(i.variable_code)) continue;
    seen.add(i.variable_code);
    const k = i.category ?? "Other";
    groups.set(k, [...(groups.get(k) ?? []), i]);
  }
  return [...groups.entries()];
}

/** Hands a downloaded file to the browser to save. */
export function saveBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}
