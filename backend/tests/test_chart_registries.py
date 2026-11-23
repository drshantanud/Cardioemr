"""Prefill from the chart, HF GDMT, lipid targets and PCI entry, for the charted
patient 2 in fixtures.sql (female, born 1958-07-02, HFrEF on three pillars)."""
import pytest

from conftest import CENTRE_B

API = "/api/v1"
PATIENT2 = "10000000-0000-0000-0000-000000000002"
CONSENT = {"HF": "15000000-0000-0000-0000-000000000012", "LIPID": "15000000-0000-0000-0000-000000000013",
           "CAD": "15000000-0000-0000-0000-000000000014"}
DETAILS = {
    "HF": {"registry_code": "HF", "hf_status_at_enrolment": "prevalent", "primary_aetiology": "ischaemic",
           "baseline_lvef": 30, "baseline_phenotype": "HFrEF"},
    "LIPID": {"registry_code": "LIPID", "prevention_type": "secondary", "categories": ["established_cad", "diabetes"],
              "baseline_ldl_kind": "untreated", "baseline_ldl_mg_dl": 160, "baseline_on_llt": False},
    "CAD": {"registry_code": "CAD", "presentation": "chronic_coronary_syndrome",
            "categories": ["chronic_coronary_syndrome"], "index_event_date": "2026-11-20"},
}
state: dict = {}


def code(r):
    return r.json().get("code")


def values(prefill: dict) -> dict:
    return {v["variable_code"]: v for v in prefill["filled"]}


def enrol_and_open_baseline(client, as_user, idem, registry: str) -> dict:
    regs = {x["registry_code"]: x for x in client.get(f"{API}/registries", headers=as_user("dra")).json()["items"]}
    protocol = regs[registry]["protocols"][0]["protocol_id"]
    r = client.post(f"{API}/enrolments", json={"patient_id": PATIENT2, "protocol_id": protocol},
                    headers={**as_user("dra"), **idem()})
    assert r.status_code == 201, r.json()
    eid, tag = r.json()["enrolment_id"], r.headers["etag"]
    r = client.put(f"{API}/enrolments/{eid}/eligibility", json={"eligibility_status": "eligible",
                         "checklist": [{"criterion_code": "diagnosis", "answer": "yes"}]},
                   headers={**as_user("dra"), "If-Match": tag})
    assert r.status_code == 200, r.json()
    r = client.post(f"{API}/enrolments/{eid}/enrol",
                    json={"index_date": "2026-11-20", "consent_id": CONSENT[registry], "details": DETAILS[registry]},
                    headers={**as_user("dra"), "If-Match": r.headers["etag"]})
    assert r.status_code == 200, r.json()
    r = client.post(f"{API}/enrolments/{eid}/assessments",
                    json={"visit_code": "BL", "assessment_type": "baseline", "assessment_date": "2026-11-21",
                          "prefill": True}, headers={**as_user("dra"), **idem()})
    assert r.status_code == 201, r.json()
    return r.json()


# --- prefill -----------------------------------------------------------------------

def test_hf_baseline_prefills_from_chart(client, as_user, idem):
    a = enrol_and_open_baseline(client, as_user, idem, "HF")
    state["hf_assessment"] = a["assessment_id"]
    v = values(a["prefill"])
    assert v["sex"]["value"] == "female" and v["sex"]["source_table"] == "clinical.patient_registrations"
    assert v["age_at_index"]["value"] == 68
    # vitals: the visit-day reading, not the October one
    assert v["systolic_bp"]["value"] == 108 and v["heart_rate"]["value"] == 64
    assert v["systolic_bp"]["source_row_id"] == "17000000-0000-0000-0000-000000000021"
    assert v["weight_kg"]["value"] == 64.0 and v["bmi"]["value"] == 25.6
    assert v["lvef"]["value"] == 30 and v["lvef"]["source_table"] == "clinical.echo_reports"
    assert v["nt_probnp"]["value"] == 1850 and v["potassium"]["value"] == 4.8
    assert round(v["egfr"]["value"]) == 61          # CKD-EPI 2021: female, 68 y, creatinine 1.0 mg/dL
    assert v["nyha_class"]["value"] == "III" and v["jvp_raised"]["value"] is True
    assert v["has_diabetes"]["value"] is True and v["has_af"]["value"] is False   # AF only suspected
    assert v["rasi_pct_target"]["value"] == 25 and v["bb_pct_target"]["value"] == 50
    assert v["bb_drug"]["value"] == "CARVEDILOL" and v["sglt2i_dose_status"]["value"] == "at_target"
    assert v["mra_prescribed"]["value"] is False and v["gdmt_pillars_prescribed"]["value"] == 3
    assert all(x["verification_status"] == "unverified" and x["source_kind"] in ("emr_derived", "calculated")
               for x in a["prefill"]["filled"])
    reasons = {s["reason"] for s in a["prefill"]["skipped"]}
    assert "not_automated_yet" in reasons and "rejected_by_validation" not in reasons


def test_prefill_never_overwrites(client, as_user):
    aid = state["hf_assessment"]
    r = client.put(f"{API}/assessments/{aid}/values", json={"values": [{"variable_code": "lvef", "value": 33}]},
                   headers=as_user("dra"))
    assert r.status_code == 412                      # lvef was prefilled: changing it needs its row_version
    r = client.post(f"{API}/assessments/{aid}/prefill", headers=as_user("rca"))
    assert r.status_code == 200 and r.json()["filled"] == []
    skipped = {s["variable_code"]: s["reason"] for s in r.json()["skipped"]}
    assert skipped["lvef"] == "already_filled" and skipped["sex"] == "already_filled"
    r = client.post(f"{API}/assessments/{aid}/prefill", headers=as_user("nua"))
    assert r.status_code == 403


# --- HF GDMT -----------------------------------------------------------------------

def test_gdmt_live_and_stored(client, as_user):
    aid = state["hf_assessment"]
    r = client.get(f"{API}/assessments/{aid}/hf/gdmt", headers=as_user("dra"))
    assert r.status_code == 200, r.json()
    g = r.json()
    p = {x["pillar"]: x for x in g["pillars"]}
    assert g["hf_phenotype"] == "HFrEF" and g["stored"] is False and g["rule_set_status"] == "draft"
    assert p["RASI"]["drug_code"] == "SACUBITRIL_VALSARTAN" and p["RASI"]["pct_of_target"] == 25
    assert p["BB"]["dose_status"] == "below_target_uptitrating" and p["BB"]["last_titration_date"] == "2026-11-05"
    assert p["MRA"]["dose_status"] == "not_prescribed" and p["SGLT2I"]["dose_status"] == "at_target"
    assert g["pillars_on_treatment"] == 3 and g["pillars_at_target"] == 1

    body = {"reasons": [{"pillar": "BB", "reason_code": "hypotension"},
                        {"pillar": "MRA", "reason_code": "hyperkalaemia"}]}
    r = client.put(f"{API}/assessments/{aid}/hf/gdmt", json=body, headers=as_user("dra"))
    assert r.status_code == 200, r.json()
    p = {x["pillar"]: x for x in r.json()["pillars"]}
    assert r.json()["stored"] is True
    assert p["BB"]["dose_status"] == "below_target_max_tolerated" and p["BB"]["reasons"] == ["hypotension"]
    assert p["MRA"]["dose_status"] == "not_prescribed" and p["MRA"]["reasons"] == ["hyperkalaemia"]


def test_gdmt_reasons_are_append_only_and_checked(client, as_user, db_admin):
    aid = state["hf_assessment"]
    url = f"{API}/assessments/{aid}/hf/gdmt"
    r = client.put(url, json={"reasons": [{"pillar": "MRA", "reason_code": "hyperkalaemia"}]}, headers=as_user("dra"))
    assert r.status_code == 409 and r.json()["errors"][0]["field"] == "BB.hypotension"
    r = client.put(url, json={"reasons": [{"pillar": "RASI", "reason_code": "other"}]}, headers=as_user("dra"))
    assert r.status_code == 400
    r = client.put(url, json={"reasons": [{"pillar": "BB", "reason_code": "hypotension"},
                                          {"pillar": "MRA", "reason_code": "hyperkalaemia"},
                                          {"pillar": "RASI", "reason_code": "titration_in_progress"}]},
                   headers=as_user("rca"))
    assert r.status_code == 200
    row = db_admin.execute("SELECT pillars_eligible, pillars_prescribed, pillars_at_target FROM "
                           "registry.hf_assessment_data WHERE assessment_id = %s", (aid,)).fetchone()
    assert row == (4, 3, 1)


def test_gdmt_only_for_hf(client, as_user, idem):
    a = enrol_and_open_baseline(client, as_user, idem, "LIPID")
    state["lipid_assessment"] = a["assessment_id"]
    v = values(a["prefill"])
    assert v["ldl_c"]["value"] == 88 and v["ldl_method"]["value"] == "direct"
    assert v["lipid_test_date"]["value"] == "2026-11-18"
    assert v["statin_daily_dose"]["value"] == 40 and v["has_diabetes"]["value"] is True
    assert v["non_hdl_c"]["value"] == 108
    assert v["statin_drug"]["value"] == "ATORVASTATIN" and v["statin_intensity"]["value"] == "high"
    r = client.get(f"{API}/assessments/{a['assessment_id']}/hf/gdmt", headers=as_user("dra"))
    assert r.status_code == 409


# --- lipid targets -----------------------------------------------------------------

def test_lipid_targets_under_both_guidelines(client, as_user):
    url = f"{API}/assessments/{state['lipid_assessment']}/lipid/targets"
    r = client.get(url, headers=as_user("dra"))
    assert r.json()["items"] == []
    assert {g["rule_set_code"]: g["is_primary"] for g in r.json()["guidelines"]} == {"ESC_EAS_2019": True,
                                                                                    "LAI_2020": False}
    esc_cats = {c["risk_category"]: c["ldl_target_mg_dl"] for c in r.json()["guidelines"][0]["categories"]
                } if r.json()["guidelines"][0]["rule_set_code"] == "ESC_EAS_2019" else {}
    assert esc_cats.get("very_high") == 55 and esc_cats.get("extreme") == 40
    body = {"categories": [{"rule_set_code": "ESC_EAS_2019", "risk_category": "very_high"},
                           {"rule_set_code": "LAI_2020", "risk_category": "extreme_a"}]}
    r = client.put(url, json=body, headers=as_user("dra"))
    assert r.status_code == 200, r.json()
    rows = {x["rule_set_code"]: x for x in r.json()["items"]}
    esc, lai = rows["ESC_EAS_2019"], rows["LAI_2020"]
    assert esc["is_primary"] and esc["ldl_target_mg_dl"] == 55 and esc["ldl_mg_dl"] == 88
    assert esc["ldl_pct_reduction"] == 45 and esc["target_met"] is False
    assert lai["ldl_target_mg_dl"] == 50 and lai["target_met"] is False and lai["rule_set_status"] == "active"


def test_lipid_target_errors(client, as_user):
    url = f"{API}/assessments/{state['lipid_assessment']}/lipid/targets"
    r = client.put(url, json={"categories": [{"rule_set_code": "LAI_2020", "risk_category": "nonsense"}]},
                   headers=as_user("dra"))
    assert r.status_code == 428                      # changing a saved category needs a reason first
    r = client.put(url, json={"categories": [{"rule_set_code": "LAI_2020", "risk_category": "nonsense"}]},
                   headers=as_user("dra", x_change_reason="Recategorised after review"))
    assert r.status_code == 422 and code(r) == "RISK_CATEGORY_UNKNOWN"
    r = client.put(url, json={"categories": [{"rule_set_code": "NCEP_ATP3", "risk_category": "high"}]},
                   headers=as_user("dra"))
    assert r.status_code == 422 and code(r) == "VALIDATION_FAILED"
    r = client.put(url, json={"categories": [{"rule_set_code": "LAI_2020", "risk_category": "very_high"}]},
                   headers=as_user("dra", x_change_reason="Recategorised after review"))
    assert r.status_code == 200
    lai = next(x for x in r.json()["items"] if x["rule_set_code"] == "LAI_2020")
    assert lai["risk_category"] == "very_high" and lai["ldl_target_mg_dl"] == 50


def test_cad_baseline_antiplatelets(client, as_user, idem):
    a = enrol_and_open_baseline(client, as_user, idem, "CAD")
    v = values(a["prefill"])
    assert v["on_dapt"]["value"] is True and v["p2y12_agent"]["value"] == "clopidogrel"
    assert v["on_aspirin"]["value"] is True and v["on_acei_arb_arni"]["value"] is True


# --- PCI ---------------------------------------------------------------------------

PCI = {"procedure_date": "2026-11-20", "indication": "chronic_coronary_syndrome", "urgency": "elective",
       "access_site": "radial", "imaging_guidance": "IVUS", "procedural_success": True, "complications": ["none"],
       "lesions": [
           {"lesion_number": 1, "vessel": "LAD", "segment_code": "6", "lesion_type_acc_aha": "B2",
            "lesion_length_mm": 28, "reference_diameter_mm": 3.0, "pre_stenosis_pct": 90, "pre_timi_flow": 3,
            "is_bifurcation": True, "medina": "1,1,0", "bifurcation_technique": "provisional",
            "lesion_preparation": ["predilatation"], "final_timi_flow": 3, "residual_stenosis_pct": 0,
            "treatment": "stent",
            "stents": [{"sequence_number": 1, "device_text": "Generic DES", "diameter_mm": 3.0, "length_mm": 32},
                       {"sequence_number": 2, "device_text": "Generic DES", "diameter_mm": 3.5, "length_mm": 12}]},
           {"lesion_number": 2, "vessel": "RCA", "pre_stenosis_pct": 75, "treatment": "POBA", "final_timi_flow": 3}]}


def test_pci_create_and_read(client, as_user, idem):
    url = f"{API}/patients/{PATIENT2}/pci-procedures"
    assert client.post(url, json=PCI, headers={**as_user("nua"), **idem()}).status_code == 403
    bad = {**PCI, "lesions": [{**PCI["lesions"][0], "medina": None}]}
    r = client.post(url, json=bad, headers={**as_user("dra"), **idem()})
    assert r.status_code == 400
    key = idem()
    r = client.post(url, json=PCI, headers={**as_user("dra"), **key})
    assert r.status_code == 201, r.json()
    again = client.post(url, json=PCI, headers={**as_user("dra"), **key})
    assert again.json()["procedure_id"] == r.json()["procedure_id"]
    p = r.json()
    state["pci"], state["pci_etag"] = p["procedure_id"], r.headers["etag"]
    assert [l["vessel"] for l in p["lesions"]] == ["LAD", "RCA"]
    assert [s["length_mm"] for s in p["lesions"][0]["stents"]] == [32, 12] and p["lesions"][1]["stents"] == []
    r = client.get(f"{API}/pci-procedures/{state['pci']}", headers=as_user("nua"))
    assert r.status_code == 200 and r.json()["lesions"][0]["medina"] == "1,1,0"
    assert client.get(f"{API}/pci-procedures/{state['pci']}", headers=as_user("drb", centre=CENTRE_B)).status_code == 404
    r = client.get(url, headers=as_user("rca"))
    assert [x["procedure_id"] for x in r.json()["items"]] == [state["pci"]]


def test_pci_replace(client, as_user):
    url = f"{API}/pci-procedures/{state['pci']}"
    changed = {**PCI, "lesions": [
        {**PCI["lesions"][0], "stents": [PCI["lesions"][0]["stents"][0],
                                         {**PCI["lesions"][0]["stents"][1], "diameter_mm": 3.25}]},
        PCI["lesions"][1],
        {"lesion_number": 3, "vessel": "LCX", "treatment": "DCB"}]}
    r = client.put(url, json=changed, headers={**as_user("dra"), "If-Match": state["pci_etag"]})
    assert r.status_code == 428                      # a final procedure changes only with a reason
    h = as_user("dra", x_change_reason="Post-dilatation balloon size corrected")
    r = client.put(url, json=changed, headers={**h, "If-Match": '"99"'})
    assert r.status_code == 412
    r = client.put(url, json={**PCI, "lesions": [PCI["lesions"][0]]}, headers={**h, "If-Match": state["pci_etag"]})
    assert r.status_code == 422 and r.json()["errors"][0]["field"] == "lesion 2"
    r = client.put(url, json=changed, headers={**h, "If-Match": state["pci_etag"]})
    assert r.status_code == 200, r.json()
    p = r.json()
    assert p["row_version"] > int(state["pci_etag"].strip('"'))
    assert p["lesions"][0]["stents"][1]["diameter_mm"] == 3.25 and p["lesions"][2]["vessel"] == "LCX"
    assert len({s["stent_id"] for s in p["lesions"][0]["stents"]}) == 2
