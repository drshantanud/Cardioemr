#!/usr/bin/env bash
# Runs the whole stack on this machine for development:
#   PostgreSQL database cemr_dev (migrations + backend/tests/fixtures.sql test users and patients)
#   dev sign-in server   http://localhost:9400
#   API (FastAPI)        http://localhost:8000
#   web app (Next.js)    http://localhost:3000
# Needs PostgreSQL 16, Python 3.12+ with backend/requirements.txt, Node 20+ with `npm install` done in web/.
#   CEMR_DEV_ADMIN_URL   superuser connection (default postgresql://postgres:postgres@localhost:5432/postgres)
#   CEMR_DEV_RESET=1     rebuild the database even if it exists
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADMIN_URL="${CEMR_DEV_ADMIN_URL:-postgresql://postgres:postgres@localhost:5432/postgres}"
DB=cemr_dev
API_PASSWORD=cemr-dev-only
BASE="${ADMIN_URL%/*}"
HOSTPART="${ADMIN_URL#*@}"; HOSTPART="${HOSTPART%/*}"

if [[ "${CEMR_DEV_RESET:-0}" == 1 ]] || ! psql "$ADMIN_URL" -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1; then
  echo "building database $DB"
  psql "$ADMIN_URL" -q -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" -c "CREATE DATABASE $DB"
  for f in "$ROOT"/db/migrations/*.sql; do psql "$BASE/$DB" -q -v ON_ERROR_STOP=1 -f "$f" >/dev/null; done
  psql "$BASE/$DB" -q -v ON_ERROR_STOP=1 -f "$ROOT/backend/tests/fixtures.sql" >/dev/null
  psql "$BASE/$DB" -q -c "ALTER ROLE cardioemr_api PASSWORD '$API_PASSWORD'"
fi

pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT INT TERM

(cd "$ROOT/web" && node dev/dev-idp.mjs) & pids+=($!)
(cd "$ROOT/backend" && \
  CEMR_DATABASE_URL="postgresql://cardioemr_api:$API_PASSWORD@$HOSTPART/$DB" \
  CEMR_OIDC_ISSUER="http://localhost:9400/" CEMR_OIDC_AUDIENCE=cardioemr-api \
  CEMR_OIDC_JWKS_URL="http://localhost:9400/jwks" CEMR_EXPORT_DIR="${TMPDIR:-/tmp}/cemr-dev-exports" \
  python -m uvicorn app.main:create_app --factory --port 8000) & pids+=($!)
(cd "$ROOT/web" && CEMR_API_URL=http://localhost:8000 npx next dev --port 3000) & pids+=($!)
wait
