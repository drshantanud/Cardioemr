"""Site reports: visits due for follow-up, and mandatory data still missing."""
from __future__ import annotations

import uuid
from datetime import date, timedelta

from fastapi import APIRouter, Depends, Query

from ..context import Ctx, roles
from ..errors import Problem
from .enrolment import _jsonable, build_schedule

router = APIRouter(tags=["Reports"])
FOLLOW_UP_READERS = roles("clinician", "research_coordinator", "principal_investigator", "nurse")
MISSING_DATA_READERS = roles("clinician", "research_coordinator", "principal_investigator")


def follow_up_due_items(facts: dict, today: date, within_days: int, include_overdue: bool) -> list[dict]:
    """Visits whose window is open, opens within `within_days`, or (optionally) closed with no assessment.
    Visits whose window opens after a reported death are left out."""
    horizon = today + timedelta(days=within_days)
    labels = {v["visit_code"]: v.get("visit_label") for v in facts["visits"]}
    longest = max((v["window_before_days"] for v in facts["visits"]), default=0)
    items = []
    for e in facts["enrolments"]:
        death = date.fromisoformat(e["death_reported_on"]) if e.get("death_reported_on") else None
        for v in build_schedule(e["index_date"], facts["visits"], e["assessments"],
                                through=horizon + timedelta(days=longest), today=today):
            opens = date.fromisoformat(v["window_opens"])
            if death is not None and opens > death:
                continue
            wanted = (v["status"] == "due" or (v["status"] == "not_due" and opens <= horizon)
                      or (include_overdue and v["status"] == "overdue"))
            if not wanted:
                continue
            closes = date.fromisoformat(v["window_closes"])
            items.append({**v, "visit_label": labels.get(v["visit_code"]), "enrolment_id": e["enrolment_id"],
                          "patient_id": e["patient_id"], "local_patient_code": e["local_patient_code"],
                          "patient_name": e["patient_name"], "mobile": e["mobile"],
                          "death_reported_on": e.get("death_reported_on"),
                          "days_until_window_closes": (closes - today).days})
    return sorted(items, key=lambda x: (x["window_closes"], x["local_patient_code"], x["visit_code"]))


@router.get("/protocols/{protocol_id}/follow-up-due")
def follow_up_due(protocol_id: uuid.UUID, within_days: int = Query(14, ge=0, le=180),
                  include_overdue: bool = True, ctx: Ctx = Depends(FOLLOW_UP_READERS)):
    facts = ctx.one("SELECT registry.follow_up_facts(%s) AS f", (protocol_id,))["f"]
    if facts is None:
        raise Problem(404, "NOT_FOUND", "Protocol not found")
    today = date.today()
    items = follow_up_due_items(facts, today, within_days, include_overdue)
    ctx.log_access("search", None, "registry.follow_up_due", protocol_id)
    counts = {s: sum(1 for i in items if i["status"] == s) for s in ("due", "not_due", "overdue")}
    return {"as_of": today.isoformat(), "within_days": within_days, "counts": counts, "items": items}


@router.get("/protocols/{protocol_id}/missing-data")
def missing_data(protocol_id: uuid.UUID, visit_code: str | None = Query(None, pattern=r"^[A-Z0-9_]{1,12}$"),
                 ctx: Ctx = Depends(MISSING_DATA_READERS)):
    if ctx.one("SELECT 1 FROM registry.registry_protocols WHERE protocol_id = %s", (protocol_id,)) is None:
        raise Problem(404, "NOT_FOUND", "Protocol not found")
    rows = ctx.all("""
        SELECT m.visit_code, m.variable_code, m.variable_label, min(m.sort_order) AS sort_order,
               count(*) AS assessments_due,
               count(*) FILTER (WHERE NOT m.has_value) AS missing,
               count(*) FILTER (WHERE m.has_value AND m.value_status <> 'present') AS recorded_as_not_available,
               count(*) FILTER (WHERE m.verification_status = 'queried') AS queried,
               array_agg(m.assessment_id ORDER BY m.assessment_date, m.assessment_id)
                 FILTER (WHERE NOT m.has_value) AS assessment_ids
          FROM registry.v_mandatory_values m
          LEFT JOIN registry.visit_schedule vs ON vs.protocol_id = m.protocol_id AND vs.visit_code = m.visit_code
         WHERE m.protocol_id = %s AND (%s::text IS NULL OR m.visit_code = %s)
         GROUP BY m.visit_code, m.variable_code, m.variable_label, vs.sort_order
        HAVING count(*) FILTER (WHERE NOT m.has_value) > 0
         ORDER BY vs.sort_order NULLS LAST, m.visit_code, min(m.sort_order), m.variable_code""",
        (protocol_id, visit_code, visit_code))
    totals = ctx.one("""
        SELECT count(DISTINCT assessment_id) AS assessments, count(*) AS mandatory_values,
               count(*) FILTER (WHERE NOT has_value) AS missing
          FROM registry.v_mandatory_values WHERE protocol_id = %s AND (%s::text IS NULL OR visit_code = %s)""",
        (protocol_id, visit_code, visit_code))
    # The visits to chase: each assessment with mandatory values still empty, most missing first.
    by_assessment = ctx.all("""
        SELECT m.assessment_id, m.enrolment_id, a.patient_id, pr.local_patient_code, m.visit_code, m.assessment_date,
               m.completion_status, count(*) FILTER (WHERE NOT m.has_value) AS missing, count(*) AS mandatory_values
          FROM registry.v_mandatory_values m
          JOIN registry.assessments a USING (assessment_id)
          LEFT JOIN clinical.patient_registrations pr ON pr.patient_id = a.patient_id AND pr.centre_id = a.centre_id
         WHERE m.protocol_id = %s AND (%s::text IS NULL OR m.visit_code = %s)
         GROUP BY m.assessment_id, m.enrolment_id, a.patient_id, pr.local_patient_code, m.visit_code,
                  m.assessment_date, m.completion_status
        HAVING count(*) FILTER (WHERE NOT m.has_value) > 0
         ORDER BY count(*) FILTER (WHERE NOT m.has_value) DESC, m.assessment_date, m.assessment_id
         LIMIT 200""", (protocol_id, visit_code, visit_code))
    for r in rows:
        r.pop("sort_order")
    totals["completeness_pct"] = (round(100 * (1 - totals["missing"] / totals["mandatory_values"]), 1)
                                  if totals["mandatory_values"] else None)
    return _jsonable({"totals": totals, "items": rows, "by_assessment": by_assessment})
