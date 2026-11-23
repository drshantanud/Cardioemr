"""Builds the file for an approved research export.

Reads only the pseudonymised research views (migration 0006), running with
the requester's own study access, and writes one file:
  * csv, r_csv, stata_csv, spss_csv: a zip of CSV tables, the data dictionary,
    manifest.json and, for SPSS, a labels.sps syntax file;
  * xlsx: one workbook with a sheet per table.

Tables (subject-level modes): subjects, visits (one row per subject visit,
one column per requested variable), events, endpoints (time to first event).
aggregate_only replaces them with counts and summaries, with cells under
SMALL_CELL shown as '<5'.

De-identification: no names, contacts, local codes or exact dates.  Visit
and event times are days from the index date.  Date variables become days
from index (pseudonymised_relative_days) or the calendar year
(pseudonymised_year_only).  Ages over 89 are written as 90."""
from __future__ import annotations

import csv
import hashlib
import io
import json
import re
import statistics
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Callable

SMALL_CELL = 5          # aggregate cells below this are suppressed
AGE_TOP_CODE = 90       # ages above 89 written as 90
MISSING_DEFAULT = {"not_done": -97, "unknown": -98, "not_applicable": -99, "declined": -96, "missing": ""}


class ExportError(Exception):
    """A reason the export cannot be produced, shown to the requester."""


@dataclass
class ExportData:
    protocol: dict
    centres: list[dict]
    dictionary: list[dict]
    subjects: list[dict]
    visits: list[dict]
    values: list[dict]
    events: list[dict]
    endpoints: list[dict]
    notes: list[str] = field(default_factory=list)


def collect(all_rows: Callable[[str, Any], list[dict]], one_row: Callable[[str, Any], dict | None],
            job: dict) -> ExportData:
    """Runs as the requester (SET ROLE r_<requested_role>, app.user_id = requested_by)."""
    allowed = one_row("SELECT app.study_centres(%s) AS c", (job["protocol_id"],))["c"]
    if not allowed:
        raise ExportError("The requester no longer has study access to this protocol")
    centres = [c for c in (job["centre_ids"] or allowed) if c in allowed]
    if not centres:
        raise ExportError("None of the requested centres is in the requester's study access")
    protocol = one_row("SELECT protocol_id, protocol_code, protocol_version, protocol_title "
                       "FROM registry.registry_protocols WHERE protocol_id = %s", (job["protocol_id"],))
    f = job["cohort_filter"] or {}
    subjects = all_rows("""
        SELECT * FROM research.v_subjects
         WHERE protocol_id = %s AND centre_id = ANY(%s)
           AND (%s::text[] IS NULL OR enrolment_status = ANY(%s))
           AND (%s::int IS NULL OR index_year >= %s) AND (%s::int IS NULL OR index_year <= %s)
         ORDER BY study_subject_code""",
        (job["protocol_id"], centres, f.get("enrolment_status"), f.get("enrolment_status"),
         f.get("index_year_from"), f.get("index_year_from"), f.get("index_year_to"), f.get("index_year_to")))
    codes = [s["study_subject_code"] for s in subjects]
    visit_codes = job["visit_codes"]
    visits = all_rows("""
        SELECT * FROM research.v_assessments
         WHERE protocol_id = %s AND study_subject_code = ANY(%s) AND (%s::text[] IS NULL OR visit_code = ANY(%s))
         ORDER BY study_subject_code, days_from_index, visit_code, visit_seq""",
        (job["protocol_id"], codes, visit_codes, visit_codes))
    values = all_rows("""
        SELECT * FROM research.v_variable_values
         WHERE protocol_id = %s AND study_subject_code = ANY(%s) AND variable_code = ANY(%s)
           AND (%s::text[] IS NULL OR visit_code = ANY(%s))""",
        (job["protocol_id"], codes, job["variable_codes"], visit_codes, visit_codes))
    dictionary = all_rows("""
        SELECT DISTINCT ON (d.variable_code) d.variable_code, d.variable_label, d.category, d.data_type, d.unit,
               d.allowed_values, d.definition_version, min(pv.sort_order) OVER (PARTITION BY d.variable_code) AS sort_order
          FROM registry.protocol_variables pv JOIN registry.variable_definitions d USING (variable_id)
         WHERE pv.protocol_id = %s AND d.variable_code = ANY(%s)
         ORDER BY d.variable_code, d.definition_version DESC""", (job["protocol_id"], job["variable_codes"]))
    dictionary.sort(key=lambda d: (d["sort_order"], d["variable_code"]))
    events = all_rows("""
        SELECT study_subject_code, event_type, event_day, before_index, hospitalised, length_of_stay_days, death_cause,
               death_cv_mode, mi_type, stroke_type, severity, outcome, source, endpoint_code, adjudication_status,
               classification, meets_endpoint
          FROM research.v_events WHERE protocol_code = %s AND study_subject_code = ANY(%s)
         ORDER BY study_subject_code, event_day, event_type, endpoint_code""", (protocol["protocol_code"], codes))
    endpoints = all_rows("""
        SELECT study_subject_code, endpoint_code, endpoint_kind, is_primary, had_event, time_days, last_follow_up_day,
               pending_adjudications
          FROM research.v_time_to_first_event WHERE protocol_id = %s AND study_subject_code = ANY(%s)
         ORDER BY study_subject_code, endpoint_code""", (job["protocol_id"], codes))
    centre_rows = all_rows("SELECT DISTINCT centre_code FROM research.v_subjects WHERE protocol_id = %s "
                           "AND centre_id = ANY(%s) ORDER BY 1", (job["protocol_id"], centres))
    return ExportData(protocol, centre_rows, dictionary, subjects, visits, values, events, endpoints)


# --- formatting ---------------------------------------------------------------

class Style:
    """Per-format conventions: what an empty cell looks like, booleans, column names."""

    def __init__(self, fmt: str):
        self.fmt = fmt
        self.empty = {"r_csv": "NA", "stata_csv": "."}.get(fmt, "")
        self.true, self.false = ("TRUE", "FALSE") if fmt == "r_csv" else (1, 0)
        self._names: dict[str, str] = {}

    def name(self, col: str) -> str:
        if self.fmt != "stata_csv":
            return col
        if col not in self._names:
            base = re.sub(r"[^A-Za-z0-9_]", "_", col)[:32]
            n, out = 1, base
            while out in self._names.values():
                n += 1
                out = f"{base[:32 - len(str(n)) - 1]}_{n}"
            self._names[col] = out
        return self._names[col]

    def cell(self, v: Any) -> Any:
        if v is None or v == "":
            return self.empty
        if isinstance(v, bool):
            return self.true if v else self.false
        if isinstance(v, Decimal):
            return int(v) if v == v.to_integral_value() else float(v)
        if isinstance(v, list):
            return ";".join(str(x) for x in v)
        return v


def _value(row: dict | None, data_type: str, deid: str, missing: dict) -> Any:
    if row is None:
        return missing.get("missing", "")
    if row["value_status"] != "present":
        return missing.get(row["value_status"], missing.get("missing", ""))
    if data_type in ("numeric", "integer"):
        v = row["numeric_value"]
        return int(v) if data_type == "integer" and v is not None else v
    if data_type == "date":
        return row["date_year"] if deid == "pseudonymised_year_only" else row["date_day"]
    if data_type == "boolean":
        return row["boolean_value"]
    if data_type == "coded":
        return row["coded_value"]
    if data_type == "multi_coded":
        return row["coded_values"]
    return row["text_value"]


def _top_code(age):
    return None if age is None else min(int(age), AGE_TOP_CODE)


def subject_level_tables(job: dict, d: ExportData) -> dict[str, tuple[list[str], list[list]]]:
    missing = {**MISSING_DEFAULT, **(job["missing_value_codes"] or {})}
    deid = job["deidentification"]
    subj_cols = ["study_subject_code", "centre_code", "sex", "age_at_index", "index_year", "enrolment_day",
                 "enrolment_status", "status_change_day"]
    subjects = [[s["study_subject_code"], s["centre_code"], s["sex"], _top_code(s["age_at_index"]), s["index_year"],
                 s["enrolment_day"], s["enrolment_status"], s["status_change_day"]] for s in d.subjects]
    by_key: dict[tuple, dict[str, dict]] = {}
    for v in d.values:
        by_key.setdefault((v["study_subject_code"], v["visit_code"], v["visit_seq"]), {})[v["variable_code"]] = v
    var_cols = [x["variable_code"] for x in d.dictionary]
    types = {x["variable_code"]: x["data_type"] for x in d.dictionary}
    visit_cols = ["study_subject_code", "visit_code", "visit_seq", "days_from_index", "within_window",
                  "completion_status", "locked", *var_cols]
    visits = []
    for a in d.visits:
        vals = by_key.get((a["study_subject_code"], a["visit_code"], a["visit_seq"]), {})
        visits.append([a["study_subject_code"], a["visit_code"], a["visit_seq"], a["days_from_index"],
                       a["within_window"], a["completion_status"], a["locked"],
                       *[_value(vals.get(c), types[c], deid, missing) for c in var_cols]])
    ev_cols = list(d.events[0].keys()) if d.events else [
        "study_subject_code", "event_type", "event_day", "before_index", "hospitalised", "length_of_stay_days",
        "death_cause", "death_cv_mode", "mi_type", "stroke_type", "severity", "outcome", "source", "endpoint_code",
        "adjudication_status", "classification", "meets_endpoint"]
    ep_cols = ["study_subject_code", "endpoint_code", "endpoint_kind", "is_primary", "had_event", "time_days",
               "last_follow_up_day", "pending_adjudications"]
    return {"subjects": (subj_cols, subjects), "visits": (visit_cols, visits),
            "events": (ev_cols, [[e[c] for c in ev_cols] for e in d.events]),
            "endpoints": (ep_cols, [[e[c] for c in ep_cols] for e in d.endpoints])}


def _suppress(n: int) -> Any:
    return f"<{SMALL_CELL}" if 0 < n < SMALL_CELL else n


def aggregate_tables(job: dict, d: ExportData) -> dict[str, tuple[list[str], list[list]]]:
    """Counts and summaries only.  Any count from 1 to SMALL_CELL-1 is written '<5'; numeric summaries
    are left out when fewer than SMALL_CELL values exist."""
    out_subj = [["n_subjects", "", _suppress(len(d.subjects))]]
    for key in ("sex", "enrolment_status"):
        for val in sorted({s[key] for s in d.subjects}):
            out_subj.append([key, val, _suppress(sum(1 for s in d.subjects if s[key] == val))])
    visits_by_code: dict[str, int] = {}
    for a in d.visits:
        visits_by_code[a["visit_code"]] = visits_by_code.get(a["visit_code"], 0) + 1
    rows = []
    types = {x["variable_code"]: x["data_type"] for x in d.dictionary}
    for vc in sorted(visits_by_code):
        for var in [x["variable_code"] for x in d.dictionary]:
            vals = [v for v in d.values if v["visit_code"] == vc and v["variable_code"] == var]
            present = [v for v in vals if v["value_status"] == "present"]
            n_vis = visits_by_code[vc]
            base = [vc, var, _suppress(n_vis), _suppress(len(present)), _suppress(n_vis - len(present))]
            t = types[var]
            if t in ("numeric", "integer"):
                xs = sorted(float(v["numeric_value"]) for v in present)
                if len(xs) >= SMALL_CELL:
                    q = statistics.quantiles(xs, n=4)
                    rows.append(base + ["", "", round(statistics.mean(xs), 3), round(statistics.stdev(xs), 3),
                                        round(statistics.median(xs), 3), round(q[0], 3), round(q[2], 3)])
                else:
                    rows.append(base + ["", "", "", "", "", "", ""])
            elif t in ("coded", "boolean", "multi_coded"):
                cats: dict[str, int] = {}
                for v in present:
                    keys = (v["coded_values"] or []) if t == "multi_coded" else [
                        v["coded_value"] if t == "coded" else str(v["boolean_value"]).lower()]
                    for k in keys:
                        cats[k] = cats.get(k, 0) + 1
                if not cats:
                    rows.append(base + ["", "", "", "", "", "", ""])
                for k in sorted(cats):
                    rows.append(base + [k, _suppress(cats[k]), "", "", "", "", ""])
            else:
                rows.append(base + ["", "", "", "", "", "", ""])
    ep: dict[str, list[int]] = {}
    for e in d.endpoints:
        ep.setdefault(e["endpoint_code"], [0, 0])
        ep[e["endpoint_code"]][0] += 1
        ep[e["endpoint_code"]][1] += 1 if e["had_event"] else 0
    return {
        "subject_summary": (["measure", "category", "n"], out_subj),
        "variable_summary": (["visit_code", "variable_code", "n_visits", "n_present", "n_not_present", "category",
                              "n_category", "mean", "sd", "median", "q1", "q3"], rows),
        "endpoint_summary": (["endpoint_code", "n_subjects", "n_with_event"],
                             [[k, _suppress(v[0]), _suppress(v[1])] for k, v in sorted(ep.items())])}


def dictionary_table(job: dict, d: ExportData) -> tuple[list[str], list[list]]:
    deid = job["deidentification"]
    rows = []
    for x in d.dictionary:
        note = ""
        if x["data_type"] == "date":
            note = "calendar year" if deid == "pseudonymised_year_only" else "days from index date"
        elif x["data_type"] == "multi_coded":
            note = "codes separated by ;"
        av = "; ".join(f"{a['code']}={a['label']}" for a in x["allowed_values"]) if x["allowed_values"] else ""
        rows.append([x["variable_code"], x["definition_version"], x["category"], x["variable_label"], x["data_type"],
                     x["unit"] or "", av, note])
    return (["variable_code", "definition_version", "category", "variable_label", "data_type", "unit",
             "allowed_values", "export_note"], rows)


def _csv_bytes(style: Style, cols: list[str], rows: list[list]) -> bytes:
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow([style.name(c) for c in cols])
    for r in rows:
        w.writerow([style.cell(v) for v in r])
    return buf.getvalue().encode("utf-8")


def _spss_syntax(style: Style, d: ExportData, missing: dict) -> bytes:
    lines = ["* CardioEMR export: variable and value labels.", "VARIABLE LABELS"]
    lines += [f"  {x['variable_code']} '{x['variable_label'].replace(chr(39), chr(39) * 2)}'" for x in d.dictionary]
    lines[-1] += "."
    coded = [x for x in d.dictionary if x["data_type"] == "coded" and x["allowed_values"]]
    if coded:
        lines.append("VALUE LABELS")
        for i, x in enumerate(coded):
            lines.append(f"  {'/' if i else ''}{x['variable_code']}")
            lines += [f"    '{a['code']}' '{a['label'].replace(chr(39), chr(39) * 2)}'" for a in x["allowed_values"]]
        lines[-1] += "."
    codes = sorted({v for k, v in missing.items() if k != "missing" and isinstance(v, (int, float))})
    numeric = [x["variable_code"] for x in d.dictionary if x["data_type"] in ("numeric", "integer", "date", "boolean")]
    if codes and numeric:
        lines.append(f"MISSING VALUES {' '.join(numeric)} ({', '.join(str(c) for c in codes[:3])}).")
    return ("\n".join(lines) + "\n").encode("utf-8")


def render(job: dict, d: ExportData, generated_at: datetime | None = None) -> tuple[bytes, str, int, dict]:
    """(file bytes, extension, row count, manifest)."""
    generated_at = generated_at or datetime.now(timezone.utc)
    style = Style(job["file_format"])
    missing = {**MISSING_DEFAULT, **(job["missing_value_codes"] or {})}
    aggregate = job["deidentification"] == "aggregate_only"
    tables = aggregate_tables(job, d) if aggregate else subject_level_tables(job, d)
    if job["include_data_dictionary"]:
        tables["data_dictionary"] = dictionary_table(job, d)
    row_count = len(tables["variable_summary" if aggregate else "visits"][1])
    manifest = {
        "export_id": str(job["export_id"]), "protocol_code": d.protocol["protocol_code"],
        "protocol_version": d.protocol["protocol_version"], "generated_at": generated_at.isoformat(),
        "purpose": job["purpose"], "deidentification": job["deidentification"], "file_format": job["file_format"],
        "centres": [c["centre_code"] for c in d.centres], "cohort_filter": job["cohort_filter"] or {},
        "visit_codes": job["visit_codes"], "variable_codes": [x["variable_code"] for x in d.dictionary],
        "missing_value_codes": missing, "small_cell_threshold": SMALL_CELL if aggregate else None,
        "age_top_code": AGE_TOP_CODE, "tables": {k: len(v[1]) for k, v in tables.items()},
        "notes": ["Times are days from the enrolment index date; no exact dates are included.",
                  f"Ages above {AGE_TOP_CODE - 1} are written as {AGE_TOP_CODE}.",
                  "Endpoint events count only adjudicated events that meet the endpoint, or events of endpoints "
                  "that need no adjudication; pending_adjudications shows what is still open.", *d.notes]}
    if job["file_format"] == "xlsx":
        from openpyxl import Workbook
        wb = Workbook()
        wb.remove(wb.active)
        for name, (cols, rows) in tables.items():
            ws = wb.create_sheet(name[:31])
            ws.append(cols)
            for r in rows:
                ws.append([style.cell(v) if not isinstance(v, bool) else v for v in r])
        ws = wb.create_sheet("manifest")
        for k, v in manifest.items():
            ws.append([k, json.dumps(v, default=str) if not isinstance(v, (str, int, float)) or v is None else v])
        buf = io.BytesIO()
        wb.save(buf)
        return buf.getvalue(), "xlsx", row_count, manifest
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, (cols, rows) in tables.items():
            z.writestr(f"{name}.csv", _csv_bytes(style, cols, rows))
        if job["file_format"] == "spss_csv" and not aggregate:
            z.writestr("labels.sps", _spss_syntax(style, d, missing))
        if job["file_format"] == "stata_csv" and style._names:
            manifest["stata_variable_names"] = {k: v for k, v in style._names.items() if k != v}
        z.writestr("manifest.json", json.dumps(manifest, indent=2, default=str))
    return buf.getvalue(), "zip", row_count, manifest


def sha256(b: bytes) -> bytes:
    return hashlib.sha256(b).digest()
