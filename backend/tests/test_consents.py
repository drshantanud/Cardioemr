"""Recording and withdrawing consent, and what a protocol shows for screening."""
import uuid
from datetime import date, timedelta

import pytest

API = "/api/v1"
HF_PROTOCOL_CODE = "CEMR-HF"


def idem():
    return {"Idempotency-Key": uuid.uuid4().hex}


@pytest.fixture
def patient(client, as_user):
    body = {"first_name": "Consent", "last_name": uuid.uuid4().hex[:8], "age_years": 55, "sex": "female"}
    r = client.post(f"{API}/patients", json=body, headers={**as_user("asa"), **idem()})
    assert r.status_code == 201, r.text
    return r.json()["patient_id"]


def hf_protocol(client, as_user):
    regs = client.get(f"{API}/registries", headers=as_user("rca")).json()["items"]
    return next(p for r in regs for p in r["protocols"] if p["protocol_code"] == HF_PROTOCOL_CODE)["protocol_id"]


def research(protocol_id, **kw):
    return {"consent_type": "research_registry", "protocol_id": protocol_id, "consent_form_version": "ICF v1.0",
            "consent_date": date.today().isoformat(), "consent_method": "written", **kw}


def test_protocol_shows_criteria(client, as_user):
    pid = hf_protocol(client, as_user)
    p = client.get(f"{API}/protocols/{pid}", headers=as_user("dra")).json()
    assert p["inclusion_text"].startswith("Age >= 18") and p["exclusion_text"]
    assert p["requires_research_consent"] is True


def test_research_consent_enrol_then_withdraw_ends_enrolment(client, as_user, patient):
    pid = hf_protocol(client, as_user)
    # The assistant may record clinical-care consent but not research consent.
    r = client.post(f"{API}/patients/{patient}/consents", headers={**as_user("asa"), **idem()},
                    json={"consent_type": "clinical_care", "consent_form_version": "v2", "consent_method": "written",
                          "consent_date": date.today().isoformat()})
    assert r.status_code == 201, r.text
    assert client.post(f"{API}/patients/{patient}/consents", json=research(pid),
                       headers={**as_user("asa"), **idem()}).status_code == 403
    r = client.post(f"{API}/patients/{patient}/consents", json=research(pid, consent_language="Marathi"),
                    headers={**as_user("rca"), **idem()})
    assert r.status_code == 201, r.text
    consent = r.json()
    assert consent["protocol_code"] == HF_PROTOCOL_CODE and consent["consent_status"] == "active"
    # A second active consent for the same protocol is refused.
    assert client.post(f"{API}/patients/{patient}/consents", json=research(pid),
                       headers={**as_user("rca"), **idem()}).status_code == 409
    overview = client.get(f"{API}/patients/{patient}", headers=as_user("rca")).json()
    assert any(c["consent_id"] == consent["consent_id"] for c in overview["consents"])

    e = client.post(f"{API}/enrolments", json={"patient_id": patient, "protocol_id": pid},
                    headers={**as_user("dra"), **idem()}).json()
    e = client.put(f"{API}/enrolments/{e['enrolment_id']}/eligibility",
                   json={"eligibility_status": "eligible", "checklist": [{"criterion_code": "INC_1", "answer": "yes"}]},
                   headers={**as_user("dra"), "If-Match": f'"{e["row_version"]}"'}).json()
    r = client.post(f"{API}/enrolments/{e['enrolment_id']}/enrol",
                    json={"index_date": date.today().isoformat(), "consent_id": consent["consent_id"],
                          "details": {"registry_code": "HF", "hf_status_at_enrolment": "prevalent",
                                      "primary_aetiology": "ischaemic", "baseline_phenotype": "HFrEF",
                                      "baseline_lvef": 30}},
                    headers={**as_user("dra"), "If-Match": f'"{e["row_version"]}"'})
    assert r.status_code == 200, r.text

    url = f"{API}/consents/{consent['consent_id']}/withdraw"
    body = {"withdrawal_date": date.today().isoformat(), "withdrawal_scope": "no_further_collection",
            "withdrawal_reason": "Moving away"}
    h = {**as_user("rca"), "If-Match": f'"{consent["row_version"]}"'}
    assert client.post(url, json=body, headers=h).status_code == 428          # needs a change reason
    bad = {**body, "withdrawal_date": (date.today() + timedelta(days=2)).isoformat()}
    assert client.post(url, json=bad, headers={**h, "X-Change-Reason": "Patient asked"}).status_code == 422
    r = client.post(url, json=body, headers={**h, "X-Change-Reason": "Patient asked"})
    assert r.status_code == 200, r.text
    assert r.json()["consent_status"] == "withdrawn"
    enr = client.get(f"{API}/enrolments/{e['enrolment_id']}", headers=as_user("dra")).json()
    assert enr["enrolment_status"] == "withdrawn"


def test_consent_shape_is_checked(client, as_user, patient):
    pid = hf_protocol(client, as_user)
    bad = [
        {"consent_type": "clinical_care", "protocol_id": pid, "consent_form_version": "v1",
         "consent_date": date.today().isoformat(), "consent_method": "written"},
        research(pid, signed_by="legally_authorised_rep"),
        research(pid, consent_date=(date.today() + timedelta(days=1)).isoformat()),
    ]
    for b in bad:
        assert client.post(f"{API}/patients/{patient}/consents", json=b,
                           headers={**as_user("rca"), **idem()}).status_code == 400, b


def test_other_centre_cannot_record_consent(client, as_user, patient):
    from conftest import CENTRE_B
    r = client.post(f"{API}/patients/{patient}/consents",
                    json={"consent_type": "clinical_care", "consent_form_version": "v1", "consent_method": "written",
                          "consent_date": date.today().isoformat()},
                    headers={**as_user("drb", centre=CENTRE_B), **idem()})
    assert r.status_code == 404
