-- CardioEMR migration 0007: acceptance tests.  Runs after test_0006 (same database).
\set ON_ERROR_STOP 1
\echo '--- 19. Migration 0007: web app support'
RESET ROLE; RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_assistant;
SELECT t_ok((SELECT count(*) FROM app.subject_memberships('oidc', 'sub-dra')) = 1
            AND (SELECT centre_code || ':' || role FROM app.subject_memberships('oidc', 'sub-dra')) = 'PUN1:clinician',
  'memberships: Dr A is a clinician at PUN1 only');
SELECT t_ok((SELECT count(*) FROM app.subject_memberships('oidc', 'sub-nobody')) = 0,
  'memberships: unknown subject returns nothing');
SELECT t_ok((SELECT centre_id IS NULL AND platform_role = 'platform_admin'
             FROM app.subject_memberships('oidc', 'sub-pa')),
  'memberships: platform admin with no centre role returns one row with no centre');
RESET ROLE; RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION cardioemr_api;
SELECT t_fails($$SELECT * FROM app.subject_memberships('oidc', 'sub-dra')$$,
  'memberships: the login role itself cannot call it', '42501');
RESET SESSION AUTHORIZATION;
-- A typed code ahead of the counter is skipped by the generator.
SELECT t_as('assistant','00000000-0000-0000-0000-0000000000d2','00000000-0000-0000-0000-00000000c0a1');
SELECT last_value + 1 AS next_n FROM clinical.centre_code_counters
 WHERE centre_id = '00000000-0000-0000-0000-00000000c0a1' \gset
SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_assistant;
INSERT INTO clinical.patients (patient_id) VALUES ('10000000-0000-0000-0000-000000000701');
INSERT INTO clinical.patient_registrations (patient_id, centre_id, local_patient_code, first_name, sex, date_of_birth)
VALUES ('10000000-0000-0000-0000-000000000701','00000000-0000-0000-0000-00000000c0a1',
        'PUN1-' || lpad(:'next_n', 6, '0'), 'Typed', 'female', '1970-01-01');
SELECT t_ok(clinical.next_local_patient_code() = 'PUN1-' || lpad((:'next_n'::int + 1)::text, 6, '0'),
  'generated local code skips a code already typed by hand');
RESET ROLE; RESET SESSION AUTHORIZATION;
SELECT t_ok(EXISTS (SELECT 1 FROM ref.api_error_map
                    WHERE source_name = 'patient_registrations_centre_id_local_patient_code_key'),
  'duplicate local code maps to a 409');
