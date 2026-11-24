"""Migration 0006 through the API: reports, unit conversion, events and adjudication, exports.
Uses patient 3 (fixtures.sql): enrolled in HF and CAD 200 days ago at Pune, CAD baseline open."""
import csv
import io
import json
import zipfile
from datetime import date, timedelta

from conftest import CAD_BASELINE3, CAD_ENROLMENT3, CENTRE_B, PATIENT3

API = "/api/v1"
S: dict = {}
TODAY = date.today()


def code(r):
    return r.json().get("code")


def test_protocol_ids(client, as_user):
    regs = {x["registry_code"]: x for x in client.get(f"{API}/registries", headers=as_user("dra")).json()["items"]}
    S["hf"] = regs["HF"]["protocols"][0]["protocol_id"]
    S["cad"] = regs["CAD"]["protocols"][0]["protocol_id"]


# --- follow-up and missing data ---------------------------------------------------

def test_follow_up_due_for_nurse(client, as_user):
    r = client.get(f"{API}/protocols/{S['cad']}/follow-up-due?within_days=14", headers=as_user("nua"))
    assert r.status_code == 200, r.text
    mine = [i for i in r.json()["items"] if i["patient_id"] == PATIENT3]
    # Day 200 after index: M1 (day 30, window to 44) is overdue; M6 (day 180, window 150-210) is due.
    by_code = {i["visit_code"]: i for i in mine}
    assert by_code["M1"]["status"] == "overdue" and by_code["M6"]["status"] == "due"
    assert "BL" not in by_code                         # baseline has an assessment
    assert by_code["M6"]["patient_name"] == "Vasant Joshi" and by_code["M6"]["mobile"] == "9822000003"
    assert by_code["M6"]["local_patient_code"] == "PUN1-000003"
    r = client.get(f"{API}/protocols/{S['cad']}/follow-up-due?include_overdue=false", headers=as_user("nua"))
    assert all(i["status"] != "overdue" for i in r.json()["items"])


def test_follow_up_due_isolated_by_centre(client, as_user):
    r = client.get(f"{API}/protocols/{S['cad']}/follow-up-due", headers=as_user("drb", centre=CENTRE_B))
    assert r.status_code == 200 and all(i["patient_id"] != PATIENT3 for i in r.json()["items"])


def test_follow_up_due_not_for_assistant(client, as_user):
    r = client.get(f"{API}/protocols/{S['cad']}/follow-up-due", headers=as_user("asa"))
    assert r.status_code == 403


def test_missing_data_report(client, as_user):
    r = client.get(f"{API}/protocols/{S['cad']}/missing-data?visit_code=BL", headers=as_user("rca"))
    assert r.status_code == 200, r.text
    body = r.json()
    rows = {i["variable_code"]: i for i in body["items"]}
    assert "presentation" in rows and CAD_BASELINE3 in rows["presentation"]["assessment_ids"]
    assert body["totals"]["missing"] >= len(rows) > 10
    visit = next(a for a in body["by_assessment"] if a["assessment_id"] == CAD_BASELINE3)
    assert visit["local_patient_code"] == "PUN1-000003" and visit["visit_code"] == "BL"
    assert 0 < visit["missing"] <= visit["mandatory_values"] and visit["patient_id"] == PATIENT3
    assert client.get(f"{API}/protocols/{S['cad']}/missing-data", headers=as_user("nua")).status_code == 403


# --- unit conversion on entry -------------------------------------------------------

def test_dictionary_lists_accepted_units(client, as_user):
    items = client.get(f"{API}/protocols/{S['cad']}/data-dictionary", headers=as_user("dra")).json()["items"]
    units = {i["variable_code"]: i["accepted_units"] for i in items}
    assert units["ldl_c"][0] == "mg/dL" and "mmol/L" in units["ldl_c"]
    assert units["creatinine"][0] == "mg/dL" and "umol/L" in units["creatinine"]
    assert "lb" in units["weight_kg"] and units["egfr"] == ["mL/min/1.73m2"]
    assert units["presentation"] is None


def test_values_entered_in_other_units(client, as_user):
    r = client.put(f"{API}/assessments/{CAD_BASELINE3}/values", headers=as_user("rca"), json={"values": [
        {"variable_code": "ldl_c", "value": 2.6, "unit": "mmol/L"},
        {"variable_code": "creatinine", "value": 88, "unit": "µmol/L"},
        {"variable_code": "weight_kg", "value": 154, "unit": "lb"},
        {"variable_code": "haemoglobin", "value": 13.1, "unit": "g/dL"}]})
    assert r.status_code == 200, r.text
    v = {i["variable_code"]: i for i in r.json()["items"]}
    assert v["ldl_c"]["value"] == 100.54 and v["ldl_c"]["entered_value"] == 2.6 and v["ldl_c"]["entered_unit"] == "mmol/L"
    assert v["creatinine"]["value"] == 1.0
    assert v["weight_kg"]["value"] == 69.85
    assert v["haemoglobin"]["value"] == 13.1 and v["haemoglobin"]["entered_unit"] is None


def test_unit_that_cannot_convert(client, as_user):
    r = client.put(f"{API}/assessments/{CAD_BASELINE3}/values", headers=as_user("rca"), json={"values": [
        {"variable_code": "hdl_c", "value": 1.1, "unit": "mg%"},
        {"variable_code": "triglycerides", "value": 1.5, "unit": "mmol/L"}]})
    assert r.status_code == 422
    errs = {e["variable_code"]: e["rule"] for e in r.json()["errors"]}
    assert errs == {"hdl_c": "UNIT_NOT_CONVERTIBLE"}     # nothing saved: triglycerides rolled back too


def test_converted_value_still_range_checked(client, as_user):
    r = client.put(f"{API}/assessments/{CAD_BASELINE3}/values", headers=as_user("rca"), json={"values": [
        {"variable_code": "hdl_c", "value": 50, "unit": "mmol/L"}]})   # 1933 mg/dL
    assert r.status_code == 422 and r.json()["errors"][0]["rule"] == "VALUE_OUT_OF_RANGE"


# --- events and adjudication ------------------------------------------------------------

def _event(client, as_user, idem, user, **body):
    base = {"patient_id": PATIENT3, "source": "hospital_records"}
    return client.post(f"{API}/events", headers={**as_user(user), **idem()}, json={**base, **body})


def test_nurse_reports_mi(client, as_user, idem):
    r = _event(client, as_user, idem, "nua", event_type="mi", event_date=str(TODAY - timedelta(days=150)),
               mi_type="1", hospitalised=True, admission_date=str(TODAY - timedelta(days=150)))
    assert r.status_code == 201, r.text
    assert r.json()["adjudications"] == []                 # nurses do not see registry adjudication
    S["mi"] = r.json()["event"]["event_id"]
    r = client.get(f"{API}/events/{S['mi']}", headers=as_user("pia"))
    adj = r.json()["adjudications"]
    assert [(a["protocol_code"], a["endpoint_code"], a["adjudication_status"]) for a in adj] == [
        ("CEMR-CAD", "MI", "pending")]
    assert adj[0]["event_day"] == 50 and adj[0]["study_subject_code"].startswith("CAD-")


def test_death_opens_one_adjudication_per_protocol(client, as_user, idem):
    r = _event(client, as_user, idem, "rca", event_type="death", event_date=str(TODAY - timedelta(days=5)),
               death_cause="cardiovascular", death_cv_mode="sudden", source="relative_report")
    assert r.status_code == 201, r.text
    S["death"] = r.json()["event"]["event_id"]
    got = sorted((a["protocol_code"], a["endpoint_code"]) for a in r.json()["adjudications"])
    assert got == [("CEMR-CAD", "CVD"), ("CEMR-HF", "CVD")]          # all-cause death needs no adjudication


def test_historical_event_opens_nothing(client, as_user, idem):
    r = _event(client, as_user, idem, "dra", event_type="pci", event_date="2019-06-01", is_historical=True,
               event_date_precision="month", source="patient_report")
    assert r.status_code == 201 and r.json()["adjudications"] == []


def test_event_rules(client, as_user, idem):
    r = _event(client, as_user, idem, "dra", event_type="death", event_date=str(TODAY), death_cause="non_cardiovascular")
    assert r.status_code == 409 and code(r) == "CONFLICT"            # one death per patient
    r = _event(client, as_user, idem, "dra", event_type="stroke", event_date=str(TODAY), death_cause="cardiovascular")
    assert r.status_code == 422                                      # death cause on a stroke
    r = _event(client, as_user, idem, "dra", event_type="mi", event_date=str(TODAY + timedelta(days=2)))
    assert r.status_code == 400                                      # future date
    r = _event(client, as_user, idem, "asa", event_type="mi", event_date=str(TODAY))
    assert r.status_code == 403


def test_other_centre_cannot_see_event(client, as_user):
    assert client.get(f"{API}/events/{S['mi']}", headers=as_user("drb", centre=CENTRE_B)).status_code == 404


def test_adjudication_queue(client, as_user):
    r = client.get(f"{API}/protocols/{S['cad']}/adjudication-queue", headers=as_user("pia"))
    assert r.status_code == 200
    items = r.json()["items"]
    assert [i["endpoint_code"] for i in items if i["event_id"] in (S["mi"], S["death"])] == ["MI", "CVD"]
    r = client.get(f"{API}/protocols/{S['cad']}/adjudication-queue?limit=1", headers=as_user("pia"))
    assert len(r.json()["items"]) == 1 and r.json()["next_cursor"]
    r2 = client.get(f"{API}/protocols/{S['cad']}/adjudication-queue?limit=1&cursor={r.json()['next_cursor']}",
                    headers=as_user("pia"))
    assert r2.json()["items"][0]["adjudication_id"] != r.json()["items"][0]["adjudication_id"]


def _adj(client, as_user, event_id, protocol_code, endpoint_code, user="pia"):
    r = client.get(f"{API}/events/{event_id}", headers=as_user(user))
    return next(a for a in r.json()["adjudications"]
                if a["protocol_code"] == protocol_code and a["endpoint_code"] == endpoint_code)


def test_reporter_cannot_adjudicate(client, as_user, idem):
    r = _event(client, as_user, idem, "dra", event_type="bleeding", event_date=str(TODAY - timedelta(days=60)),
               bleeding_site="gastrointestinal", severity="moderate", hospitalised=True)
    S["bleed"] = r.json()["event"]["event_id"]
    a = _adj(client, as_user, S["bleed"], "CEMR-CAD", "BLEED_BARC35", user="dra")
    r = client.put(f"{API}/events/{S['bleed']}/adjudications/{a['adjudication_id']}",
                   headers={**as_user("dra"), "If-Match": f'"{a["row_version"]}"'},
                   json={"adjudication_status": "adjudicated", "classification": "3a"})
    assert r.status_code == 422 and code(r) == "ADJUDICATOR_CONFLICT"
    r = client.put(f"{API}/events/{S['bleed']}/adjudications/{a['adjudication_id']}",
                   headers={**as_user("rca"), "If-Match": f'"{a["row_version"]}"'},
                   json={"adjudication_status": "adjudicated", "classification": "3a"})
    assert r.status_code == 403


def test_classification_decides_the_endpoint(client, as_user):
    a = _adj(client, as_user, S["bleed"], "CEMR-CAD", "BLEED_BARC35")
    url = f"{API}/events/{S['bleed']}/adjudications/{a['adjudication_id']}"
    h = {**as_user("pia"), "If-Match": f'"{a["row_version"]}"'}
    r = client.put(url, headers=h, json={"adjudication_status": "adjudicated", "classification": "type 3a"})
    assert r.status_code == 422 and code(r) == "CLASSIFICATION_INVALID"
    r = client.put(url, headers=h, json={"adjudication_status": "adjudicated", "classification": "2",
                                         "meets_endpoint": True})
    assert r.status_code == 422 and code(r) == "CLASSIFICATION_INVALID"
    r = client.put(url, headers=h, json={"adjudication_status": "adjudicated", "classification": "3a",
                                         "endpoint_code": "BLEED_BARC35", "committee_reference": "CEC-01"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["meets_endpoint"] is True and body["adjudicated_by"] == "00000000-0000-0000-0000-0000000000d4"
    S["bleed_adj"] = body


def test_changing_a_decision_needs_a_reason(client, as_user):
    a = S["bleed_adj"]
    url = f"{API}/events/{S['bleed']}/adjudications/{a['adjudication_id']}"
    body = {"adjudication_status": "adjudicated", "classification": "2"}
    r = client.put(url, headers={**as_user("pia"), "If-Match": f'"{a["row_version"]}"'}, json=body)
    assert r.status_code == 428
    r = client.put(url, headers={**as_user("pia"), "If-Match": f'"{a["row_version"]}"',
                                 "X-Change-Reason": "Hb drop was 2.1 g/dL on review"}, json=body)
    assert r.status_code == 200 and r.json()["meets_endpoint"] is False
    r = client.put(url, headers={**as_user("pia"), "If-Match": f'"{a["row_version"]}"',
                                 "X-Change-Reason": "again"}, json=body)
    assert r.status_code == 412


def test_mi_and_death_adjudicated(client, as_user):
    for ev, proto, ep, body in ((S["mi"], "CEMR-CAD", "MI", {"classification": "1"}),
                                (S["death"], "CEMR-CAD", "CVD", {"classification": "cardiovascular"}),
                                (S["death"], "CEMR-HF", "CVD", {"classification": "cardiovascular"})):
        a = _adj(client, as_user, ev, proto, ep)
        r = client.put(f"{API}/events/{ev}/adjudications/{a['adjudication_id']}",
                       headers={**as_user("pia"), "If-Match": f'"{a["row_version"]}"'},
                       json={"adjudication_status": "adjudicated", **body})
        assert r.status_code == 200 and r.json()["meets_endpoint"] is True, r.text
    r = client.get(f"{API}/protocols/{S['cad']}/adjudication-queue?status=adjudicated", headers=as_user("pia"))
    assert {i["endpoint_code"] for i in r.json()["items"] if i["event_id"] in (S["mi"], S["death"])} == {"MI", "CVD"}


def test_classification_codes_for_the_form(client, as_user):
    r = client.get(f"{API}/adjudication-classifications", headers=as_user("pia"))
    assert r.status_code == 200
    barc = [i["code"] for i in r.json()["items"] if i["classification_system"] == "BARC"]
    assert "3a" in barc and "5b" in barc
    assert client.get(f"{API}/adjudication-classifications", headers=as_user("nua")).status_code == 403


def test_changed_event_reopens_adjudication(client, as_user):
    r = client.get(f"{API}/events/{S['bleed']}", headers=as_user("dra"))
    ev, tag = r.json()["event"], r.headers["etag"]
    body = {k: ev[k] for k in ("event_date", "event_date_precision", "is_historical", "description", "hospitalised",
                               "admission_date", "discharge_date", "facility_name", "severity", "outcome",
                               "death_cause", "death_cv_mode", "mi_type", "stroke_type", "bleeding_site",
                               "pci_procedure_id", "target_lesion_id", "potassium_mmol_l", "creatinine_result_id",
                               "source", "source_document_id")}
    body["severity"] = "life_threatening"
    r = client.put(f"{API}/events/{S['bleed']}", headers={**as_user("dra"), "If-Match": tag}, json=body)
    assert r.status_code == 428
    r = client.put(f"{API}/events/{S['bleed']}", headers={**as_user("dra"), "If-Match": tag,
                                                         "X-Change-Reason": "Discharge summary received"}, json=body)
    assert r.status_code == 200, r.text
    a = next(x for x in r.json()["adjudications"] if x["endpoint_code"] == "BLEED_BARC35")
    assert a["adjudication_status"] == "pending" and a["meets_endpoint"] is None
    S["bleed_body"], S["bleed_tag"] = body, r.headers["etag"]


def test_entered_in_error_withdraws_adjudications(client, as_user):
    r = client.put(f"{API}/events/{S['bleed']}", headers={**as_user("dra"), "If-Match": S["bleed_tag"],
                                                         "X-Change-Reason": "Duplicate of hospital record"},
                   json={**S["bleed_body"], "status": "entered_in_error"})
    assert r.status_code == 200
    a = r.json()["adjudications"][0]
    assert a["adjudication_status"] == "event_withdrawn"
    r = client.put(f"{API}/events/{S['bleed']}/adjudications/{a['adjudication_id']}",
                   headers={**as_user("pia"), "If-Match": f'"{a["row_version"]}"'},
                   json={"adjudication_status": "not_an_event"})
    assert r.status_code == 409 and code(r) == "EVENT_WITHDRAWN"
    r = client.get(f"{API}/patients/{PATIENT3}/events", headers=as_user("nua"))
    assert S["bleed"] not in [e["event_id"] for e in r.json()["items"]]


def test_prefill_counts_events_since_last_visit(client, as_user, idem):
    r = client.post(f"{API}/enrolments/{CAD_ENROLMENT3}/assessments", headers={**as_user("rca"), **idem()},
                    json={"visit_code": "M6", "assessment_type": "scheduled", "contact_mode": "records_review",
                          "assessment_date": str(TODAY - timedelta(days=1)), "prefill": True})
    assert r.status_code == 201, r.text
    filled = {f["variable_code"]: f["value"] for f in r.json()["prefill"]["filled"]}
    skipped = {s["variable_code"]: s["reason"] for s in r.json()["prefill"]["skipped"]}
    assert filled["mi_since_last"] is True and filled["cv_death"] is True
    assert filled["stroke_since_last"] is False and filled["major_bleeding_since_last"] is False
    assert skipped["tlr_since_last"] == "not_automated_yet"


def test_follow_up_stops_after_death(client, as_user):
    r = client.get(f"{API}/protocols/{S['hf']}/follow-up-due?within_days=180", headers=as_user("nua"))
    death = str(TODAY - timedelta(days=5))
    mine = [i for i in r.json()["items"] if i["patient_id"] == PATIENT3]
    assert mine and all(i["window_opens"] <= death and i["death_reported_on"] == death for i in mine)


# --- exports -------------------------------------------------------------------------------

EXPORT = {"purpose": "Interim CAD outcome analysis for the steering committee",
          "variable_codes": ["presentation", "ldl_c", "weight_kg", "index_event_date", "mi_since_last"],
          "deidentification": "pseudonymised_relative_days", "file_format": "csv"}


def test_export_request_validation(client, as_user, idem):
    r = client.post(f"{API}/exports", headers={**as_user("rca"), **idem()},
                    json={**EXPORT, "protocol_id": S["cad"], "variable_codes": ["ldl_c", "lvef_typo"]})
    assert r.status_code == 422 and r.json()["errors"][0]["variable_code"] == "lvef_typo"
    r = client.post(f"{API}/exports", headers={**as_user("dra"), **idem()}, json={**EXPORT, "protocol_id": S["cad"]})
    assert r.status_code == 403                                   # clinicians do not export
    r = client.post(f"{API}/exports", headers={**as_user("rca"), **idem()},
                    json={**EXPORT, "protocol_id": S["cad"], "cohort_filter": {"sex": "male"}})
    assert r.status_code == 400


def test_export_four_eyes_and_generation(client, as_user, idem):
    r = client.post(f"{API}/exports", headers={**as_user("rca"), **idem()}, json={**EXPORT, "protocol_id": S["cad"]})
    assert r.status_code == 201, r.text
    job = r.json()
    assert job["status"] == "requested" and job["requested_role"] == "research_coordinator"
    url = f"{API}/exports/{job['export_id']}/decision"
    r = client.post(url, headers={**as_user("rca"), "If-Match": f'"{job["row_version"]}"'}, json={"decision": "approved"})
    assert r.status_code == 403                                   # coordinators cannot decide
    r = client.post(url, headers={**as_user("pia"), "If-Match": f'"{job["row_version"]}"'},
                    json={"decision": "approved", "note": "Within approved analysis plan"})
    assert r.status_code == 200 and r.json()["approved_by"] == "00000000-0000-0000-0000-0000000000d4"
    r = client.get(f"{API}/exports/{job['export_id']}", headers=as_user("rca"))
    done = r.json()
    assert done["status"] == "completed", done
    assert done["row_count"] >= 2 and len(done["file_sha256"]) == 64 and done["download_url"]
    assert client.get(f"{API}/exports/{job['export_id']}", headers=as_user("pia")).json()["download_url"] is None
    S["export"] = done


def test_export_download_and_contents(client, as_user):
    link = S["export"]["download_url"].split("/api/v1", 1)[1]
    assert client.get(f"{API}{link}", headers=as_user("pia")).status_code == 403     # only the requester
    bad = link.replace("sig=", "sig=x")
    assert client.get(f"{API}{bad}", headers=as_user("rca")).status_code == 403
    r = client.get(f"{API}{link}", headers=as_user("rca"))
    assert r.status_code == 200 and r.headers["content-type"] == "application/zip"
    z = zipfile.ZipFile(io.BytesIO(r.content))
    assert set(z.namelist()) == {"subjects.csv", "visits.csv", "events.csv", "endpoints.csv", "data_dictionary.csv",
                                 "manifest.json"}
    everything = b"".join(z.read(n) for n in z.namelist()).decode()
    for identifier in ("Vasant", "Joshi", "9822000003", "PUN1-000003", "1931", str(TODAY - timedelta(days=200))):
        assert identifier not in everything
    subjects = list(csv.DictReader(io.StringIO(z.read("subjects.csv").decode())))
    s3 = next(s for s in subjects if s["age_at_index"] == "90")       # born 1931: top-coded
    visits = [v for v in csv.DictReader(io.StringIO(z.read("visits.csv").decode()))
              if v["study_subject_code"] == s3["study_subject_code"]]
    bl = next(v for v in visits if v["visit_code"] == "BL")
    assert bl["ldl_c"] == "100.54" and bl["weight_kg"] == "69.85" and bl["presentation"] == ""
    m6 = next(v for v in visits if v["visit_code"] == "M6")
    assert m6["mi_since_last"] == "1"
    eps = {(e["study_subject_code"], e["endpoint_code"]): e
           for e in csv.DictReader(io.StringIO(z.read("endpoints.csv").decode()))}
    mace = eps[(s3["study_subject_code"], "MACE3")]
    assert mace["had_event"] == "1" and mace["time_days"] == "50"     # first MACE = the MI on day 50
    assert eps[(s3["study_subject_code"], "BLEED_BARC35")]["had_event"] == "0"
    manifest = json.loads(z.read("manifest.json"))
    assert manifest["centres"] == ["PUN1"] or "PUN1" in manifest["centres"]


def test_requester_cannot_approve_own_export(client, as_user, idem):
    r = client.post(f"{API}/exports", headers={**as_user("pia"), **idem()},
                    json={**EXPORT, "protocol_id": S["hf"], "variable_codes": ["nyha_class"]})
    assert r.status_code == 201
    r = client.post(f"{API}/exports/{r.json()['export_id']}/decision",
                    headers={**as_user("pia"), "If-Match": f'"{r.json()["row_version"]}"'}, json={"decision": "approved"})
    assert r.status_code == 422 and code(r) == "FOUR_EYES"


def test_aggregate_export_suppresses_small_cells(client, as_user, idem):
    r = client.post(f"{API}/exports", headers={**as_user("rca"), **idem()},
                    json={**EXPORT, "protocol_id": S["cad"], "deidentification": "aggregate_only", "file_format": "xlsx"})
    job = r.json()
    client.post(f"{API}/exports/{job['export_id']}/decision",
                headers={**as_user("pia"), "If-Match": f'"{job["row_version"]}"'}, json={"decision": "approved"})
    done = client.get(f"{API}/exports/{job['export_id']}", headers=as_user("rca")).json()
    assert done["status"] == "completed", done
    r = client.get(f"{API}{done['download_url'].split('/api/v1', 1)[1]}", headers=as_user("rca"))
    from openpyxl import load_workbook
    wb = load_workbook(io.BytesIO(r.content))
    assert {"subject_summary", "variable_summary", "endpoint_summary", "data_dictionary", "manifest"} <= set(wb.sheetnames)
    assert "visits" not in wb.sheetnames and "subjects" not in wb.sheetnames
    n = [row for row in wb["subject_summary"].iter_rows(values_only=True)][1]
    assert n[0] == "n_subjects" and n[2] == "<5"


def test_stata_and_spss_formats(client, as_user, idem):
    for fmt, extra in (("stata_csv", None), ("spss_csv", "labels.sps")):
        r = client.post(f"{API}/exports", headers={**as_user("rca"), **idem()},
                        json={**EXPORT, "protocol_id": S["cad"], "file_format": fmt,
                              "deidentification": "pseudonymised_year_only"})
        job = r.json()
        client.post(f"{API}/exports/{job['export_id']}/decision",
                    headers={**as_user("pia"), "If-Match": f'"{job["row_version"]}"'}, json={"decision": "approved"})
        done = client.get(f"{API}/exports/{job['export_id']}", headers=as_user("rca")).json()
        r = client.get(f"{API}{done['download_url'].split('/api/v1', 1)[1]}", headers=as_user("rca"))
        z = zipfile.ZipFile(io.BytesIO(r.content))
        visits = z.read("visits.csv").decode()
        if fmt == "stata_csv":
            assert ",.," in visits or visits.rstrip().endswith(".")       # empty cells are '.'
        else:
            assert extra in z.namelist() and "VARIABLE LABELS" in z.read(extra).decode()
        row = next(v for v in csv.DictReader(io.StringIO(visits)) if v["visit_code"] == "BL"
                   and v["ldl_c"] == "100.54")
        assert row is not None


def test_export_access_logged(db_admin):
    n = db_admin.execute("SELECT count(*) FROM audit.access_log WHERE access_type = 'export_download'").fetchone()[0]
    assert n >= 3
    rows = db_admin.execute("SELECT status FROM research.export_jobs").fetchall()
    assert {"completed", "requested"} <= {r[0] for r in rows}
