-- CardioEMR migration 0009: acceptance tests.  Runs after test_0008 (same database).
\set ON_ERROR_STOP 1
\echo '--- 21. Migration 0009: protocol names for the follow-up report'
RESET ROLE; RESET SESSION AUTHORIZATION;
SELECT t_as('nurse','00000000-0000-0000-0000-0000000000d7','00000000-0000-0000-0000-00000000c0a1');
SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_nurse;
SELECT t_ok((SELECT array_agg(protocol_code) FROM registry.centre_protocols()) @> ARRAY['CEMR-HF'],
  'a nurse lists the protocols active at the centre');
SELECT t_fails($$SELECT count(*) FROM registry.registry_protocols$$, 'a nurse still cannot read protocols', '42501');
SELECT t_fails($$SELECT * FROM registry._centre_protocols('00000000-0000-0000-0000-00000000c0b1')$$,
  'a nurse cannot list another centre''s protocols', '42501');
RESET ROLE; SET ROLE r_assistant;
SELECT t_fails($$SELECT * FROM registry.centre_protocols()$$, 'assistants cannot list protocols', '42501');
RESET ROLE; RESET SESSION AUTHORIZATION;
