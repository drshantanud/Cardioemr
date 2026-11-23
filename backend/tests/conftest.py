"""Builds a fresh database from db/migrations, loads tests/fixtures.sql, and
runs the API against it as the real cardioemr_api login (RLS on).

Needs a PostgreSQL 16 server.  CEMR_TEST_ADMIN_URL must point at a superuser
connection on that server (default: postgres/postgres on localhost)."""
from __future__ import annotations

import os
import pathlib
import tempfile
import time
import uuid

import jwt
import psycopg
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.auth import TokenVerifier
from app.config import Settings
from app.main import create_app

ROOT = pathlib.Path(__file__).resolve().parents[2]
ADMIN_URL = os.environ.get("CEMR_TEST_ADMIN_URL", "postgresql://postgres:postgres@localhost:5432/postgres")
DB = "cemr_api_test"
API_PASSWORD = "cemr-api-test-only"
ISSUER, AUDIENCE = "https://idp.test/", "cardioemr-api"

CENTRE_A = "00000000-0000-0000-0000-00000000c0a1"
CENTRE_B = "00000000-0000-0000-0000-00000000c0b1"
PATIENT = "10000000-0000-0000-0000-000000000001"
PATIENT3 = "10000000-0000-0000-0000-000000000003"
HF_ENROLMENT3 = "1b000000-0000-0000-0000-000000000032"
CAD_ENROLMENT3 = "1b000000-0000-0000-0000-000000000034"
CAD_BASELINE3 = "1c000000-0000-0000-0000-000000000034"
HF_CONSENT = "15000000-0000-0000-0000-000000000002"
CARE_CONSENT = "15000000-0000-0000-0000-000000000001"
SUGGESTION = "18000000-0000-0000-0000-000000000001"
USERS = {"dra": "clinician", "asa": "assistant", "drb": "clinician", "pia": "principal_investigator",
         "rca": "research_coordinator", "nua": "nurse", "sus": "clinician"}


def _admin(dbname="postgres"):
    return psycopg.connect(ADMIN_URL.rsplit("/", 1)[0] + "/" + dbname, autocommit=True)


@pytest.fixture(scope="session")
def database():
    with _admin() as c:
        c.execute(f"DROP DATABASE IF EXISTS {DB} WITH (FORCE)")
        c.execute(f"CREATE DATABASE {DB}")
    with _admin(DB) as c:
        for f in sorted((ROOT / "db" / "migrations").glob("*.sql")):
            c.execute(f.read_text())
        c.execute((ROOT / "backend" / "tests" / "fixtures.sql").read_text())
        c.execute(f"ALTER ROLE cardioemr_api PASSWORD '{API_PASSWORD}'")
    host = ADMIN_URL.split("@", 1)[1].rsplit("/", 1)[0]
    yield f"postgresql://cardioemr_api:{API_PASSWORD}@{host}/{DB}"


class _StaticJwks:
    def __init__(self, public_key):
        self._key = public_key

    def get_signing_key_from_jwt(self, _token):
        return type("K", (), {"key": self._key})()


@pytest.fixture(scope="session")
def keypair():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture(scope="session")
def client(database, keypair):
    verifier = TokenVerifier(ISSUER, AUDIENCE, jwk_client=_StaticJwks(keypair.public_key()))
    settings = Settings(database_url=database, oidc_issuer=ISSUER, oidc_audience=AUDIENCE,
                        export_dir=tempfile.mkdtemp(prefix="cemr-exports-"))
    app = create_app(settings, verifier)
    with TestClient(app) as c:
        yield c


@pytest.fixture(scope="session")
def token(keypair):
    def make(sub: str, **overrides) -> str:
        now = int(time.time())
        claims = {"iss": ISSUER, "aud": AUDIENCE, "sub": f"sub-{sub}", "iat": now, "exp": now + 300, **overrides}
        return jwt.encode(claims, keypair, algorithm="RS256")
    return make


@pytest.fixture(scope="session")
def as_user(token):
    """Headers for a user acting in their fixture role at a centre (default Pune)."""
    def headers(user: str, role: str | None = None, centre: str = CENTRE_A, **extra) -> dict:
        h = {"Authorization": f"Bearer {token(user)}", "X-Centre-Id": centre, "X-Acting-Role": role or USERS[user]}
        h.update({k.replace("_", "-"): v for k, v in extra.items()})
        return h
    return headers


@pytest.fixture
def idem():
    return lambda: {"Idempotency-Key": uuid.uuid4().hex}


@pytest.fixture
def db_admin(database):
    with _admin(DB) as c:
        yield c
