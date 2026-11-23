-- CardioEMR migration 0006: acceptance tests.  Runs after test_0004 (same database).
-- Patient 1 at centre A is enrolled in CEMR-CAD (enrolment 16..03, index 5 days ago, test 0003).
\set ON_ERROR_STOP 1

\echo '--- 18. Migration 0006: unit conversion on entry'
SELECT protocol_id AS cad_protocol FROM registry.registry_protocols WHERE protocol_code = 'CEMR-CAD' \gset
CREATE OR REPLACE FUNCTION public.t_cad_value(p_code text, p_value numeric, p_unit text) RETURNS numeric
LANGUAGE sql AS $$
  INSERT INTO registry.variable_values (assessment_id, patient_id, centre_id, variable_id, entered_value, entered_unit)
  SELECT '17000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
         variable_id, p_value, p_unit FROM registry.variable_definitions
   WHERE variable_code = p_code AND registry_type_id = (SELECT registry_type_id FROM registry.registry_types WHERE registry_code = 'CAD')
  RETURNING numeric_value
$$;
GRANT EXECUTE ON FUNCTION public.t_cad_value(text, numeric, text) TO PUBLIC;
SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_research_coordinator;
SELECT t_as('research_coordinator','00000000-0000-0000-0000-0000000000d7','00000000-0000-0000-0000-00000000c0a1');
INSERT INTO registry.assessments (assessment_id, enrolment_id, patient_id, centre_id, visit_code, assessment_type,
  assessment_date)
VALUES ('17000000-0000-0000-0000-000000000006','16000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','UNSCHED','unscheduled', current_date);
SELECT t_ok(t_cad_value('ldl_c', 2.6, 'mmol/L') = 100.54, 'LDL-C 2.6 mmol/L stored as 100.54 mg/dL');
SELECT t_ok((SELECT entered_value = 2.6 AND entered_unit = 'mmol/L' FROM registry.variable_values v
             JOIN registry.variable_definitions d USING (variable_id)
             WHERE v.assessment_id = '17000000-0000-0000-0000-000000000006' AND d.variable_code = 'ldl_c'),
  'value and unit as typed are kept');
SELECT t_ok(t_cad_value('creatinine', 97, 'umol/L') = 1.10, 'creatinine 97 umol/L = 1.10 mg/dL');
SELECT t_ok(t_cad_value('haemoglobin', 128, 'g/L') = 12.80, 'haemoglobin 128 g/L = 12.8 g/dL');
SELECT t_ok(t_cad_value('weight_kg', 165, 'lb') = 74.84, 'weight 165 lb = 74.84 kg');
SELECT t_ok(t_cad_value('systolic_bp', 16, 'kPa') = 120, 'integer variable rounds: 16 kPa = 120 mmHg');
SELECT t_hint($$SELECT t_cad_value('hdl_c', 40, 'mg%')$$, 'unknown unit refused', 'UNIT_NOT_CONVERTIBLE');
SELECT t_hint($$SELECT t_cad_value('egfr', 60, 'mL/min')$$, 'eGFR does not accept a clearance in mL/min', 'UNIT_NOT_CONVERTIBLE');
SELECT t_hint($$SELECT t_cad_value('presentation', 1, 'mg/dL')$$, 'coded variable takes no unit', 'UNIT_NOT_CONVERTIBLE');
SELECT t_hint($$SELECT t_cad_value('hdl_c', 50, 'mmol/L')$$, 'converted value is range-checked (HDL-C 50 mmol/L)',
  'VALUE_OUT_OF_RANGE');
SELECT t_ok((SELECT accepted_units FROM (SELECT registry.accepted_units(variable_id) AS accepted_units
             FROM registry.variable_definitions WHERE variable_code = 'ldl_c' LIMIT 1) x) = ARRAY['mg/dL','mmol/L'],
  'accepted units for LDL-C: mg/dL, mmol/L');

\echo '--- 19. Migration 0006: clinical events and adjudication'
RESET ROLE; RESET SESSION AUTHORIZATION;
INSERT INTO iam.user_centre_roles (user_id, organisation_id, centre_id, role) VALUES
 ('00000000-0000-0000-0000-0000000000d7','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c0a1','nurse');
SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_nurse;
SELECT t_as('nurse','00000000-0000-0000-0000-0000000000d7','00000000-0000-0000-0000-00000000c0a1');
INSERT INTO clinical.clinical_events (event_id, patient_id, centre_id, event_type, event_date, stroke_type, source)
VALUES ('1d000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  'stroke', current_date - 1, 'ischaemic', 'follow_up_call');
SELECT t_ok(true, 'nurse reports a stroke');
SELECT t_fails($$SELECT count(*) FROM registry.event_adjudications$$, 'nurse cannot read adjudications', '42501');
SELECT t_hint($$INSERT INTO clinical.clinical_events (patient_id, centre_id, event_type, event_date, source, pci_procedure_id)
  VALUES ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1','stroke', current_date, 'site_clinician',
  gen_random_uuid())$$, 'PCI link on a stroke refused', 'EVENT_INVALID');
SELECT t_hint($$INSERT INTO clinical.clinical_events (patient_id, centre_id, event_type, event_date, source)
  VALUES ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1','mi', current_date + 3, 'site_clinician')$$,
  'future event date refused', 'EVENT_INVALID');

RESET ROLE; SET ROLE r_principal_investigator;
SELECT t_as('principal_investigator','00000000-0000-0000-0000-0000000000d4','00000000-0000-0000-0000-00000000c0a1');
SELECT t_ok((SELECT array_agg(ed.endpoint_code ORDER BY ed.endpoint_code) FROM registry.event_adjudications a
             JOIN registry.endpoint_definitions ed USING (endpoint_id)
             WHERE a.event_id = '1d000000-0000-0000-0000-000000000001') = ARRAY['ISCH_STROKE'],
  'stroke opened one pending CAD ischaemic-stroke adjudication (withdrawn HF enrolment opens none)');
SELECT t_hint($$INSERT INTO registry.event_adjudications (event_id, protocol_id, patient_id, centre_id)
  SELECT '1d000000-0000-0000-0000-000000000001', protocol_id, '10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1' FROM registry.registry_protocols WHERE protocol_code = 'CEMR-HF'$$,
  'users cannot open adjudications by hand', 'ADJUDICATION_ROLE');
SELECT t_hint($$UPDATE registry.event_adjudications SET adjudication_status = 'adjudicated', classification = 'lacunar'
  WHERE event_id = '1d000000-0000-0000-0000-000000000001'$$, 'classification outside the system refused', 'CLASSIFICATION_INVALID');
UPDATE registry.event_adjudications SET adjudication_status = 'adjudicated', classification = 'ischaemic'
 WHERE event_id = '1d000000-0000-0000-0000-000000000001';
SELECT t_ok((SELECT meets_endpoint AND adjudicated_by = '00000000-0000-0000-0000-0000000000d4' AND adjudicated_at IS NOT NULL
             FROM registry.event_adjudications WHERE event_id = '1d000000-0000-0000-0000-000000000001'),
  'PI adjudicates: meets_endpoint follows the classification; adjudicator stamped');
SELECT t_ok((SELECT array_agg(endpoint_code || ':' || endpoint_status ORDER BY endpoint_code) FROM registry.v_endpoint_events
             WHERE event_id = '1d000000-0000-0000-0000-000000000001') = ARRAY['ISCH_STROKE:confirmed','MACE3:confirmed'],
  'adjudicated ischaemic stroke counts for ISCH_STROKE and for the MACE3 composite');
SELECT t_hint($$UPDATE registry.event_adjudications SET classification = 'haemorrhagic'
  WHERE event_id = '1d000000-0000-0000-0000-000000000001'$$, 'changing a decision needs a reason', 'CHANGE_REASON_REQUIRED');
SELECT t_hint($$UPDATE registry.event_adjudications SET adjudication_status = 'pending'
  WHERE event_id = '1d000000-0000-0000-0000-000000000001'$$, 'pending is set by the system only', 'ADJUDICATION_ROLE');

RESET ROLE; SET ROLE r_research_coordinator;
SELECT t_as('research_coordinator','00000000-0000-0000-0000-0000000000d7','00000000-0000-0000-0000-00000000c0a1');
INSERT INTO clinical.clinical_events (event_id, patient_id, centre_id, event_type, event_date, mi_type, source)
VALUES ('1d000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  'mi', current_date - 2, '2', 'hospital_records');
SELECT t_hint($$UPDATE registry.event_adjudications SET adjudication_status = 'not_an_event'
  WHERE event_id = '1d000000-0000-0000-0000-000000000002'$$, 'coordinator cannot decide an adjudication', 'ADJUDICATION_ROLE');
SELECT t_hint($$UPDATE clinical.clinical_events SET event_type = 'stroke' WHERE event_id = '1d000000-0000-0000-0000-000000000002'$$,
  'event type is fixed', 'EVENT_TYPE_FIXED');
SELECT t_hint($$UPDATE clinical.clinical_events SET mi_type = '1' WHERE event_id = '1d000000-0000-0000-0000-000000000002'$$,
  'changing an event needs a reason', 'CHANGE_REASON_REQUIRED');
RESET ROLE; SET ROLE r_principal_investigator;
SELECT t_as('principal_investigator','00000000-0000-0000-0000-0000000000d4','00000000-0000-0000-0000-00000000c0a1');
UPDATE registry.event_adjudications SET adjudication_status = 'adjudicated', classification = '2'
 WHERE event_id = '1d000000-0000-0000-0000-000000000002';
RESET ROLE; SET ROLE r_research_coordinator;
SELECT t_as('research_coordinator','00000000-0000-0000-0000-0000000000d7','00000000-0000-0000-0000-00000000c0a1');
SELECT set_config('app.change_reason', 'Discharge summary: type 1 MI', false);
UPDATE clinical.clinical_events SET mi_type = '1' WHERE event_id = '1d000000-0000-0000-0000-000000000002';
SELECT t_ok((SELECT adjudication_status = 'pending' AND meets_endpoint IS NULL FROM registry.event_adjudications
             WHERE event_id = '1d000000-0000-0000-0000-000000000002'), 'changed MI details send the adjudication back to pending');
UPDATE clinical.clinical_events SET status = 'entered_in_error' WHERE event_id = '1d000000-0000-0000-0000-000000000002';
SELECT t_ok((SELECT adjudication_status = 'event_withdrawn' FROM registry.event_adjudications
             WHERE event_id = '1d000000-0000-0000-0000-000000000002'), 'event entered in error withdraws its adjudication');
SELECT t_hint($$UPDATE clinical.clinical_events SET description = 'x' WHERE event_id = '1d000000-0000-0000-0000-000000000002'$$,
  'an event entered in error is closed', 'EVENT_WITHDRAWN');
SELECT set_config('app.change_reason', '', false);

-- The reporter may not adjudicate their own report.
RESET ROLE; SET ROLE r_clinician;
SELECT t_as('clinician','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-00000000c0a1');
INSERT INTO clinical.clinical_events (event_id, patient_id, centre_id, event_type, event_date, bleeding_site, source)
VALUES ('1d000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  'bleeding', current_date, 'access site', 'site_clinician');
SELECT t_hint($$UPDATE registry.event_adjudications SET adjudication_status = 'adjudicated', classification = '3a'
  WHERE event_id = '1d000000-0000-0000-0000-000000000003'$$, 'reporter cannot adjudicate own event', 'ADJUDICATOR_CONFLICT');

\echo '--- 20. Migration 0006: reports and research exports'
SELECT t_ok((SELECT count(*) FROM registry.v_mandatory_values WHERE assessment_id = '17000000-0000-0000-0000-000000000003') > 0,
  'missing-data view lists the CAD baseline''s mandatory variables');
RESET ROLE; SET ROLE r_nurse;
SELECT t_as('nurse','00000000-0000-0000-0000-0000000000d7','00000000-0000-0000-0000-00000000c0a1');
SELECT t_ok(jsonb_array_length(registry.follow_up_facts(:'cad_protocol')->'enrolments') = 1, 'nurse gets follow-up facts for the CAD enrolment at her centre');
SELECT t_ok(registry.follow_up_facts(:'cad_protocol')->'enrolments'->0->>'mobile' = '9822000001', 'follow-up facts carry the mobile for the call list');
SELECT t_fails($$SELECT * FROM registry.v_mandatory_values$$, 'nurse cannot read registry values', '42501');

RESET ROLE; RESET SESSION AUTHORIZATION;
INSERT INTO registry.study_memberships (user_id, protocol_id, study_role, approved_by, can_export)
SELECT '00000000-0000-0000-0000-0000000000d7', protocol_id, 'data_manager', '00000000-0000-0000-0000-0000000000d5', true
  FROM registry.registry_protocols WHERE protocol_code = 'CEMR-CAD';
SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_research_coordinator;
SELECT t_as('research_coordinator','00000000-0000-0000-0000-0000000000d7','00000000-0000-0000-0000-00000000c0a1');
INSERT INTO research.export_jobs (export_id, protocol_id, purpose, variable_codes, deidentification, file_format)
SELECT '1e000000-0000-0000-0000-000000000001', protocol_id, 'CAD interim analysis', ARRAY['ldl_c'],
  'pseudonymised_relative_days', 'csv' FROM registry.registry_protocols WHERE protocol_code = 'CEMR-CAD';
SELECT t_ok((SELECT requested_role = 'research_coordinator' AND status = 'requested' FROM research.export_jobs
             WHERE export_id = '1e000000-0000-0000-0000-000000000001'), 'export requested; role recorded');
SELECT t_ok((SELECT count(*) FROM research.v_variable_values WHERE variable_code = 'ldl_c') = 1
        AND (SELECT numeric_value FROM research.v_variable_values WHERE variable_code = 'ldl_c') = 100.54,
  'pseudonymised value view shows the converted LDL-C');
SELECT t_ok((SELECT had_event AND time_days = 4 FROM research.v_time_to_first_event WHERE endpoint_code = 'MACE3'),
  'time to first MACE: the ischaemic stroke on day 4');
SELECT t_ok(NOT EXISTS (SELECT 1 FROM information_schema.columns c JOIN information_schema.views v
  ON v.table_schema = c.table_schema AND v.table_name = c.table_name WHERE c.table_schema = 'research'
  AND c.column_name IN ('first_name','last_name','mobile','date_of_birth','local_patient_code','patient_id','index_date',
                      'enrolment_id','assessment_id','date_value','event_date')),
  'no identifiers or exact dates in any research view');
SELECT t_hint($$UPDATE research.export_jobs SET variable_codes = ARRAY['ldl_c','sex']
  WHERE export_id = '1e000000-0000-0000-0000-000000000001'$$, 'request cannot be edited', 'EXPORT_STATE');
SELECT t_hint($$UPDATE research.export_jobs SET status = 'approved' WHERE export_id = '1e000000-0000-0000-0000-000000000001'$$,
  'coordinator cannot approve', 'EXPORT_ROLE');
SELECT t_hint($$UPDATE research.export_jobs SET status = 'running' WHERE export_id = '1e000000-0000-0000-0000-000000000001'$$,
  'cannot run before approval', 'EXPORT_STATE');
RESET ROLE; SET ROLE r_principal_investigator;
SELECT t_as('principal_investigator','00000000-0000-0000-0000-0000000000d4','00000000-0000-0000-0000-00000000c0a1');
RESET ROLE; RESET SESSION AUTHORIZATION;
INSERT INTO registry.study_memberships (user_id, protocol_id, study_role, approved_by, can_export)
SELECT '00000000-0000-0000-0000-0000000000d4', protocol_id, 'chief_investigator', '00000000-0000-0000-0000-0000000000d5', true
  FROM registry.registry_protocols WHERE protocol_code = 'CEMR-CAD';
SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_principal_investigator;
SELECT t_as('principal_investigator','00000000-0000-0000-0000-0000000000d4','00000000-0000-0000-0000-00000000c0a1');
UPDATE research.export_jobs SET status = 'approved' WHERE export_id = '1e000000-0000-0000-0000-000000000001';
SELECT t_ok((SELECT approved_by = '00000000-0000-0000-0000-0000000000d4' FROM research.export_jobs
             WHERE export_id = '1e000000-0000-0000-0000-000000000001'), 'PI approves; approver stamped by the database');
SELECT t_hint($$UPDATE research.export_jobs SET status = 'running' WHERE export_id = '1e000000-0000-0000-0000-000000000001'$$,
  'only the requester''s own access runs an export', 'EXPORT_ROLE');
RESET ROLE; SET ROLE r_research_coordinator;
SELECT t_as('research_coordinator','00000000-0000-0000-0000-0000000000d7','00000000-0000-0000-0000-00000000c0a1');
UPDATE research.export_jobs SET status = 'running' WHERE export_id = '1e000000-0000-0000-0000-000000000001';
SELECT t_hint($$UPDATE research.export_jobs SET status = 'completed' WHERE export_id = '1e000000-0000-0000-0000-000000000001'$$,
  'completed export needs file, hash, row count and expiry', 'EXPORT_STATE');
RESET ROLE; RESET SESSION AUTHORIZATION;

SELECT t_ok(NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace,
       regexp_matches(p.prosrc, 'cemr:([A-Z_]+)', 'g') m
  WHERE n.nspname IN ('registry','clinical','app','ref','research')
    AND NOT EXISTS (SELECT 1 FROM ref.api_error_map e WHERE e.source_kind = 'hint' AND e.source_name = 'cemr:' || m[1])),
  'every HINT tag raised by a function (0006 included) is in ref.api_error_map');
SELECT t_ok(NOT EXISTS (
  SELECT 1 FROM ref.api_error_map e WHERE e.source_kind = 'constraint'
    AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conname = e.source_name)
    AND NOT EXISTS (SELECT 1 FROM pg_class i WHERE i.relkind = 'i' AND i.relname = e.source_name)),
  'every mapped constraint or index still exists');
SELECT t_ok((SELECT bool_and(status = 'draft') FROM registry.endpoint_definitions),
  'every endpoint definition is still draft, waiting for clinical sign-off');
