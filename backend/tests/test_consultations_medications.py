"""Consultation notes, vitals, diagnoses, allergies and prescribing.

Each test works on patients it registers itself, so the registry fixtures
used by the other test files are left alone."""
import uuid

import pytest

from conftest import CENTRE_B, PATIENT

API = "/api/v1"


def code(r):
    return r.json().get("code")


def idem():
    return {"Idempotency-Key": uuid.uuid4().hex}


@pytest.fixture
def patient(client, as_user):
    body = {"first_name": "Test", "last_name": uuid.uuid4().hex[:8], "age_years": 60, "sex": "male"}
    r = client.post(f"{API}/patients", json=body, headers={**as_user("asa"), **idem()})
    assert r.status_code == 201, r.text
    return r.json()["patient_id"]


@pytest.fixture
def draft(client, as_user, patient):
    r = client.post(f"{API}/patients/{patient}/encounters", json={"encounter_type": "new_consultation"},
                    headers={**as_user("dra"), **idem()})
    assert r.status_code == 201, r.text
    return r.json()


def save(client, as_user, enc, body, user="dra"):
    return client.put(f"{API}/encounters/{enc['encounter_id']}", json=body,
                      headers={**as_user(user), "If-Match": f'"{enc["row_version"]}"'})


# --- consultations ------------------------------------------------------------------

def test_only_a_clinician_starts_a_consultation(client, as_user, patient):
    for user in ("asa", "nua", "rca"):
        r = client.post(f"{API}/patients/{patient}/encounters", json={}, headers={**as_user(user), **idem()})
        assert r.status_code == 403, user


def test_draft_save_with_complaints_and_assessment(client, as_user, draft):
    assert draft["status"] == "draft" and draft["clinician_name"] == "Dr A"
    body = {"note": {"history_present_illness": "Breathless on one flight of stairs for 3 weeks",
                     "assessment": "Decompensated HFrEF", "follow_up_date": "2026-12-20"},
            "complaints": [{"concept_code": "CX_DYSPNOEA", "duration_value": 3, "duration_unit": "weeks"},
                           {"concept_code": "CX_PEDAL_OEDEMA"}],
            "assessment": {"nyha_class": "III", "jvp": "raised", "peripheral_oedema": "ankle", "hf_phenotype": "HFrEF"}}
    r = save(client, as_user, draft, body)
    assert r.status_code == 200, r.text
    e = r.json()
    assert e["row_version"] == draft["row_version"] + 1 and r.headers["ETag"] == f'"{e["row_version"]}"'
    assert [c["concept_code"] for c in e["complaints"]] == ["CX_DYSPNOEA", "CX_PEDAL_OEDEMA"]
    assert e["clinical_assessment"]["nyha_class"] == "III"
    # Saving again replaces the complaint list and the assessment.
    r2 = save(client, as_user, e, {"complaints": [{"concept_code": "CX_FATIGUE"}],
                                   "assessment": {"nyha_class": "II"}})
    e2 = r2.json()
    assert [c["concept_code"] for c in e2["complaints"]] == ["CX_FATIGUE"]
    assert e2["clinical_assessment"]["nyha_class"] == "II" and e2["clinical_assessment"]["jvp"] is None
    assert e2["assessment"] == "Decompensated HFrEF"         # note fields not sent are kept


def test_stale_save_is_412(client, as_user, draft):
    assert save(client, as_user, draft, {"note": {"plan": "a"}}).status_code == 200
    r = save(client, as_user, draft, {"note": {"plan": "b"}})
    assert r.status_code == 412 and code(r) == "STALE_VERSION"


def test_unknown_complaint_is_rejected(client, as_user, draft):
    r = save(client, as_user, draft, {"complaints": [{"concept_code": "CX_NOPE"}]})
    assert r.status_code == 422


def test_nurse_can_edit_a_draft_but_not_sign(client, as_user, draft):
    r = save(client, as_user, draft, {"note": {"examination_other": "Weight up 2 kg"}}, user="nua")
    assert r.status_code == 200
    e = r.json()
    r = client.post(f"{API}/encounters/{e['encounter_id']}/sign", headers={**as_user("nua"), "If-Match": f'"{e["row_version"]}"'})
    assert r.status_code == 403


def test_sign_freezes_and_amendment_keeps_original(client, as_user, draft):
    empty = client.post(f"{API}/encounters/{draft['encounter_id']}/sign",
                        headers={**as_user("dra"), "If-Match": f'"{draft["row_version"]}"'})
    assert empty.status_code == 422
    e = save(client, as_user, draft, {"note": {"plan": "Start furosemide 40 mg OD"}}).json()
    r = client.post(f"{API}/encounters/{e['encounter_id']}/sign", headers={**as_user("dra"), "If-Match": f'"{e["row_version"]}"'})
    assert r.status_code == 200 and r.json()["status"] == "signed" and r.json()["signed_by_name"] == "Dr A"
    signed = r.json()
    r = save(client, as_user, signed, {"note": {"plan": "changed"}})
    assert r.status_code == 409 and code(r) == "ENCOUNTER_SIGNED"
    r = client.post(f"{API}/encounters/{e['encounter_id']}/amendments",
                    json={"field_name": "plan", "amended_value": "Start furosemide 20 mg OD", "reason": "Dose typo"},
                    headers=as_user("dra"))
    assert r.status_code == 201
    am = r.json()
    assert am["status"] == "amended" and am["plan"] == "Start furosemide 40 mg OD"
    assert am["amendments"][0]["previous_value"] == "Start furosemide 40 mg OD"
    assert am["amendments"][0]["amended_value"] == "Start furosemide 20 mg OD"


def test_complaints_on_signed_encounter_cannot_be_deleted_in_db(db_admin, client, as_user, draft):
    e = save(client, as_user, draft, {"complaints": [{"concept_code": "CX_SYNCOPE"}]}).json()
    client.post(f"{API}/encounters/{e['encounter_id']}/sign", headers={**as_user("dra"), "If-Match": f'"{e["row_version"]}"'})
    with db_admin.cursor() as cur:
        cur.execute("BEGIN")
        cur.execute("SET LOCAL ROLE r_clinician")
        cur.execute("SELECT set_config('app.user_id', '00000000-0000-0000-0000-0000000000d1', true), "
                    "set_config('app.centre_id', '00000000-0000-0000-0000-00000000c0a1', true)")
        cur.execute("SAVEPOINT s")
        with pytest.raises(Exception, match="signed encounter"):
            cur.execute("DELETE FROM clinical.encounter_complaints WHERE encounter_id = %s", (e["encounter_id"],))
        cur.execute("ROLLBACK")


def test_other_centre_cannot_read_consultation(client, as_user, draft):
    r = client.get(f"{API}/encounters/{draft['encounter_id']}", headers=as_user("drb", centre=CENTRE_B))
    assert r.status_code == 404


def test_list_encounters(client, as_user, draft):
    items = client.get(f"{API}/patients/{draft['patient_id']}/encounters", headers=as_user("asa")).json()["items"]
    assert items[0]["encounter_id"] == draft["encounter_id"]


# --- vitals, diagnoses, allergies ------------------------------------------------------

def test_vitals_with_bmi_and_into_draft(client, as_user, draft):
    pid = draft["patient_id"]
    r = client.post(f"{API}/patients/{pid}/vitals", json={"encounter_id": draft["encounter_id"], "height_cm": 170,
                    "weight_kg": 72, "systolic_bp": 118, "diastolic_bp": 76, "heart_rate": 64}, headers=as_user("asa"))
    assert r.status_code == 201, r.text
    assert r.json()["bmi"] == 24.9
    got = client.get(f"{API}/encounters/{draft['encounter_id']}", headers=as_user("dra")).json()
    assert got["vitals"][0]["systolic_bp"] == 118
    bad = client.post(f"{API}/patients/{pid}/vitals", json={"systolic_bp": 80, "diastolic_bp": 90}, headers=as_user("asa"))
    assert bad.status_code == 400
    assert client.post(f"{API}/patients/{pid}/vitals", json={}, headers=as_user("asa")).status_code == 400


def test_diagnosis_triggers_registry_suggestions(client, as_user, draft):
    pid = draft["patient_id"]
    r = client.post(f"{API}/patients/{pid}/diagnoses", json={"concept_code": "DX_ICM", "diagnosis_role": "final",
                    "is_principal": True, "encounter_id": draft["encounter_id"]}, headers=as_user("dra"))
    assert r.status_code == 201, r.text
    d = r.json()
    assert d["diagnosis_text"] == "Ischaemic cardiomyopathy"
    assert {s["registry_code"] for s in d["new_registry_suggestions"]} >= {"HF", "CAD"}
    r = client.patch(f"{API}/diagnoses/{d['diagnosis_id']}", json={"status": "resolved"},
                     headers={**as_user("dra"), "If-Match": f'"{d["row_version"]}"'})
    assert r.status_code == 200 and r.json()["status"] == "resolved" and r.json()["resolved_date"]


def test_typed_final_diagnosis_needs_icd10(client, as_user, patient):
    h = as_user("dra")
    r = client.post(f"{API}/patients/{patient}/diagnoses", json={"diagnosis_text": "Takotsubo", "diagnosis_role": "final"},
                    headers=h)
    assert r.status_code == 422
    r = client.post(f"{API}/patients/{patient}/diagnoses", json={"diagnosis_text": "Takotsubo", "diagnosis_role": "final",
                    "icd10_code": "I51.81"}, headers=h)
    assert r.status_code == 201
    r = client.post(f"{API}/patients/{patient}/diagnoses", json={"diagnosis_text": "Atypical chest pain",
                    "diagnosis_role": "working", "certainty": "suspected"}, headers=h)
    assert r.status_code == 201


def test_assistant_cannot_add_diagnosis(client, as_user, patient):
    r = client.post(f"{API}/patients/{patient}/diagnoses", json={"concept_code": "DX_HTN", "diagnosis_role": "comorbidity"},
                    headers=as_user("asa"))
    assert r.status_code == 403


def test_concepts_lookup(client, as_user):
    items = client.get(f"{API}/concepts", params={"domain": "complaint"}, headers=as_user("asa")).json()["items"]
    assert len(items) == 9 and {"concept_code": "CX_CHEST_PAIN"}.items() <= next(
        i for i in items if i["concept_code"] == "CX_CHEST_PAIN").items()
    dx = client.get(f"{API}/concepts", params={"domain": "diagnosis"}, headers=as_user("dra")).json()["items"]
    icm = next(i for i in dx if i["concept_code"] == "DX_ICM")
    assert set(icm["registry_triggers"]) == {"CAD", "HF", "LIPID"}


# --- prescribing ---------------------------------------------------------------------

def start(client, as_user, pid, **body):
    return client.post(f"{API}/patients/{pid}/medications", json=body, headers=as_user("dra"))


def test_drug_search_finds_products(client, as_user):
    items = client.get(f"{API}/drugs", params={"q": "sacu"}, headers=as_user("dra")).json()["items"]
    arni = items[0]
    assert arni["drug_code"] == "SACUBITRIL_VALSARTAN" and "ARNI" in arni["classes"]
    assert [p["strength_label"] for p in arni["products"]][0].startswith("12/13")
    assert client.get(f"{API}/drugs", params={"q": "amlod"}, headers=as_user("dra")).json()["items"][0]["drug_code"] \
        == "AMLODIPINE"


def test_prescribe_titrate_and_stop(client, as_user, draft):
    pid = draft["patient_id"]
    drugs = client.get(f"{API}/drugs", params={"q": "sacubitril"}, headers=as_user("dra")).json()["items"][0]
    p50 = next(p for p in drugs["products"] if p["reference_strength"] == 50)
    r = start(client, as_user, pid, drug_code="SACUBITRIL_VALSARTAN", product_id=p50["product_id"], dose_quantity=1,
              frequency_code="BD", encounter_id=draft["encounter_id"], indication="HFrEF")
    assert r.status_code == 201, r.text
    c = r.json()
    assert c["status"] == "active" and c["current_dose"]["daily_dose"] == 100
    assert c["current_dose"]["prescribed_by_name"] == "Dr A"
    assert start(client, as_user, pid, drug_code="SACUBITRIL_VALSARTAN", strength=50, dose_quantity=1,
                 frequency_code="BD").status_code == 409

    url = f"{API}/medication-courses/{c['course_id']}/events"
    up = client.post(url, json={"event_type": "dose_change", "reason_code": "RSN_TITRATION",
                                "dose": {"strength": 100, "strength_label": "49/51 mg", "dose_quantity": 1,
                                         "frequency_code": "BD"}}, headers=as_user("dra"))
    assert up.status_code == 201, up.text
    assert [e["event_type"] for e in up.json()["events"]] == ["initiate", "increase"]
    assert up.json()["current_dose"]["daily_dose"] == 200
    same = client.post(url, json={"event_type": "dose_change", "dose": {"strength": 100, "dose_quantity": 1,
                                  "frequency_code": "BD", "strength_label": "49/51 mg"}}, headers=as_user("dra"))
    assert same.status_code == 422
    nostop = client.post(url, json={"event_type": "discontinue"}, headers=as_user("dra"))
    assert nostop.status_code == 400
    stop = client.post(url, json={"event_type": "discontinue", "reason_code": "RSN_HYPOTENSION"}, headers=as_user("dra"))
    assert stop.status_code == 201 and stop.json()["status"] == "stopped" and stop.json()["stopped_on"]
    # Every event is kept.
    assert len(stop.json()["events"]) == 3
    enc = client.get(f"{API}/encounters/{draft['encounter_id']}", headers=as_user("dra")).json()
    assert enc["medication_events"][0]["generic_name"] == "Sacubitril/valsartan"


def test_daily_dose_arithmetic(client, as_user, patient):
    r = start(client, as_user, patient, drug_code="CARVEDILOL", strength=3.125, dose_quantity=2, frequency_code="BD")
    assert r.json()["current_dose"]["daily_dose"] == 12.5
    r = start(client, as_user, patient, drug_code="EVOLOCUMAB", strength=140, dose_quantity=1, dose_unit="injection",
              frequency_code="Q2W", route="sc")
    assert r.status_code == 201 and r.json()["current_dose"]["daily_dose"] == 10
    r = start(client, as_user, patient, drug_code="GLYCERYL_TRINITRATE", strength=0.5, dose_quantity=1,
              frequency_code="SOS")
    assert r.status_code == 422
    r = start(client, as_user, patient, drug_code="GLYCERYL_TRINITRATE", strength=0.5, dose_quantity=1,
              frequency_code="SOS", doses_per_day=1)
    assert r.status_code == 201 and r.json()["current_dose"]["route"] == "sublingual"
    r = start(client, as_user, patient, drug_code="ASPIRIN", dose_quantity=75, dose_unit="mg", frequency_code="OD")
    assert r.json()["current_dose"]["daily_dose"] == 75
    r = start(client, as_user, patient, drug_code="ATORVASTATIN", dose_quantity=1, frequency_code="HS")
    assert r.status_code == 422          # tablet without strength


def test_allergy_blocks_prescription(client, as_user, patient):
    r = client.post(f"{API}/patients/{patient}/allergies", json={"allergen_type": "drug_class",
                    "drug_class_code": "STATIN", "allergen_text": "Statins", "reaction": "Myositis",
                    "severity": "severe"}, headers=as_user("asa"))
    assert r.status_code == 201
    r = start(client, as_user, patient, drug_code="ROSUVASTATIN", strength=10, dose_quantity=1, frequency_code="OD")
    assert r.status_code == 409 and code(r) == "ALLERGY"


def test_typed_drug_allergy_and_beta_blocker_class_block_prescription(client, as_user, patient):
    def allergy(**b):
        r = client.post(f"{API}/patients/{patient}/allergies", json=b, headers=as_user("asa"))
        assert r.status_code == 201, r.text
    # Typed by name, not picked from the catalogue: still blocks the drug it names.
    allergy(allergen_type="drug", allergen_text="Amiodarone (thyroid)")
    r = start(client, as_user, patient, drug_code="AMIODARONE", strength=200, dose_quantity=1, frequency_code="OD")
    assert r.status_code == 409 and code(r) == "ALLERGY"
    # A beta-blocker class allergy covers atenolol, which sits outside the HF beta-blocker class.
    allergy(allergen_type="drug_class", drug_class_code="BETA_BLOCKER", allergen_text="Beta-blockers")
    r = start(client, as_user, patient, drug_code="ATENOLOL", strength=50, dose_quantity=1, frequency_code="OD")
    assert r.status_code == 409 and code(r) == "ALLERGY"
    r = start(client, as_user, patient, drug_code="AMLODIPINE", strength=5, dose_quantity=1, frequency_code="OD")
    assert r.status_code == 201, r.text


def test_hold_resume_and_void(client, as_user, patient):
    c = start(client, as_user, patient, drug_code="SPIRONOLACTONE", strength=25, dose_quantity=1,
              frequency_code="OD").json()
    url = f"{API}/medication-courses/{c['course_id']}/events"
    held = client.post(url, json={"event_type": "hold", "reason_code": "RSN_HYPERKALAEMIA"}, headers=as_user("dra"))
    assert held.json()["status"] == "on_hold"
    resumed = client.post(url, json={"event_type": "resume"}, headers=as_user("dra")).json()
    assert resumed["status"] == "active" and resumed["current_dose"]["daily_dose"] == 25
    stopped = client.post(url, json={"event_type": "discontinue", "reason_text": "K 6.1"}, headers=as_user("dra")).json()
    stop_event = stopped["events"][-1]
    assert stop_event["event_type"] == "discontinue"
    v = client.post(f"{API}/medication-events/{stop_event['medication_event_id']}/void",
                    json={"reason_text": "Wrong patient"}, headers=as_user("dra"))
    assert v.status_code == 201
    assert v.json()["status"] == "active" and v.json()["stopped_on"] is None
    again = client.post(f"{API}/medication-events/{stop_event['medication_event_id']}/void",
                        json={"reason_text": "Wrong patient"}, headers=as_user("dra"))
    assert again.status_code == 409


def test_only_clinicians_prescribe(client, as_user, patient):
    r = client.post(f"{API}/patients/{patient}/medications", json={"drug_code": "ASPIRIN", "dose_quantity": 75,
                    "dose_unit": "mg", "frequency_code": "OD"}, headers=as_user("nua"))
    assert r.status_code == 403
    assert client.get(f"{API}/patients/{patient}/medications", headers=as_user("nua")).status_code == 200


def test_clinical_summary(client, as_user):
    """Patient 2 in the fixtures has labs, an echo, vitals, diagnoses and medicines."""
    s = client.get(f"{API}/patients/10000000-0000-0000-0000-000000000002/clinical-summary", headers=as_user("dra"))
    assert s.status_code == 200, s.text
    body = s.json()
    assert body["latest_echo"]["lvef"] is not None
    assert body["medications"] and all("current_dose" in m for m in body["medications"])
    assert body["latest_vitals"] is not None
    assert {"diagnoses", "allergies", "latest_labs", "latest_ecg", "last_signed_encounter"} <= set(body)


def test_clinical_summary_other_centre(client, as_user):
    r = client.get(f"{API}/patients/{PATIENT}/clinical-summary", headers=as_user("drb", centre=CENTRE_B))
    assert r.status_code == 404
