-- CardioEMR migration 0003: acceptance tests.  Runs after test_0001 and test_0002 on the same database.
\set ON_ERROR_STOP 1

-- Runs a statement that must fail with the given 'cemr:' error tag in HINT.
CREATE OR REPLACE FUNCTION public.t_hint(p_sql text, p_name text, p_tag text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_hint text; v_msg text;
BEGIN
  EXECUTE p_sql;
  RAISE NOTICE 'FAIL  % (statement succeeded)', p_name;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT, v_msg = MESSAGE_TEXT;
  IF v_hint = 'cemr:' || p_tag THEN RAISE NOTICE 'PASS  % [%: %]', p_name, v_hint, v_msg;
  ELSE RAISE NOTICE 'FAIL  % (got hint %, %)', p_name, v_hint, v_msg; END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.t_hint(text, text, text) TO PUBLIC;

\echo '--- 14. Migration 0003: CAD data dictionary'
SELECT t_ok((SELECT count(*) FROM registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id)
             WHERE t.registry_code = 'CAD') = 94, 'CAD dictionary has 94 variables');
SELECT t_ok((SELECT count(DISTINCT pv.variable_id) FROM registry.protocol_variables pv
             JOIN registry.registry_protocols p USING (protocol_id) WHERE p.protocol_code = 'CEMR-CAD') = 94,
  'every CAD variable is collected by CEMR-CAD v1');
SELECT t_ok(NOT EXISTS (SELECT 1 FROM registry.protocol_variables pv JOIN registry.registry_protocols p USING (protocol_id)
             WHERE p.protocol_code = 'CEMR-CAD' AND pv.visit_code <> '*'
               AND NOT EXISTS (SELECT 1 FROM registry.visit_schedule vs WHERE vs.protocol_id = p.protocol_id
                               AND vs.visit_code = pv.visit_code)), 'every CAD visit code exists in the CAD visit schedule');
SELECT t_ok((SELECT count(*) FROM registry.protocol_variables pv JOIN registry.registry_protocols p USING (protocol_id)
             JOIN registry.variable_definitions d USING (variable_id)
             WHERE p.protocol_code = 'CEMR-CAD' AND pv.visit_code IN ('M1','M6','M12','ANNUAL') AND pv.requirement = 'mandatory'
               AND d.variable_code IN ('vital_status','cv_death','mi_since_last','stroke_since_last','tlr_since_last',
                 'tvr_since_last','any_revasc_since_last','stent_thrombosis_since_last','major_bleeding_since_last',
                 'hf_hospitalisation_since_last')) = 40, 'PRD 6.5 outcomes are mandatory at every follow-up visit');
SELECT t_ok((SELECT array_agg(a->>'code' ORDER BY a->>'code') FROM registry.variable_definitions d
             JOIN registry.registry_types t USING (registry_type_id), jsonb_array_elements(d.allowed_values) a
             WHERE t.registry_code = 'CAD' AND d.variable_code = 'presentation')
          = (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY['chronic_coronary_syndrome','STEMI','NSTEMI','unstable_angina',
             'prior_mi_stable','prior_revascularisation_stable','other']) x),
  'dictionary presentation codes match cad_enrolment_details');
SELECT t_ok((SELECT count(*) FROM ref.drug_class_members WHERE drug_class_code = 'ANTICOAGULANT') = 6,
  'six oral anticoagulants in the catalogue for on_oac');

\echo '--- 15. Migration 0003: error tags the API maps'
SELECT t_ok(NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace,
       regexp_matches(p.prosrc, 'cemr:([A-Z_]+)', 'g') m
  WHERE n.nspname IN ('registry','clinical','app')
    AND NOT EXISTS (SELECT 1 FROM ref.api_error_map e WHERE e.source_kind = 'hint' AND e.source_name = 'cemr:' || m[1])),
  'every HINT tag raised by a function is in ref.api_error_map');
SELECT t_ok(NOT EXISTS (
  SELECT 1 FROM ref.api_error_map e WHERE e.source_kind = 'constraint'
    AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conname = e.source_name)
    AND NOT EXISTS (SELECT 1 FROM pg_class i WHERE i.relkind = 'i' AND i.relname = e.source_name)),
  'every mapped constraint or index exists');

-- CAD fixture, as the migration owner: protocol active at centre A, PI holds a role there.
UPDATE registry.registry_protocols SET status = 'active', approved_at = now(),
  approved_by = '00000000-0000-0000-0000-0000000000d5' WHERE protocol_code = 'CEMR-CAD';
INSERT INTO registry.protocol_sites (protocol_id, centre_id, ethics_approval_ref, site_status)
SELECT protocol_id, '00000000-0000-0000-0000-00000000c0a1', 'EC/2027/003', 'active' FROM registry.registry_protocols
 WHERE protocol_code = 'CEMR-CAD';
INSERT INTO iam.user_centre_roles (user_id, organisation_id, centre_id, role) VALUES
 ('00000000-0000-0000-0000-0000000000d4','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c0a1',
  'principal_investigator');

SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_clinician;
SELECT t_as('clinician','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-00000000c0a1');
SELECT t_hint($$INSERT INTO registry.enrolments (patient_id, centre_id, registry_type_id, protocol_id, enrolment_date,
  index_date, eligibility_status, eligibility_confirmed_by, enrolled_by, enrolment_status, consent_id)
  SELECT '10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1', registry_type_id, protocol_id,
  current_date, current_date, 'eligible', '00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000d1','enrolled',
  '15000000-0000-0000-0000-000000000002' FROM registry.registry_protocols WHERE protocol_code = 'CEMR-CAD'$$,
  'HF research consent does not cover CAD enrolment', 'CONSENT_REQUIRED');
INSERT INTO clinical.patient_consents (consent_id, patient_id, centre_id, consent_type, protocol_id, consent_form_version,
  consent_date, consent_method)
SELECT '15000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  'research_registry', protocol_id, 'CAD-ICF v1.0', current_date, 'written'
FROM registry.registry_protocols WHERE protocol_code = 'CEMR-CAD';
INSERT INTO registry.enrolments (enrolment_id, patient_id, centre_id, registry_type_id, protocol_id, enrolment_date,
  index_date, eligibility_status, eligibility_confirmed_by, enrolled_by, enrolment_status, consent_id)
SELECT '16000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  registry_type_id, protocol_id, current_date, current_date - 5, 'eligible', '00000000-0000-0000-0000-0000000000d1',
  '00000000-0000-0000-0000-0000000000d1','enrolled','15000000-0000-0000-0000-000000000003'
FROM registry.registry_protocols WHERE protocol_code = 'CEMR-CAD';
INSERT INTO registry.cad_enrolment_details (enrolment_id, patient_id, centre_id, presentation, categories, index_event_date,
  killip_class_at_presentation, initial_strategy)
VALUES ('16000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  'NSTEMI', ARRAY['acute_coronary_syndrome','NSTEMI','multivessel'], current_date - 5, 'I', 'pci');
INSERT INTO registry.assessments (assessment_id, enrolment_id, patient_id, centre_id, visit_code, assessment_type, assessment_date)
VALUES ('17000000-0000-0000-0000-000000000003','16000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','BL','baseline', current_date);
SELECT t_ok((SELECT within_window FROM registry.assessments WHERE assessment_id = '17000000-0000-0000-0000-000000000003'),
  'CAD baseline on day 5 is inside its 0 to +14 window');

-- CAD values through the generic validator, with tags.
INSERT INTO registry.variable_values (assessment_id, patient_id, centre_id, variable_id, numeric_value)
SELECT '17000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  variable_id, 2 FROM registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id)
 WHERE t.registry_code = 'CAD' AND d.variable_code = 'pci_stents_count';
INSERT INTO registry.variable_values (assessment_id, patient_id, centre_id, variable_id, coded_values)
SELECT '17000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  variable_id, ARRAY['LAD','RCA'] FROM registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id)
 WHERE t.registry_code = 'CAD' AND d.variable_code = 'diseased_vessels';
SELECT t_ok((SELECT count(*) FROM registry.variable_values WHERE assessment_id = '17000000-0000-0000-0000-000000000003') = 2,
  'CAD values saved (stent count, diseased vessels)');
SELECT t_hint($$INSERT INTO registry.variable_values (assessment_id, patient_id, centre_id, variable_id, numeric_value)
  SELECT '17000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  variable_id, 140 FROM registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id)
  WHERE t.registry_code = 'CAD' AND d.variable_code = 'lvef'$$, 'CAD LVEF 140% rejected', 'VALUE_OUT_OF_RANGE');
SELECT t_hint($$INSERT INTO registry.variable_values (assessment_id, patient_id, centre_id, variable_id, coded_value)
  SELECT '17000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  variable_id, 'V' FROM registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id)
  WHERE t.registry_code = 'CAD' AND d.variable_code = 'killip_class'$$, 'Killip V rejected', 'CODE_NOT_ALLOWED');
SELECT t_hint($$INSERT INTO registry.variable_values (assessment_id, patient_id, centre_id, variable_id, coded_values)
  SELECT '17000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  variable_id, ARRAY['LAD','OM'] FROM registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id)
  WHERE t.registry_code = 'CAD' AND d.variable_code = 'diseased_vessels'$$, 'diseased_vessels takes only LM, LAD, LCX, RCA',
  'CODE_NOT_ALLOWED');
SELECT t_hint($$INSERT INTO registry.variable_values (assessment_id, patient_id, centre_id, variable_id, numeric_value)
  SELECT '17000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  variable_id, 2.5 FROM registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id)
  WHERE t.registry_code = 'CAD' AND d.variable_code = 'pci_lesions_treated'$$, '2.5 lesions rejected', 'WRONG_VALUE_TYPE');

\echo '--- 16. Migration 0003: lock and unlock'
SELECT t_hint($$UPDATE registry.assessments SET locked_at = now() WHERE assessment_id = '17000000-0000-0000-0000-000000000003'$$,
  'clinician cannot lock', 'LOCK_ROLE');
RESET ROLE; SET ROLE r_research_coordinator;
SELECT t_as('research_coordinator','00000000-0000-0000-0000-0000000000d7','00000000-0000-0000-0000-00000000c0a1');
SELECT t_hint($$UPDATE registry.assessments SET locked_at = now() WHERE assessment_id = '17000000-0000-0000-0000-000000000003'$$,
  'partial assessment cannot be locked', 'ASSESSMENT_INCOMPLETE');
UPDATE registry.assessments SET completion_status = 'complete', completed_by = '00000000-0000-0000-0000-0000000000d7'
 WHERE assessment_id = '17000000-0000-0000-0000-000000000003';
UPDATE registry.variable_values SET verification_status = 'queried'
 WHERE assessment_id = '17000000-0000-0000-0000-000000000003' AND coded_values IS NOT NULL;
SELECT t_hint($$UPDATE registry.assessments SET locked_at = now() WHERE assessment_id = '17000000-0000-0000-0000-000000000003'$$,
  'assessment with an open query cannot be locked', 'OPEN_QUERIES');
UPDATE registry.variable_values SET verification_status = 'verified'
 WHERE assessment_id = '17000000-0000-0000-0000-000000000003';
UPDATE registry.assessments SET locked_at = now() WHERE assessment_id = '17000000-0000-0000-0000-000000000003';
SELECT t_ok((SELECT locked_by FROM registry.assessments WHERE assessment_id = '17000000-0000-0000-0000-000000000003')
            = '00000000-0000-0000-0000-0000000000d7', 'coordinator locks; locked_by stamped');
SELECT t_hint($$UPDATE registry.variable_values SET numeric_value = 3 WHERE assessment_id = '17000000-0000-0000-0000-000000000003'
  AND numeric_value IS NOT NULL$$, 'locked values cannot change', 'ASSESSMENT_LOCKED');
SELECT t_hint($$UPDATE registry.assessments SET locked_at = NULL WHERE assessment_id = '17000000-0000-0000-0000-000000000003'$$,
  'coordinator cannot unlock', 'LOCK_ROLE');
RESET ROLE; SET ROLE r_principal_investigator;
SELECT t_as('principal_investigator','00000000-0000-0000-0000-0000000000d4','00000000-0000-0000-0000-00000000c0a1');
SELECT t_hint($$UPDATE registry.assessments SET locked_at = NULL WHERE assessment_id = '17000000-0000-0000-0000-000000000003'$$,
  'PI unlock without a reason refused', 'CHANGE_REASON_REQUIRED');
SELECT set_config('app.change_reason', 'Stent count corrected from cath report', false);
UPDATE registry.assessments SET locked_at = NULL WHERE assessment_id = '17000000-0000-0000-0000-000000000003';
SELECT t_ok((SELECT locked_at IS NULL AND locked_by IS NULL FROM registry.assessments
             WHERE assessment_id = '17000000-0000-0000-0000-000000000003'), 'PI unlocks with a reason');
SELECT set_config('app.change_reason', '', false);
RESET ROLE; RESET SESSION AUTHORIZATION;
SELECT t_ok((SELECT reason FROM audit.audit_log WHERE table_name = 'assessments'
             AND row_pk::text LIKE '%17000000-0000-0000-0000-000000000003%'
             AND old_values->>'locked_at' IS NOT NULL AND new_values ? 'locked_at' AND new_values->>'locked_at' IS NULL)
          = 'Stent count corrected from cath report', 'unlock reason is in the audit log');
-- Test 0001 tampered with one centre A row on purpose; nothing written since breaks the chain.
SELECT t_ok((SELECT count(*) FILTER (WHERE NOT ok) = 1 AND bool_and(ok) FILTER (WHERE audit_id > (
               SELECT max(audit_id) FROM audit.verify_chain('00000000-0000-0000-0000-00000000c0a1') WHERE NOT ok))
             FROM audit.verify_chain('00000000-0000-0000-0000-00000000c0a1')),
  'centre A chain: only the row test 0001 tampered with fails; every later row verifies');
