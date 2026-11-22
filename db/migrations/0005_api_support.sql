-- =====================================================================
-- CardioEMR  migration 0005_api_support   (2026-11-22)
-- What the registry API needs from the database to open a request:
--   1. app.resolve_subject: maps the token's (provider, subject) to an
--      active user, without giving application roles read access to all
--      of iam.users.
--   2. api.idempotency_keys: stores the first response to a POST so a
--      retried request with the same Idempotency-Key returns it again.
-- =====================================================================
SET check_function_bodies = off;

-- 1. Token subject -> user ------------------------------------------
CREATE OR REPLACE FUNCTION app.resolve_subject(p_provider text, p_subject text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, iam AS $$
  SELECT user_id FROM iam.users
   WHERE auth_provider = p_provider AND auth_subject = p_subject AND status = 'active'
$$;
REVOKE EXECUTE ON FUNCTION app.resolve_subject(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.resolve_subject(text, text) TO r_assistant, r_nurse, r_clinician,
  r_research_coordinator, r_principal_investigator, r_centre_admin, r_platform_admin, r_audit_reader;

-- 2. Idempotency ------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS api;
REVOKE ALL ON SCHEMA api FROM PUBLIC;
CREATE TABLE api.idempotency_keys (
  user_id        uuid NOT NULL DEFAULT app.current_user_id(),
  idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 16 AND 64),
  method         text NOT NULL,
  path           text NOT NULL,
  request_sha256 bytea NOT NULL,
  response_status smallint NOT NULL,
  response_body  jsonb NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, idempotency_key)
);
CREATE INDEX idempotency_keys_created ON api.idempotency_keys (created_at);
ALTER TABLE api.idempotency_keys ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_keys ON api.idempotency_keys
  USING (user_id = app.current_user_id()) WITH CHECK (user_id = app.current_user_id());
GRANT USAGE ON SCHEMA api TO r_assistant, r_nurse, r_clinician, r_research_coordinator,
  r_principal_investigator, r_centre_admin, r_platform_admin;
GRANT SELECT, INSERT ON api.idempotency_keys TO r_assistant, r_nurse, r_clinician, r_research_coordinator,
  r_principal_investigator, r_centre_admin, r_platform_admin;
-- Keys older than 24 hours are ignored by the API and removed by a nightly job run as the owner.

-- 3. Visit schedule facts --------------------------------------------
-- Nurses book follow-up visits but have no grant on registry tables.  This
-- returns only what a schedule needs (index date, visit windows, which
-- visits have an assessment and its status) for an enrolment at the
-- caller's active centre; no clinical values.
CREATE OR REPLACE FUNCTION registry.schedule_facts(p_enrolment uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$ SELECT registry._schedule_facts(app.visible_centre(), p_enrolment) $$;
CREATE OR REPLACE FUNCTION registry._schedule_facts(p_centre uuid, p_enrolment uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, registry AS $$
DECLARE e record;
BEGIN
  IF NOT app._centre_arg_ok(p_centre) THEN
    RAISE EXCEPTION 'no active centre' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT enrolment_id, protocol_id, index_date INTO e FROM registry.enrolments
   WHERE enrolment_id = p_enrolment AND centre_id = p_centre;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'index_date', e.index_date,
    'visits', (SELECT coalesce(jsonb_agg(jsonb_build_object('visit_code', visit_code, 'target_day', target_day,
                 'window_before_days', window_before_days, 'window_after_days', window_after_days,
                 'repeats_every_days', repeats_every_days) ORDER BY sort_order), '[]')
                 FROM registry.visit_schedule WHERE protocol_id = e.protocol_id),
    'assessments', (SELECT coalesce(jsonb_agg(jsonb_build_object('assessment_id', assessment_id,
                 'visit_code', visit_code, 'assessment_date', assessment_date,
                 'completion_status', completion_status) ORDER BY assessment_date), '[]')
                 FROM registry.assessments WHERE enrolment_id = e.enrolment_id
                  AND assessment_type IN ('baseline','scheduled')));
END $$;
REVOKE EXECUTE ON FUNCTION registry._schedule_facts(uuid, uuid), registry.schedule_facts(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION registry._schedule_facts(uuid, uuid), registry.schedule_facts(uuid)
  TO r_nurse, r_clinician, r_research_coordinator, r_principal_investigator;
