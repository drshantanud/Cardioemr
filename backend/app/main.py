"""CardioEMR registry API (contract: api/registry-api-v0.1.yaml)."""
from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from psycopg_pool import ConnectionPool

from .auth import TokenVerifier
from .config import Settings, get_settings
from .errors import ErrorMap, install_handlers
from .routers import assessments, enrolment, events, exports, hf_lipid, me, patients, pci, protocols, reports


def load_error_map(pool: ConnectionPool) -> ErrorMap:
    with pool.connection() as conn, conn.transaction():
        conn.execute("SET LOCAL ROLE r_clinician")   # the login role itself reads nothing
        rows = conn.execute("SELECT source_kind, source_name, error_code, http_status, title "
                            "FROM ref.api_error_map").fetchall()
    return ErrorMap(rows)


def create_app(settings: Settings | None = None, verifier: TokenVerifier | None = None) -> FastAPI:
    settings = settings or get_settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if not settings.database_url:
            raise RuntimeError("CEMR_DATABASE_URL is not set")
        pool = ConnectionPool(settings.database_url, min_size=settings.pool_min, max_size=settings.pool_max,
                              kwargs={"autocommit": True}, open=True)
        app.state.pool = pool
        app.state.error_map = load_error_map(pool)
        app.state.verifier = verifier or TokenVerifier(settings.oidc_issuer, settings.oidc_audience,
                                                       settings.oidc_jwks_url)
        yield
        pool.close()

    app = FastAPI(title="CardioEMR Registry API", version="0.1.0", lifespan=lifespan,
                  openapi_url="/api/v1/openapi.json", docs_url="/api/v1/docs")
    app.state.settings = settings
    install_handlers(app)
    for r in (me.router, patients.router, protocols.router, enrolment.router, assessments.router, hf_lipid.router, pci.router, events.router,
              reports.router, exports.router):
        app.include_router(r, prefix="/api/v1")
    return app
