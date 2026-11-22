"""API acceptance tests: the registry flow from suggestion to locked visit,
with the security and validation rules of the contract (doc section 6)."""
import pytest

from conftest import CARE_CONSENT, CENTRE_B, HF_CONSENT, PATIENT, SUGGESTION

API = "/api/v1"
state: dict = {}


def code(r):
    return r.json().get("code")


# --- authentication and roles -------------------------------------------------

def test_no_token_is_401(client):
    r = client.get(f"{API}/registries", headers={"X-Centre-Id": CENTRE_B, "X-Acting-Role": "clinician"})
    assert r.status_code == 401 and r.headers["content-type"].startswith("application/problem+json")


def test_forged_token_is_401(client, as_user, token):
    h = as_user("dra")
    h["Authorization"] = "Bearer " + token("dra")[:-4] + "AAAA"
    assert client.get(f"{API}/registries", headers=h).status_code == 401


def test_expired_token_is_401(client, as_user, token):
    h = as_user("dra")
    h["Authorization"] = "Bearer " + token("dra", exp=1)
    assert client.get(f"{API}/registries", headers=h).status_code == 401


def test_suspended_user_is_401(client, as_user):
    assert client.get(f"{API}/registries", headers=as_user("sus")).status_code == 401


def test_role_not_held_at_centre(client, as_user):
    r = client.get(f"{API}/registries", headers=as_user("dra", role="principal_investigator"))
    assert r.status_code == 403 and code(r) == "ROLE_NOT_HELD"
    r = client.get(f"{API}/registries", headers=as_user("dra", centre=CENTRE_B))
    assert r.status_code == 403 and code(r) == "ROLE_NOT_HELD"


def test_assistant_has_no_registry_access(client, as_user):
    r = client.get(f"{API}/registry-suggestions", headers=as_user("asa"))
    assert r.status_code == 403 and code(r) == "FORBIDDEN"


# --- protocols and dictionaries ------------------------------------------------

def test_registries_for_clinician_and_nurse(client, as_user):
    r = client.get(f"{API}/registries", headers=as_user("dra"))
    assert r.status_code == 200
    regs = {x["registry_code"]: x for x in r.json()["items"]}
    assert set(regs) == {"HF", "LIPID", "CAD"}
    hf = regs["HF"]["protocols"][0]
    assert hf["protocol_code"] == "CEMR-HF" and hf["site_status"] == "active"
    state["hf_protocol"] = hf["protocol_id"]
    state["cad_protocol"] = regs["CAD"]["protocols"][0]["protocol_id"]
    r = client.get(f"{API}/registries", headers=as_user("nua"))
    assert r.status_code == 200 and all(x["protocols"] == [] for x in r.json()["items"])


def test_protocol_and_dictionary(client, as_user):
    r = client.get(f"{API}/protocols/{state['hf_protocol']}", headers=as_user("dra"))
    assert r.status_code == 200 and r.headers["etag"]
    assert [v["visit_code"] for v in r.json()["visits"]][:2] == ["BL", "M1"]
    r = client.get(f"{API}/protocols/{state['cad_protocol']}/data-dictionary", headers=as_user("dra"))
    assert len({v["variable_code"] for v in r.json()["items"]}) == 94
    r = client.get(f"{API}/protocols/{state['hf_protocol']}/data-dictionary?visit_code=BL",
                   headers={**as_user("dra"), "Accept": "text/csv"})
    assert r.headers["content-type"].startswith("text/csv") and r.text.startswith("variable_code,")


# --- suggestion -> screening -> eligibility -> enrolment -----------------------

def test_nurse_sees_suggestion(client, as_user):
    r = client.get(f"{API}/registry-suggestions", headers=as_user("nua"))
    assert [s["suggestion_id"] for s in r.json()["items"]] == [SUGGESTION]


def test_start_screening_is_idempotent(client, as_user, db_admin):
    body = {"patient_id": PATIENT, "protocol_id": state["hf_protocol"], "suggestion_id": SUGGESTION}
    key = {"Idempotency-Key": "screening-key-0001"}
    r1 = client.post(f"{API}/enrolments", json=body, headers={**as_user("dra"), **key})
    r2 = client.post(f"{API}/enrolments", json=body, headers={**as_user("dra"), **key})
    assert r1.status_code == r2.status_code == 201
    assert r1.json()["enrolment_id"] == r2.json()["enrolment_id"]
    assert db_admin.execute("SELECT count(*) FROM registry.enrolments").fetchone()[0] == 1
    assert db_admin.execute("SELECT status FROM registry.registry_suggestions").fetchone()[0] == "screening_started"
    r3 = client.post(f"{API}/enrolments", json={**body, "screening_date": "2026-01-01"},
                     headers={**as_user("dra"), **key})
    assert r3.status_code == 422 and code(r3) == "IDEMPOTENCY_MISMATCH"
    state["enrolment"] = r1.json()["enrolment_id"]
    state["etag"] = r1.headers["etag"]


def test_other_centre_gets_404(client, as_user):
    r = client.get(f"{API}/enrolments/{state['enrolment']}", headers=as_user("drb", centre=CENTRE_B))
    assert r.status_code == 404


def test_eligibility_rules(client, as_user):
    body = {"eligibility_status": "eligible", "checklist": [{"criterion_code": "hf_diagnosis", "answer": "yes"}]}
    url = f"{API}/enrolments/{state['enrolment']}/eligibility"
    r = client.put(url, json=body, headers={**as_user("rca"), "If-Match": state["etag"]})
    assert r.status_code == 403 and code(r) == "FORBIDDEN"
    r = client.put(url, json=body, headers={**as_user("dra"), "If-Match": '"99"'})
    assert r.status_code == 412 and code(r) == "STALE_VERSION" and r.json()["current"]["row_version"] == 1
    r = client.put(url, json=body, headers={**as_user("dra"), "If-Match": state["etag"]})
    assert r.status_code == 200 and r.json()["eligibility_status"] == "eligible"
    state["etag"] = r.headers["etag"]


HF_DETAILS = {"registry_code": "HF", "hf_status_at_enrolment": "newly_diagnosed", "primary_aetiology": "ischaemic",
              "baseline_lvef": 30, "baseline_phenotype": "HFrEF"}


def test_enrol_needs_research_consent_for_this_protocol(client, as_user):
    url = f"{API}/enrolments/{state['enrolment']}/enrol"
    h = {**as_user("dra"), "If-Match": state["etag"]}
    r = client.post(url, json={"index_date": "2026-11-20", "consent_id": CARE_CONSENT, "details": HF_DETAILS}, headers=h)
    assert r.status_code == 422 and code(r) == "CONSENT_REQUIRED"
    cad = {"registry_code": "CAD", "presentation": "NSTEMI", "categories": ["NSTEMI"], "index_event_date": "2026-11-20"}
    r = client.post(url, json={"index_date": "2026-11-20", "consent_id": HF_CONSENT, "details": cad}, headers=h)
    assert r.status_code == 422 and code(r) == "PROTOCOL_MISMATCH"
    r = client.post(url, json={"index_date": "2026-11-20", "consent_id": HF_CONSENT, "details": HF_DETAILS}, headers=h)
    assert r.status_code == 200, r.json()
    e = r.json()
    assert e["enrolment_status"] == "enrolled" and e["details"]["baseline_phenotype"] == "HFrEF"
    assert e["study_subject_code"] is None          # clinicians do not see the research code
    assert e["schedule"][0]["visit_code"] == "BL" and e["schedule"][0]["status"] in ("due", "done")
    state["etag"] = r.headers["etag"]


def test_coordinator_sees_study_code_and_reads_are_logged(client, as_user, db_admin):
    r = client.get(f"{API}/enrolments/{state['enrolment']}", headers=as_user("rca"))
    assert r.status_code == 200, str(r.json())
    assert r.json()["study_subject_code"].startswith("HF-")
    n = db_admin.execute("SELECT count(*) FROM audit.access_log WHERE entity_name = 'registry.enrolments'").fetchone()[0]
    assert n >= 1


def test_second_enrolment_same_protocol_conflicts(client, as_user, idem):
    r = client.post(f"{API}/enrolments", json={"patient_id": PATIENT, "protocol_id": state["hf_protocol"]},
                    headers={**as_user("dra"), **idem()})
    assert r.status_code == 409 and code(r) == "ALREADY_ENROLLED"


# --- assessments ---------------------------------------------------------------

def test_open_baseline(client, as_user, idem):
    url = f"{API}/enrolments/{state['enrolment']}/assessments"
    body = {"visit_code": "BL", "assessment_type": "baseline", "assessment_date": "2026-11-22"}
    r = client.post(url, json=body, headers={**as_user("dra"), **idem()})
    assert r.status_code == 201 and r.json()["days_from_index"] == 2 and r.json()["within_window"] is True
    state["assessment"], state["a_etag"] = r.json()["assessment_id"], r.headers["etag"]
    r = client.post(url, json=body, headers={**as_user("dra"), **idem()})
    assert r.status_code == 409 and code(r) == "DUPLICATE_VISIT"
    r = client.post(url, json={**body, "visit_code": "M99"}, headers={**as_user("dra"), **idem()})
    assert r.status_code == 422


def test_bad_values_all_reported_none_saved(client, as_user, db_admin):
    values = [{"variable_code": "lvef", "value": 140}, {"variable_code": "nyha_class", "value": "V"},
              {"variable_code": "systolic_bp", "value": 112.5}, {"variable_code": "heart_rate", "value": 72},
              {"variable_code": "no_such_variable", "value": 1}]
    r = client.put(f"{API}/assessments/{state['assessment']}/values", json={"values": values},
                   headers=as_user("dra"))
    assert r.status_code == 422
    rules = {e["variable_code"]: e["rule"] for e in r.json()["errors"]}
    assert rules == {"lvef": "VALUE_OUT_OF_RANGE", "nyha_class": "CODE_NOT_ALLOWED",
                     "systolic_bp": "WRONG_VALUE_TYPE", "no_such_variable": "UNKNOWN_VARIABLE"}
    assert db_admin.execute("SELECT count(*) FROM registry.variable_values").fetchone()[0] == 0


def test_save_and_change_values(client, as_user):
    url = f"{API}/assessments/{state['assessment']}/values"
    r = client.put(url, json={"values": [{"variable_code": "lvef", "value": 30},
                                         {"variable_code": "nyha_class", "value": "II"}]}, headers=as_user("dra"))
    assert r.status_code == 200
    lvef = next(v for v in r.json()["items"] if v["variable_code"] == "lvef")
    assert lvef["value"] == 30 and lvef["verification_status"] == "unverified"
    r = client.put(url, json={"values": [{"variable_code": "lvef", "value": 32}]}, headers=as_user("dra"))
    assert r.status_code == 412                      # no row_version for an existing value
    change = {"values": [{"variable_code": "lvef", "value": 32, "row_version": lvef["row_version"]}]}
    r = client.put(url, json=change, headers=as_user("dra"))
    assert r.status_code == 428 and code(r) == "CHANGE_REASON_REQUIRED"
    r = client.put(url, json=change, headers=as_user("dra", x_change_reason="Remeasured biplane"))
    assert r.status_code == 200 and r.json()["items"][0]["value"] == 32


def test_complete_needs_mandatory_values(client, as_user):
    url = f"{API}/assessments/{state['assessment']}/complete"
    r = client.post(url, json={"completion_status": "complete"},
                    headers={**as_user("dra"), "If-Match": state["a_etag"]})
    assert r.status_code == 422 and code(r) == "MANDATORY_MISSING"
    missing = [e["variable_code"] for e in r.json()["errors"]]
    assert "lvef" not in missing and "nyha_class" not in missing and len(missing) > 10
    fill = [{"variable_code": c, "value_status": "unknown"} for c in missing]
    assert client.put(f"{API}/assessments/{state['assessment']}/values", json={"values": fill},
                      headers=as_user("dra")).status_code == 200
    r = client.post(url, json={"completion_status": "complete"},
                    headers={**as_user("dra"), "If-Match": state["a_etag"]})
    assert r.status_code == 200 and r.json()["completion_status"] == "complete"
    state["a_etag"] = r.headers["etag"]


def test_lock_and_unlock(client, as_user, db_admin):
    aid = state["assessment"]
    r = client.post(f"{API}/assessments/{aid}/lock", headers={**as_user("dra"), "If-Match": state["a_etag"]})
    assert r.status_code == 403
    detail = client.get(f"{API}/assessments/{aid}", headers=as_user("rca")).json()
    lvef = next(v["value"] for v in detail["variables"] if v["definition"]["variable_code"] == "lvef")
    r = client.put(f"{API}/assessments/{aid}/values/lvef/verification", json={"verification_status": "queried",
                   "query_text": "Check against echo report"},
                   headers={**as_user("rca"), "If-Match": f'"{lvef["row_version"]}"'})
    assert r.status_code == 200
    queried_version = r.json()["row_version"]
    r = client.post(f"{API}/assessments/{aid}/lock", headers={**as_user("rca"), "If-Match": state["a_etag"]})
    assert r.status_code == 422 and code(r) == "OPEN_QUERIES"
    client.put(f"{API}/assessments/{aid}/values/lvef/verification", json={"verification_status": "verified"},
               headers={**as_user("rca"), "If-Match": f'"{queried_version}"'})
    r = client.post(f"{API}/assessments/{aid}/lock", headers={**as_user("rca"), "If-Match": state["a_etag"]})
    assert r.status_code == 200 and r.json()["locked_at"]
    etag_locked = r.headers["etag"]
    r = client.put(f"{API}/assessments/{aid}/values", json={"values": [{"variable_code": "heart_rate", "value": 70}]},
                   headers=as_user("dra"))
    assert r.status_code == 422 and code(r) == "ASSESSMENT_LOCKED"
    r = client.delete(f"{API}/assessments/{aid}/lock", headers={**as_user("rca"), "If-Match": etag_locked})
    assert r.status_code == 403
    r = client.delete(f"{API}/assessments/{aid}/lock", headers={**as_user("pia"), "If-Match": etag_locked})
    assert r.status_code == 428
    r = client.delete(f"{API}/assessments/{aid}/lock",
                      headers={**as_user("pia", x_change_reason="Correct LVEF per core lab"), "If-Match": etag_locked})
    assert r.status_code == 200 and r.json()["locked_at"] is None
    reason = db_admin.execute("""SELECT reason FROM audit.audit_log WHERE table_name = 'assessments'
                                  AND new_values ? 'locked_at' AND new_values->>'locked_at' IS NULL
                                  ORDER BY audit_id DESC LIMIT 1""").fetchone()[0]
    assert reason == "Correct LVEF per core lab"


def test_schedule_shows_baseline_done(client, as_user):
    r = client.get(f"{API}/enrolments/{state['enrolment']}/schedule", headers=as_user("nua"))
    items = r.json()["items"]
    assert items[0]["visit_code"] == "BL" and items[0]["status"] == "done"
    assert any(i["visit_code"] == "ANNUAL" and i["occurrence"] >= 2 for i in items)
