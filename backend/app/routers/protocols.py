"""Registries, protocols and data dictionaries (no patient data)."""
from __future__ import annotations

import csv
import io
import uuid

from fastapi import APIRouter, Depends, Request, Response

from ..context import Ctx, etag, roles
from ..errors import Problem

router = APIRouter(tags=["Protocols"])
READERS = roles("clinician", "research_coordinator", "principal_investigator", "nurse", "platform_admin")
CONFIG_READERS = roles("clinician", "research_coordinator", "principal_investigator", "platform_admin")


@router.get("/registries")
def list_registries(ctx: Ctx = Depends(READERS)):
    if ctx.role == "nurse":   # nurses see registry names only (no grant on protocols)
        rows = ctx.all("SELECT registry_code, registry_name FROM registry.registry_types WHERE status = 'active' "
                       "ORDER BY registry_code")
        return {"items": [dict(r, protocols=[]) for r in rows]}
    rows = ctx.all("""
        SELECT rt.registry_code, rt.registry_name, p.protocol_id, p.protocol_code, p.protocol_version, p.status,
               ps.site_status
          FROM registry.registry_types rt
          LEFT JOIN registry.registry_protocols p ON p.registry_type_id = rt.registry_type_id
          LEFT JOIN registry.protocol_sites ps ON ps.protocol_id = p.protocol_id AND ps.centre_id = %s
         WHERE rt.status = 'active'
         ORDER BY rt.registry_code, p.protocol_code, p.protocol_version""", (ctx.centre_id,))
    out: dict[str, dict] = {}
    for r in rows:
        reg = out.setdefault(r["registry_code"], {"registry_code": r["registry_code"],
                                                   "registry_name": r["registry_name"], "protocols": []})
        if r["protocol_id"]:
            reg["protocols"].append({k: r[k] for k in ("protocol_id", "protocol_code", "protocol_version",
                                                        "status", "site_status")})
    return {"items": list(out.values())}


def _protocol(ctx: Ctx, protocol_id: uuid.UUID) -> dict:
    p = ctx.one("""SELECT p.*, rt.registry_code FROM registry.registry_protocols p
                    JOIN registry.registry_types rt USING (registry_type_id) WHERE p.protocol_id = %s""",
                (protocol_id,))
    if p is None:
        raise Problem(404, "NOT_FOUND", "Protocol not found")
    return p


@router.get("/protocols/{protocol_id}")
def get_protocol(protocol_id: uuid.UUID, response: Response, ctx: Ctx = Depends(CONFIG_READERS)):
    p = _protocol(ctx, protocol_id)
    visits = ctx.all("""SELECT visit_code, visit_label, target_day, window_before_days, window_after_days,
                               repeats_every_days FROM registry.visit_schedule WHERE protocol_id = %s
                        ORDER BY sort_order""", (protocol_id,))
    endpoints = ctx.all("""SELECT endpoint_code, endpoint_label, endpoint_kind FROM registry.endpoint_definitions
                           WHERE protocol_id = %s ORDER BY endpoint_code""", (protocol_id,))
    rule_sets = ctx.all("""
        SELECT rs.rule_kind, rs.rule_set_code, rs.version, rs.status, x.role
          FROM (VALUES (%(h)s::uuid, 'primary'), (%(s)s::uuid, 'primary'), (%(l)s::uuid, 'primary'),
                       (%(l2)s::uuid, 'secondary')) x(id, role)
          JOIN ref.rule_sets rs ON rs.rule_set_id = x.id""",
        {"h": p["hf_target_dose_rule_set_id"], "s": p["statin_rule_set_id"], "l": p["ldl_target_rule_set_id"],
         "l2": p.get("ldl_secondary_rule_set_id")})
    response.headers["ETag"] = etag(p["row_version"])
    return {"protocol_id": p["protocol_id"], "protocol_code": p["protocol_code"],
            "protocol_version": p["protocol_version"], "registry_code": p["registry_code"],
            "title": p["protocol_title"], "status": p["status"],
            "requires_research_consent": p["requires_research_consent"],
            "visits": visits, "endpoints": endpoints, "rule_sets": rule_sets, "row_version": p["row_version"]}


DICT_COLUMNS = ["variable_code", "definition_version", "category", "variable_label", "description", "data_type",
                "unit", "accepted_units", "allowed_values", "min_value", "max_value", "source_kind", "emr_source",
                "visit_code", "requirement", "condition_text"]
COMPUTED = {"accepted_units": "registry.accepted_units(d.variable_id) AS accepted_units"}


@router.get("/protocols/{protocol_id}/data-dictionary")
def data_dictionary(protocol_id: uuid.UUID, request: Request, visit_code: str | None = None,
                    ctx: Ctx = Depends(CONFIG_READERS)):
    p = _protocol(ctx, protocol_id)
    rows = ctx.all(f"""
        SELECT {', '.join(COMPUTED.get(c) or ('d.' + c if c not in ('visit_code', 'requirement', 'condition_text')
                                              else 'pv.' + c) for c in DICT_COLUMNS)}
          FROM registry.protocol_variables pv JOIN registry.variable_definitions d USING (variable_id)
         WHERE pv.protocol_id = %s AND (%s::text IS NULL OR pv.visit_code IN (%s, '*'))
         ORDER BY pv.sort_order, d.variable_code, pv.visit_code""", (protocol_id, visit_code, visit_code))
    for r in rows:
        for k in ("min_value", "max_value"):
            if r[k] is not None:
                r[k] = float(r[k])
    if "text/csv" in request.headers.get("accept", ""):
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(DICT_COLUMNS)
        for r in rows:
            av = "; ".join(a["code"] for a in r["allowed_values"]) if r["allowed_values"] else ""
            units = "; ".join(r["accepted_units"] or [])
            w.writerow([av if c == "allowed_values" else units if c == "accepted_units"
                        else ("" if r[c] is None else r[c]) for c in DICT_COLUMNS])
        return Response(buf.getvalue(), media_type="text/csv")
    return {"protocol_code": p["protocol_code"], "protocol_version": p["protocol_version"], "items": rows}
