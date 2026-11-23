"""Settings read from the environment.  Nothing here has a production default
for secrets: the database URL and the identity provider must be configured."""
from dataclasses import dataclass, field
import os


@dataclass(frozen=True)
class Settings:
    database_url: str = field(default_factory=lambda: os.environ.get("CEMR_DATABASE_URL", ""))
    # OIDC: tokens are RS256/ES256 JWTs signed by the identity provider.
    oidc_issuer: str = field(default_factory=lambda: os.environ.get("CEMR_OIDC_ISSUER", ""))
    oidc_audience: str = field(default_factory=lambda: os.environ.get("CEMR_OIDC_AUDIENCE", "cardioemr-api"))
    oidc_jwks_url: str = field(default_factory=lambda: os.environ.get("CEMR_OIDC_JWKS_URL", ""))
    auth_provider: str = field(default_factory=lambda: os.environ.get("CEMR_AUTH_PROVIDER", "oidc"))
    pool_min: int = field(default_factory=lambda: int(os.environ.get("CEMR_DB_POOL_MIN", "1")))
    pool_max: int = field(default_factory=lambda: int(os.environ.get("CEMR_DB_POOL_MAX", "10")))
    # Research exports: where finished files are kept, and the key that signs download links.
    # With no CEMR_EXPORT_DIR an approved export fails with a clear reason; with no URL key a
    # random key is made at start-up (links then stop working on restart).
    export_dir: str = field(default_factory=lambda: os.environ.get("CEMR_EXPORT_DIR", ""))
    export_url_key: str = field(default_factory=lambda: os.environ.get("CEMR_EXPORT_URL_KEY", ""))
    export_retention_days: int = field(default_factory=lambda: int(os.environ.get("CEMR_EXPORT_RETENTION_DAYS", "7")))
    export_link_minutes: int = 15


def get_settings() -> Settings:
    return Settings()
