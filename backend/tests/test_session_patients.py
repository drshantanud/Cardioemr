"""Web app foundation: who am I (/me), patient search, registration, overview and update."""
import uuid

from conftest import CENTRE_A, CENTRE_B, PATIENT

API = "/api/v1"


def code(r):
    return r.json().get("code")


def bearer(token, user):
    return {"Authorization": f"Bearer {token(user)}"}


# --- /me ----------------------------------------------------------------------

def test_me_lists_centres_and_roles(client, token):
    r = client.get(f"{API}/me", headers=bearer(token, "dra"))
    assert r.status_code == 200
    body = r.json()
    assert body["full_name"] == "Dr A"
    assert [c["centre_code"] for c in body["centres"]] == ["PUN1"]
    assert body["centres"][0]["roles"] == ["clinician"]
    assert body["centres"][0]["organisation_name"] == "Heart Clinic Pune"


def test_me_needs_no_centre_but_needs_a_token(client):
    assert client.get(f"{API}/me").status_code == 401


def test_me_suspended_user_is_401(client, token):
    assert client.get(f"{API}/me", headers=bearer(token, "sus")).status_code == 401


def test_me_unknown_subject_is_401(client, token):
    assert client.get(f"{API}/me", headers=bearer(token, "nobody")).status_code == 401


# --- search -------------------------------------------------------------------

def test_list_patients_at_own_centre(client, as_user):
    r = client.get(f"{API}/patients", headers=as_user("asa"))
    assert r.status_code == 200
    codes = {p["local_patient_code"] for p in r.json()["items"]}
    assert "PUN1-000001" in codes
    assert all(c.startswith("PUN1-") for c in codes)


def test_other_centre_sees_none_of_pune(client, as_user):
    r = client.get(f"{API}/patients", headers=as_user("drb", centre=CENTRE_B))
    assert r.status_code == 200
    assert not [p for p in r.json()["items"] if p["local_patient_code"].startswith("PUN1-")]


def test_search_by_name_code_and_mobile(client, as_user):
    h = as_user("asa")
    for q in ("ramesh", "Kulkarni", "PUN1-000001", "9822000001", "2000001"):
        items = client.get(f"{API}/patients", params={"q": q}, headers=h).json()["items"]
        assert "PUN1-000001" in [p["local_patient_code"] for p in items], q
    none = client.get(f"{API}/patients", params={"q": "zzzqqq"}, headers=h).json()
    assert none["items"] == [] and none["has_more"] is False


def test_search_wildcards_are_literal(client, as_user):
    items = client.get(f"{API}/patients", params={"q": "%"}, headers=as_user("asa")).json()["items"]
    assert items == []


def test_list_paging(client, as_user):
    h = as_user("asa")
    first = client.get(f"{API}/patients", params={"limit": 1}, headers=h).json()
    assert len(first["items"]) == 1 and first["has_more"] is True
    second = client.get(f"{API}/patients", params={"limit": 1, "offset": 1}, headers=h).json()
    assert second["items"][0]["patient_id"] != first["items"][0]["patient_id"]


def test_list_writes_access_log(client, as_user, db_admin):
    before = db_admin.execute("SELECT count(*) FROM audit.access_log WHERE access_type = 'search' "
                              "AND entity_name = 'clinical.patient_registrations'").fetchone()[0]
    client.get(f"{API}/patients", params={"q": "ram"}, headers=as_user("asa"))
    after = db_admin.execute("SELECT count(*) FROM audit.access_log WHERE access_type = 'search' "
                             "AND entity_name = 'clinical.patient_registrations'").fetchone()[0]
    assert after == before + 1


def test_centre_admin_cannot_list_patients(client, as_user):
    r = client.get(f"{API}/patients", headers=as_user("dra", role="centre_admin"))
    assert r.status_code == 403 and code(r) == "FORBIDDEN"


# --- registration -------------------------------------------------------------

NEW = {"first_name": "Anita", "last_name": "Joshi", "date_of_birth": "1971-05-20", "sex": "female",
       "mobile": "9822012345", "city": "Pune", "state_code": "MH", "pincode": "411001",
       "referral_source": "physician"}


def test_register_patient_generates_local_code(client, as_user, idem):
    r = client.post(f"{API}/patients", json=NEW, headers={**as_user("asa"), **idem()})
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["local_patient_code"].startswith("PUN1-")
    assert body["display_name"] == "Anita Joshi" and body["age_years"] >= 54
    assert r.headers["ETag"] == '"1"'
    got = client.get(f"{API}/patients/{body['patient_id']}", headers=as_user("asa"))
    assert got.status_code == 200 and got.json()["patient"]["mobile"] == "9822012345"


def test_register_is_idempotent(client, as_user):
    key = {"Idempotency-Key": uuid.uuid4().hex}
    body = {**NEW, "first_name": "Kiran", "mobile": "9822099999", "date_of_birth": "1980-01-01"}
    a = client.post(f"{API}/patients", json=body, headers={**as_user("asa"), **key})
    b = client.post(f"{API}/patients", json=body, headers={**as_user("asa"), **key})
    assert a.status_code == b.status_code == 201
    assert a.json()["patient_id"] == b.json()["patient_id"]


def test_possible_duplicate_needs_confirmation(client, as_user, idem):
    dup = {**NEW, "first_name": "Ramesh", "last_name": "Kulkarni", "date_of_birth": "1968-03-14", "sex": "male",
           "mobile": None}
    r = client.post(f"{API}/patients", json=dup, headers={**as_user("asa"), **idem()})
    assert r.status_code == 409 and code(r) == "POSSIBLE_DUPLICATE"
    assert r.json()["current"][0]["local_patient_code"] == "PUN1-000001"
    ok = client.post(f"{API}/patients", json={**dup, "confirm_not_duplicate": True},
                     headers={**as_user("asa"), **idem()})
    assert ok.status_code == 201


def test_duplicate_check_stays_inside_the_centre(client, as_user, idem):
    """Mumbai registering someone with Ramesh's mobile is not told Pune has him."""
    body = {**NEW, "first_name": "Ramesh", "last_name": "K", "mobile": "9822000001", "date_of_birth": "1968-03-14"}
    r = client.post(f"{API}/patients", json=body, headers={**as_user("drb", centre=CENTRE_B), **idem()})
    assert r.status_code == 201 and r.json()["local_patient_code"].startswith("MUM1-")


def test_register_with_age_only(client, as_user, idem):
    body = {"first_name": "Lakshmi", "age_years": 62, "sex": "female", "mobile": "9822077777"}
    r = client.post(f"{API}/patients", json=body, headers={**as_user("nua"), **idem()})
    assert r.status_code == 201, r.text
    assert r.json()["dob_precision"] == "estimated_from_age" and r.json()["age_years"] in (61, 62)


def test_register_needs_dob_or_age(client, as_user, idem):
    r = client.post(f"{API}/patients", json={"first_name": "X", "sex": "male"}, headers={**as_user("asa"), **idem()})
    assert r.status_code == 400 and code(r) == "VALIDATION_FAILED"


def test_register_rejects_bad_mobile_and_unknown_fields(client, as_user, idem):
    h = {**as_user("asa"), **idem()}
    assert client.post(f"{API}/patients", json={**NEW, "mobile": "12ab"}, headers=h).status_code == 400
    assert client.post(f"{API}/patients", json={**NEW, "religion": "x"}, headers=h).status_code == 400


def test_register_duplicate_local_code_is_409(client, as_user, idem):
    body = {**NEW, "first_name": "Vijay", "mobile": "9822055555", "local_patient_code": "PUN1-000001"}
    r = client.post(f"{API}/patients", json=body, headers={**as_user("asa"), **idem()})
    assert r.status_code == 409 and code(r) == "CONFLICT"


# --- overview by role ---------------------------------------------------------

def test_overview_for_clinician_includes_registry(client, as_user):
    r = client.get(f"{API}/patients/{PATIENT}", headers=as_user("dra"))
    assert r.status_code == 200
    body = r.json()
    assert body["patient"]["local_patient_code"] == "PUN1-000001"
    assert body["enrolments"] is not None
    assert {c["consent_type"] for c in body["consents"]} >= {"clinical_care", "research_registry"}
    assert any(c["protocol_code"] == "CEMR-HF" for c in body["consents"])


def test_overview_for_assistant_hides_registry(client, as_user):
    body = client.get(f"{API}/patients/{PATIENT}", headers=as_user("asa")).json()
    assert body["enrolments"] is None and body["registry_suggestions"] is None
    assert all(c["protocol_code"] is None for c in body["consents"])


def test_overview_other_centre_is_404(client, as_user):
    r = client.get(f"{API}/patients/{PATIENT}", headers=as_user("drb", centre=CENTRE_B))
    assert r.status_code == 404


# --- update -------------------------------------------------------------------

def _new(client, as_user, idem, **extra):
    body = {**NEW, "first_name": "Meera", "mobile": None, "date_of_birth": "1990-02-02", **extra}
    return client.post(f"{API}/patients", json=body, headers={**as_user("asa"), **idem()}).json()


def test_update_needs_change_reason_and_if_match(client, as_user, idem):
    p = _new(client, as_user, idem, last_name="Rao")
    url = f"{API}/patients/{p['patient_id']}"
    r = client.patch(url, json={"city": "Nashik"}, headers={**as_user("asa"), "If-Match": '"1"'})
    assert r.status_code == 428 and code(r) == "CHANGE_REASON_REQUIRED"
    r = client.patch(url, json={"city": "Nashik"},
                     headers={**as_user("asa"), "If-Match": '"1"', "X-Change-Reason": "Moved house"})
    assert r.status_code == 200 and r.json()["city"] == "Nashik" and r.headers["ETag"] == '"2"'
    stale = client.patch(url, json={"city": "Satara"},
                         headers={**as_user("asa"), "If-Match": '"1"', "X-Change-Reason": "Typo"})
    assert stale.status_code == 412 and code(stale) == "STALE_VERSION"


def test_update_cannot_clear_required_fields(client, as_user, idem):
    p = _new(client, as_user, idem, last_name="Iyer")
    r = client.patch(f"{API}/patients/{p['patient_id']}", json={"first_name": None},
                     headers={**as_user("asa"), "If-Match": '"1"', "X-Change-Reason": "Clear"})
    assert r.status_code == 400


def test_update_other_centre_is_404(client, as_user):
    r = client.patch(f"{API}/patients/{PATIENT}", json={"city": "X"},
                     headers={**as_user("drb", centre=CENTRE_B), "If-Match": '"1"', "X-Change-Reason": "Try"})
    assert r.status_code == 404


def test_centre_a_unchanged(client, as_user):
    r = client.get(f"{API}/patients/{PATIENT}", headers=as_user("dra", centre=CENTRE_A))
    assert r.json()["patient"]["first_name"] == "Ramesh"
