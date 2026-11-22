-- CardioEMR migration 0001: acceptance tests (PRD section 18).
-- Run as a superuser on a fresh database after the migration.
-- Every check prints PASS or FAIL; the runner fails on any FAIL.
\set ON_ERROR_STOP 1
SET client_min_messages = notice;

CREATE OR REPLACE FUNCTION public.t_ok(p boolean, p_name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p IS TRUE THEN RAISE NOTICE 'PASS  %', p_name; ELSE RAISE NOTICE 'FAIL  %', p_name; END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.t_ok(boolean, text) TO PUBLIC;

-- Runs a statement that must fail with the given SQLSTATE class prefix.
CREATE OR REPLACE FUNCTION public.t_fails(p_sql text, p_name text, p_state text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RAISE NOTICE 'FAIL  % (statement succeeded)', p_name;
EXCEPTION WHEN OTHERS THEN
  IF p_state IS NULL OR SQLSTATE LIKE p_state || '%' THEN RAISE NOTICE 'PASS  % [%: %]', p_name, SQLSTATE, SQLERRM;
  ELSE RAISE NOTICE 'FAIL  % (wrong error %: %)', p_name, SQLSTATE, SQLERRM; END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.t_fails(text, text, text) TO PUBLIC;

-- Fixture: two organisations, three centres, seven users ----------------
INSERT INTO iam.organisations (organisation_id, organisation_name, organisation_type) VALUES
 ('00000000-0000-0000-0000-0000000000a1','Heart Clinic Pune','clinic'),
 ('00000000-0000-0000-0000-0000000000b1','City Hospital Mumbai','hospital');
INSERT INTO iam.centres (centre_id, organisation_id, centre_name, centre_code) VALUES
 ('00000000-0000-0000-0000-00000000c0a1','00000000-0000-0000-0000-0000000000a1','Pune Main','PUN1'),
 ('00000000-0000-0000-0000-00000000c0b1','00000000-0000-0000-0000-0000000000b1','Mumbai Cardiology','MUM1'),
 ('00000000-0000-0000-0000-00000000c0b2','00000000-0000-0000-0000-0000000000b1','Mumbai Annexe','MUM2');
INSERT INTO iam.users (user_id, full_name, email, auth_subject, platform_role) VALUES
 ('00000000-0000-0000-0000-0000000000d1','Dr A','dra@example.org','sub-dra',NULL),
 ('00000000-0000-0000-0000-0000000000d2','Assistant A','asa@example.org','sub-asa',NULL),
 ('00000000-0000-0000-0000-0000000000d3','Dr B','drb@example.org','sub-drb',NULL),
 ('00000000-0000-0000-0000-0000000000d4','PI Network','pi@example.org','sub-pi',NULL),
 ('00000000-0000-0000-0000-0000000000d5','Platform Admin','pa@example.org','sub-pa','platform_admin'),
 ('00000000-0000-0000-0000-0000000000d6','Admin B','adb@example.org','sub-adb',NULL),
 ('00000000-0000-0000-0000-0000000000d7','Coordinator A','rca@example.org','sub-rca',NULL);
INSERT INTO iam.user_centre_roles (user_id, organisation_id, centre_id, role) VALUES
 ('00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c0a1','clinician'),
 ('00000000-0000-0000-0000-0000000000d2','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c0a1','assistant'),
 ('00000000-0000-0000-0000-0000000000d3','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-00000000c0b1','clinician'),
 ('00000000-0000-0000-0000-0000000000d6','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-00000000c0b1','centre_admin'),
 ('00000000-0000-0000-0000-0000000000d7','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c0a1','research_coordinator');

UPDATE registry.registry_protocols SET status = 'active', approved_at = now(),
  approved_by = '00000000-0000-0000-0000-0000000000d5' WHERE protocol_code = 'CEMR-HF';
INSERT INTO registry.protocol_sites (protocol_id, centre_id, ethics_approval_ref, site_status)
SELECT protocol_id, c, 'EC/2027/001', 'active' FROM registry.registry_protocols,
  unnest(ARRAY['00000000-0000-0000-0000-00000000c0a1','00000000-0000-0000-0000-00000000c0b1']::uuid[]) c
WHERE protocol_code = 'CEMR-HF';
INSERT INTO registry.study_memberships (user_id, protocol_id, study_role, approved_by, can_export)
SELECT '00000000-0000-0000-0000-0000000000d4', protocol_id, 'chief_investigator', '00000000-0000-0000-0000-0000000000d5', true
FROM registry.registry_protocols WHERE protocol_code = 'CEMR-HF';

-- Session switcher: same as the API would do per request.
CREATE OR REPLACE FUNCTION public.t_as(p_role text, p_user text, p_centre text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('app.user_id', p_user, false);
  PERFORM set_config('app.centre_id', coalesce(p_centre, ''), false);
END $$;
GRANT EXECUTE ON FUNCTION public.t_as(text, text, text) TO PUBLIC;

\echo '--- 1. Clinician at centre A documents a heart failure consultation'
SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_clinician;
SELECT t_as('clinician','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-00000000c0a1');
INSERT INTO clinical.patients (patient_id) VALUES ('10000000-0000-0000-0000-000000000001');
INSERT INTO clinical.patient_registrations (registration_id, patient_id, centre_id, local_patient_code, first_name,
  last_name, date_of_birth, sex, mobile)
VALUES ('11000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1', clinical.next_local_patient_code(), 'Ramesh', 'Kulkarni', '1968-03-14',
  'male', '9822000001');
SELECT t_ok((SELECT local_patient_code FROM clinical.patient_registrations) = 'PUN1-000001', 'local patient code generated per centre');
SELECT t_ok((SELECT organisation_id FROM clinical.patient_registrations) = '00000000-0000-0000-0000-0000000000a1',
  'organisation_id filled from centre by trigger');
INSERT INTO clinical.encounters (encounter_id, patient_id, centre_id, clinician_id, encounter_type, assessment)
VALUES ('12000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','00000000-0000-0000-0000-0000000000d1','new_consultation','HFrEF, NYHA II');
INSERT INTO clinical.vital_signs (patient_id, centre_id, encounter_id, height_cm, weight_kg, systolic_bp, diastolic_bp, heart_rate)
VALUES ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  '12000000-0000-0000-0000-000000000001',170,72,110,70,76);
SELECT t_ok((SELECT bmi FROM clinical.vital_signs) = 24.9, 'BMI generated (72 kg, 170 cm = 24.9)');
SELECT t_fails($$INSERT INTO clinical.vital_signs (patient_id, centre_id, systolic_bp, diastolic_bp)
  VALUES ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',80,95)$$,
  'diastolic above systolic rejected', '23');
INSERT INTO clinical.diagnoses (patient_id, centre_id, encounter_id, concept_id, diagnosis_text, diagnosis_role)
SELECT '10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  '12000000-0000-0000-0000-000000000001', concept_id, 'Ischaemic cardiomyopathy', 'final'
FROM ref.concepts WHERE concept_code = 'DX_ICM';
SELECT t_ok((SELECT array_agg(registry_code ORDER BY registry_code) FROM registry.registry_suggestions)
  = ARRAY['CAD','HF','LIPID'], 'ischaemic cardiomyopathy suggests HF, lipid and CAD registries (PRD 5)');
SELECT t_ok((SELECT count(*) FROM registry.enrolments) = 0, 'no silent enrolment: suggestion only');

INSERT INTO clinical.investigations (investigation_id, patient_id, centre_id, encounter_id, investigation_type, performed_on)
VALUES ('13000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','12000000-0000-0000-0000-000000000001','lab', current_date),
       ('13000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','12000000-0000-0000-0000-000000000001','echo', current_date);
INSERT INTO clinical.lab_results (investigation_id, patient_id, centre_id, analyte_code, collected_at, value_reported, unit_reported)
VALUES ('13000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','NT_PROBNP', now(), 200, 'pmol/L'),
       ('13000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','LDL_C', now(), 3.0, 'mmol/L');
SELECT t_ok((SELECT value_canonical FROM clinical.lab_results WHERE analyte_code = 'NT_PROBNP') = 1691.4,
  'NT-proBNP 200 pmol/L stored as 1691.4 pg/mL with original value kept');
SELECT t_ok((SELECT value_canonical FROM clinical.lab_results WHERE analyte_code = 'LDL_C') = 116.01,
  'LDL-C 3.0 mmol/L stored as 116.01 mg/dL');
SELECT t_fails($$INSERT INTO clinical.lab_results (investigation_id, patient_id, centre_id, analyte_code, collected_at,
  value_reported, unit_reported) VALUES ('13000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','LDL_C', now(), 120, 'mg%')$$, 'unknown unit rejected', '23');
SELECT t_fails($$INSERT INTO clinical.lab_results (investigation_id, patient_id, centre_id, analyte_code, collected_at,
  value_reported, unit_reported) VALUES ('13000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','K', now(), 45, 'mmol/L')$$, 'implausible potassium 45 mmol/L rejected', '23');
INSERT INTO clinical.echo_reports (investigation_id, patient_id, centre_id, lvef, lvef_method, lvedd_mm)
VALUES ('13000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1', 30, 'biplane_simpson', 62);

\echo '--- 2. Medication history and GDMT engine'
INSERT INTO clinical.medication_courses (course_id, patient_id, centre_id, drug_id, started_on)
SELECT ('14000000-0000-0000-0000-00000000000' || n)::uuid, '10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1', drug_id, current_date - 60
FROM ref.drugs JOIN (VALUES (1,'SACUBITRIL_VALSARTAN'),(2,'CARVEDILOL'),(3,'DAPAGLIFLOZIN'),(4,'METOPROLOL_TARTRATE'))
  v(n, dc) ON v.dc = drug_code;
INSERT INTO clinical.medication_events (course_id, patient_id, centre_id, event_type, effective_date, drug_id,
  strength_label, dose_quantity, dose_unit, frequency_code, doses_per_day, daily_dose, prescribed_by)
SELECT c.course_id, c.patient_id, c.centre_id, e.et, current_date - e.ago, c.drug_id, e.lbl, 1, 'tablet', e.freq, e.n,
  e.dd, '00000000-0000-0000-0000-0000000000d1'
FROM clinical.medication_courses c JOIN (VALUES
  ('14000000-0000-0000-0000-000000000001'::uuid,'initiate',60,'49/51 mg','BD',2,200),
  ('14000000-0000-0000-0000-000000000002'::uuid,'initiate',60,'3.125 mg','BD',2,6.25),
  ('14000000-0000-0000-0000-000000000002'::uuid,'increase',30,'12.5 mg','BD',2,25),
  ('14000000-0000-0000-0000-000000000002'::uuid,'increase',5,'25 mg','BD',2,50),
  ('14000000-0000-0000-0000-000000000003'::uuid,'initiate',60,'10 mg','OD',1,10),
  ('14000000-0000-0000-0000-000000000004'::uuid,'initiate',60,'25 mg','BD',2,50)) e(cid, et, ago, lbl, freq, n, dd)
  ON e.cid = c.course_id;
INSERT INTO clinical.medication_events (course_id, patient_id, centre_id, event_type, effective_date, drug_id, reason_text)
SELECT course_id, patient_id, centre_id, 'discontinue', current_date - 40, drug_id, 'switched to carvedilol'
FROM clinical.medication_courses WHERE course_id = '14000000-0000-0000-0000-000000000004';
SELECT t_ok((SELECT status FROM clinical.medication_courses WHERE course_id = '14000000-0000-0000-0000-000000000004') = 'stopped',
  'discontinue event closes the course');
SELECT t_ok((SELECT count(*) FROM clinical.medication_events WHERE course_id = '14000000-0000-0000-0000-000000000002') = 3,
  'every carvedilol titration kept as its own event');
SELECT t_fails($$UPDATE clinical.medication_events SET daily_dose = 100$$, 'medication events cannot be edited', '42');

CREATE TEMP TABLE g AS SELECT * FROM registry.compute_gdmt('10000000-0000-0000-0000-000000000001', current_date,
  (SELECT rule_set_id FROM ref.rule_sets WHERE rule_set_code = 'ESC_HF_2021_2023'), 'HFrEF');
SELECT t_ok((SELECT pct_target_dose FROM g WHERE pillar_code = 'RASI') = 50.0, 'ARNI 49/51 mg BD = 50% of target');
SELECT t_ok((SELECT pct_target_dose FROM g WHERE pillar_code = 'BB') = 100.0, 'carvedilol 25 mg BD = 100% of target');
SELECT t_ok((SELECT last_titration_date FROM g WHERE pillar_code = 'BB') = current_date - 5, 'date of last titration');
SELECT t_ok((SELECT NOT prescribed AND eligible FROM g WHERE pillar_code = 'MRA'), 'MRA eligible but not prescribed');
SELECT t_ok((SELECT pct_target_dose FROM g WHERE pillar_code = 'SGLT2I') = 100.0, 'dapagliflozin 10 mg = at target');
SELECT t_ok((SELECT count(*) FILTER (WHERE prescribed) FROM g) = 3, '3 of 4 eligible pillars prescribed');
CREATE TEMP TABLE g2 AS SELECT * FROM registry.compute_gdmt('10000000-0000-0000-0000-000000000001', current_date - 50,
  (SELECT rule_set_id FROM ref.rule_sets WHERE rule_set_code = 'ESC_HF_2021_2023'), 'HFrEF');
SELECT t_ok((SELECT pct_target_dose FROM g2 WHERE pillar_code = 'BB') = 12.5
  AND (SELECT d.drug_code FROM g2 JOIN ref.drugs d USING (drug_id) WHERE pillar_code = 'BB') = 'CARVEDILOL',
  'as of 50 days ago: evidence-based carvedilol 6.25 mg/day (12.5%) preferred over metoprolol tartrate');
CREATE TEMP TABLE g3 AS SELECT * FROM registry.compute_gdmt('10000000-0000-0000-0000-000000000001', current_date,
  (SELECT rule_set_id FROM ref.rule_sets WHERE rule_set_code = 'ESC_HF_2021_2023'), 'HFpEF');
SELECT t_ok((SELECT count(*) FILTER (WHERE eligible) FROM g3) = 1, 'HFpEF: only SGLT2i counted as an eligible pillar');

\echo '--- 3. Signed records cannot be silently altered'
UPDATE clinical.encounters SET status = 'signed', signed_at = now(), signed_by = '00000000-0000-0000-0000-0000000000d1'
 WHERE encounter_id = '12000000-0000-0000-0000-000000000001';
SELECT t_fails($$UPDATE clinical.encounters SET assessment = 'HFpEF' WHERE encounter_id = '12000000-0000-0000-0000-000000000001'$$,
  'signed encounter text cannot be edited', '42');
SELECT t_fails($$INSERT INTO clinical.vital_signs (patient_id, centre_id, encounter_id, heart_rate) VALUES
  ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1','12000000-0000-0000-0000-000000000001',80)$$,
  'vitals cannot be added to a signed encounter', '42');
INSERT INTO clinical.encounter_amendments (encounter_id, patient_id, centre_id, field_name, previous_value, amended_value, reason)
VALUES ('12000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','assessment','HFrEF, NYHA II','HFrEF, NYHA III','Dictation error corrected');
SELECT t_ok((SELECT status FROM clinical.encounters) = 'amended' AND (SELECT assessment FROM clinical.encounters) = 'HFrEF, NYHA II',
  'amendment recorded beside the untouched original');

\echo '--- 4. Registry enrolment needs eligibility and research consent'
SELECT t_fails($$INSERT INTO registry.enrolments (patient_id, centre_id, registry_type_id, protocol_id, enrolment_date,
  index_date, eligibility_status, eligibility_confirmed_by, enrolled_by, enrolment_status)
  SELECT '10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1', registry_type_id, protocol_id,
  current_date, current_date, 'eligible', '00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000d1','enrolled'
  FROM registry.registry_protocols WHERE protocol_code = 'CEMR-HF'$$, 'enrolment without research consent rejected', '23');
INSERT INTO clinical.patient_consents (consent_id, patient_id, centre_id, consent_type, consent_form_version, consent_date, consent_method)
VALUES ('15000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','clinical_care','v1', current_date,'written');
SELECT t_fails($$INSERT INTO registry.enrolments (patient_id, centre_id, registry_type_id, protocol_id, enrolment_date,
  index_date, eligibility_status, eligibility_confirmed_by, enrolled_by, enrolment_status, consent_id)
  SELECT '10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1', registry_type_id, protocol_id,
  current_date, current_date, 'eligible', '00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000d1','enrolled',
  '15000000-0000-0000-0000-000000000001' FROM registry.registry_protocols WHERE protocol_code = 'CEMR-HF'$$,
  'clinical-care consent does not authorise research enrolment', '23');
INSERT INTO clinical.patient_consents (consent_id, patient_id, centre_id, consent_type, protocol_id, consent_form_version, consent_date, consent_method)
SELECT '15000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','research_registry', protocol_id, 'HF-ICF v1.0 (Marathi)', current_date, 'written'
FROM registry.registry_protocols WHERE protocol_code = 'CEMR-HF';
INSERT INTO registry.enrolments (enrolment_id, patient_id, centre_id, registry_type_id, protocol_id, enrolment_date,
  index_date, eligibility_status, eligibility_confirmed_by, enrolled_by, enrolment_status, consent_id)
SELECT '16000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  registry_type_id, protocol_id, current_date, current_date - 10, 'eligible', '00000000-0000-0000-0000-0000000000d1',
  '00000000-0000-0000-0000-0000000000d1','enrolled','15000000-0000-0000-0000-000000000002'
FROM registry.registry_protocols WHERE protocol_code = 'CEMR-HF';
SELECT t_ok((SELECT count(*) FROM registry.enrolments WHERE enrolment_status = 'enrolled') = 1, 'enrolment with research consent accepted');
INSERT INTO registry.assessments (assessment_id, enrolment_id, patient_id, centre_id, encounter_id, visit_code,
  assessment_type, assessment_date)
VALUES ('17000000-0000-0000-0000-000000000001','16000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','12000000-0000-0000-0000-000000000001','BL','baseline', current_date);
SELECT t_ok((SELECT days_from_index = 10 AND within_window FROM registry.assessments), 'baseline day 10 is inside the 0 to +14 window');
INSERT INTO registry.hf_assessment_data (assessment_id, patient_id, centre_id, nyha_class, systolic_bp, lvef, hf_phenotype,
  nt_probnp_pg_ml, pillars_eligible, pillars_prescribed, pillars_at_target)
VALUES ('17000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  'II',110,30,'HFrEF',1691.4,4,3,2);
INSERT INTO registry.variable_values (assessment_id, patient_id, centre_id, variable_id, coded_value)
SELECT '17000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  variable_id, 'ischaemic' FROM registry.variable_definitions WHERE variable_code = 'primary_aetiology'
  AND registry_type_id = (SELECT registry_type_id FROM registry.registry_types WHERE registry_code = 'HF');
SELECT t_fails($$INSERT INTO registry.variable_values (assessment_id, patient_id, centre_id, variable_id, numeric_value)
  SELECT '17000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  variable_id, 140 FROM registry.variable_definitions WHERE variable_code = 'lvef'
  AND registry_type_id = (SELECT registry_type_id FROM registry.registry_types WHERE registry_code = 'HF')$$,
  'registry value outside its defined range (LVEF 140%) rejected', '23');
SELECT t_fails($$INSERT INTO registry.variable_values (assessment_id, patient_id, centre_id, variable_id, coded_value)
  SELECT '17000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  variable_id, 'V' FROM registry.variable_definitions WHERE variable_code = 'nyha_class'
  AND registry_type_id = (SELECT registry_type_id FROM registry.registry_types WHERE registry_code = 'HF')$$,
  'registry code outside allowed values (NYHA V) rejected', '23');
INSERT INTO clinical.clinical_events (patient_id, centre_id, event_type, event_date, hospitalised, admission_date,
  discharge_date, source) VALUES ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  'hf_hospitalisation', current_date - 3, true, current_date - 6, current_date - 3, 'hospital_records');

\echo '--- 5. Centre isolation'
SELECT t_as('clinician','00000000-0000-0000-0000-0000000000d3','00000000-0000-0000-0000-00000000c0b1');
SELECT t_ok((SELECT count(*) FROM clinical.patient_registrations) = 0
        AND (SELECT count(*) FROM clinical.patients) = 0
        AND (SELECT count(*) FROM clinical.encounters) = 0
        AND (SELECT count(*) FROM clinical.lab_results) = 0
        AND (SELECT count(*) FROM clinical.medication_events) = 0
        AND (SELECT count(*) FROM registry.enrolments) = 0, 'centre B clinician sees none of centre A''s rows');
SELECT t_fails($$INSERT INTO clinical.encounters (patient_id, centre_id, clinician_id, encounter_type)
  VALUES ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1','00000000-0000-0000-0000-0000000000d3','follow_up')$$,
  'centre B cannot write into centre A', '42');
SELECT t_as('clinician','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-00000000c0b1');
SELECT t_ok((SELECT count(*) FROM clinical.patient_registrations) = 0, 'switching active centre to one without a role shows nothing');
RESET ROLE; SET ROLE r_assistant;
SELECT t_as('clinician','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-00000000c0a1');
SELECT t_ok((SELECT count(*) FROM clinical.patient_registrations) = 0,
  'API switching to a role the user does not hold at the centre (assistant) shows nothing');

\echo '--- 6. Role permissions'
SELECT t_as('assistant','00000000-0000-0000-0000-0000000000d2','00000000-0000-0000-0000-00000000c0a1');
SELECT t_ok((SELECT count(*) FROM clinical.patient_registrations) = 1, 'assistant sees centre A registrations');
SELECT t_fails($$INSERT INTO clinical.medication_events (course_id, patient_id, centre_id, event_type, effective_date,
  drug_id, reason_text) SELECT course_id, patient_id, centre_id, 'discontinue', current_date, drug_id, 'x'
  FROM clinical.medication_courses LIMIT 1$$, 'assistant cannot prescribe or change medication', '42501');
SELECT t_fails($$SELECT count(*) FROM registry.enrolments$$, 'assistant cannot read registry data', '42501');
SELECT t_fails($$SELECT count(*) FROM research.v_enrolments$$, 'assistant cannot read research datasets', '42501');
RESET ROLE; SET ROLE r_platform_admin;
SELECT t_as('platform_admin','00000000-0000-0000-0000-0000000000d5', NULL);
SELECT t_fails($$SELECT count(*) FROM clinical.patient_registrations$$, 'platform admin has no access to identifiable patient data', '42501');
SELECT t_ok((SELECT count(*) FROM registry.enrolments) = 0, 'platform admin sees no registry patient rows');
SELECT t_ok((SELECT count(*) FROM iam.centres) = 3, 'platform admin manages all centres');
RESET ROLE; SET ROLE r_centre_admin;
SELECT t_as('centre_admin','00000000-0000-0000-0000-0000000000d6','00000000-0000-0000-0000-00000000c0b1');
SELECT t_fails($$INSERT INTO iam.user_centre_roles (user_id, organisation_id, centre_id, role) VALUES
  ('00000000-0000-0000-0000-0000000000d6','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-00000000c0b1','clinician')$$,
  'centre admin cannot grant roles to themselves', '42501');
SELECT t_fails($$INSERT INTO iam.user_centre_roles (user_id, organisation_id, centre_id, role) VALUES
  ('00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c0a1','clinician')$$,
  'centre admin cannot grant roles in another organisation', '42501');
INSERT INTO iam.user_centre_roles (user_id, organisation_id, centre_id, role) VALUES
  ('00000000-0000-0000-0000-0000000000d3','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-00000000c0b2','clinician');
SELECT t_ok(true, 'centre admin can grant a role at another centre of the same organisation');
SELECT t_fails($$UPDATE iam.users SET platform_role = 'platform_admin' WHERE user_id = '00000000-0000-0000-0000-0000000000d3'$$,
  'centre admin cannot create a platform admin', '42501');

\echo '--- 7. Study access is pseudonymised'
RESET ROLE; SET ROLE r_principal_investigator;
SELECT t_as('principal_investigator','00000000-0000-0000-0000-0000000000d4', NULL);
SELECT t_ok((SELECT count(*) FROM research.v_enrolments) = 1, 'network PI sees the enrolment in the pooled view');
SELECT t_ok((SELECT study_subject_code ~ '^HF-[A-Za-z2-9]{6}$' FROM research.v_enrolments), 'pseudonymous study code assigned');
SELECT t_ok((SELECT age_at_index FROM research.v_enrolments) = extract(year FROM age(current_date - 10, date '1968-03-14'))::int,
  'age at index instead of date of birth');
SELECT t_ok(NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'research'
  AND column_name IN ('first_name','last_name','mobile','date_of_birth','local_patient_code','address_line','patient_id')),
  'no identifier columns in any research view');
SELECT t_ok((SELECT count(*) FROM research.v_hf_assessments) = 1 AND (SELECT count(*) FROM research.v_events) = 1,
  'PI sees HF assessment and event, with days from index');
SELECT t_ok((SELECT event_day FROM research.v_events) = 7, 'event placed at day 7 after index');
SELECT t_ok((SELECT count(*) FROM clinical.patient_registrations) = 0, 'PI cannot reach identifiable centre records');
INSERT INTO research.export_jobs (protocol_id, purpose, variable_codes, deidentification, file_format)
SELECT protocol_id, 'Baseline table for interim report', ARRAY['age_at_index','sex','lvef'], 'pseudonymised_relative_days', 'csv'
FROM registry.registry_protocols WHERE protocol_code = 'CEMR-HF';
SELECT t_fails($$UPDATE research.export_jobs SET status = 'approved', approved_by = '00000000-0000-0000-0000-0000000000d4',
  approved_at = now()$$, 'requester cannot approve their own export (four-eyes)', '23');

\echo '--- 8. Cross-centre identity linkage without exposing identifiers'
RESET ROLE; SET ROLE r_clinician;
SELECT t_as('clinician','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-00000000c0a1');
SELECT clinical.set_match_keys('11000000-0000-0000-0000-000000000001',
  jsonb_build_object('mobile', encode(public.hmac('9822000001','pepper-from-kms','sha256'),'hex'),
                     'name_dob', encode(public.hmac('ramesh kulkarni|1968-03-14','pepper-from-kms','sha256'),'hex')));
SELECT t_as('clinician','00000000-0000-0000-0000-0000000000d3','00000000-0000-0000-0000-00000000c0b1');
INSERT INTO clinical.patients (patient_id) VALUES ('10000000-0000-0000-0000-000000000002');
INSERT INTO clinical.patient_registrations (registration_id, patient_id, centre_id, local_patient_code, first_name,
  last_name, date_of_birth, sex, mobile)
VALUES ('11000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0b1',
  clinical.next_local_patient_code(), 'Ramesh', 'Kulkarni', '1968-03-14', 'male', '9822000001');
SELECT t_ok((SELECT local_patient_code FROM clinical.patient_registrations) = 'MUM1-000001', 'centre B numbers its own patients');
SELECT clinical.set_match_keys('11000000-0000-0000-0000-000000000002',
  jsonb_build_object('mobile', encode(public.hmac('9822000001','pepper-from-kms','sha256'),'hex'),
                     'name_dob', encode(public.hmac('ramesh kulkarni|1968-03-14','pepper-from-kms','sha256'),'hex')));
SELECT t_fails($$SELECT * FROM clinical.patient_match_keys$$, 'match keys are not readable by any app role', '42501');
CREATE TEMP TABLE m AS SELECT * FROM clinical.find_match_candidates('11000000-0000-0000-0000-000000000002');
SELECT t_ok((SELECT candidate_patient_id FROM m) = '10000000-0000-0000-0000-000000000001'
  AND (SELECT strength FROM m) = 'strong', 'match found by keyed hashes only: master id + matched key types');
INSERT INTO clinical.patient_consents (consent_id, patient_id, centre_id, consent_type, consent_form_version, consent_date, consent_method)
VALUES ('15000000-0000-0000-0000-000000000009','10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0b1',
  'cross_centre_linkage','LINK v1', current_date,'written');
INSERT INTO clinical.encounters (encounter_id, patient_id, centre_id, clinician_id, encounter_type)
VALUES ('12000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0b1',
  '00000000-0000-0000-0000-0000000000d3','new_consultation');
INSERT INTO clinical.patient_link_requests (link_request_id, registration_id, centre_id, candidate_patient_id,
  matched_key_types, linkage_consent_id)
VALUES ('18000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0b1',
  '10000000-0000-0000-0000-000000000001', ARRAY['mobile','name_dob'], '15000000-0000-0000-0000-000000000009');
SELECT clinical.confirm_patient_link('18000000-0000-0000-0000-000000000001');
SELECT t_ok((SELECT patient_id FROM clinical.patient_registrations) = '10000000-0000-0000-0000-000000000001'
  AND (SELECT patient_id FROM clinical.encounters) = '10000000-0000-0000-0000-000000000001'
  AND (SELECT patient_id FROM clinical.patient_consents WHERE consent_id = '15000000-0000-0000-0000-000000000009')
      = '10000000-0000-0000-0000-000000000001',
  'confirmed link re-points centre B registration and its clinical rows to the shared master patient');
SELECT t_ok((SELECT count(*) FROM clinical.encounters) = 1,
  'after linking, centre B still sees only its own encounter, not centre A''s');
RESET ROLE; RESET SESSION AUTHORIZATION;
SELECT t_ok((SELECT status FROM clinical.patients WHERE patient_id = '10000000-0000-0000-0000-000000000002') = 'merged',
  'orphaned master record marked merged, not deleted');
SET SESSION AUTHORIZATION cardioemr_api;

\echo '--- 9. Consent withdrawal'
SET ROLE r_clinician;
SELECT t_as('clinician','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-00000000c0a1');
UPDATE clinical.patient_consents SET consent_status = 'withdrawn', withdrawal_date = current_date,
  withdrawal_scope = 'exclude_collected_data', withdrawal_reason = 'patient request'
 WHERE consent_id = '15000000-0000-0000-0000-000000000002';
SELECT t_ok((SELECT enrolment_status FROM registry.enrolments) = 'withdrawn', 'withdrawal closes the enrolment');
SELECT t_ok((SELECT count(*) FROM clinical.encounters) = 1, 'clinical record unaffected by research withdrawal');
RESET ROLE; SET ROLE r_principal_investigator;
SELECT t_as('principal_investigator','00000000-0000-0000-0000-0000000000d4', NULL);
SELECT t_ok((SELECT count(*) FROM research.v_enrolments) = 0 AND (SELECT count(*) FROM research.v_hf_assessments) = 0,
  'withdrawn-with-exclusion patient disappears from research views');

\echo '--- 10. Audit trail'
RESET ROLE; RESET SESSION AUTHORIZATION;
SELECT t_ok((SELECT count(*) FROM audit.audit_log WHERE table_name = 'encounters'
             AND row_pk = '12000000-0000-0000-0000-000000000001') >= 3, 'encounter create, sign and amend all audited');
SELECT t_ok((SELECT user_id FROM audit.audit_log WHERE table_name = 'encounter_amendments' LIMIT 1)
  = '00000000-0000-0000-0000-0000000000d1', 'audit row names the application user');
SELECT t_ok((SELECT new_values ? 'status' AND NOT new_values ? 'assessment' FROM audit.audit_log
  WHERE table_name = 'encounters' AND action = 'UPDATE' ORDER BY audit_id LIMIT 1), 'UPDATE audit stores only changed columns');
SELECT t_ok((SELECT bool_and(ok) FROM audit.verify_chain('00000000-0000-0000-0000-00000000c0a1')),
  'hash chain for centre A verifies');
SELECT t_fails($$UPDATE audit.audit_log SET reason = 'tamper' WHERE audit_id = 1$$, 'audit log cannot be updated, even by superuser', '42501');
SELECT t_fails($$DELETE FROM audit.audit_log WHERE audit_id = 1$$, 'audit log cannot be deleted, even by superuser', '42501');
SELECT t_fails($$TRUNCATE audit.audit_log$$, 'audit log cannot be truncated', '42501');
ALTER TABLE audit.audit_log_default DISABLE TRIGGER USER;          -- a rogue superuser
UPDATE audit.audit_log SET new_values = jsonb_set(new_values, '{assessment}', '"edited"')
 WHERE table_name = 'encounters' AND action = 'INSERT' AND chain_key = '00000000-0000-0000-0000-00000000c0a1';
ALTER TABLE audit.audit_log_default ENABLE TRIGGER USER;
SELECT t_ok(EXISTS (SELECT 1 FROM audit.verify_chain('00000000-0000-0000-0000-00000000c0a1') WHERE NOT ok),
  'tampering by a superuser who disabled triggers is detected by the hash chain');
SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_clinician;
SELECT t_fails($$SELECT * FROM audit.audit_log$$, 'clinicians cannot read the audit log', '42501');
RESET ROLE; RESET SESSION AUTHORIZATION;

\echo '--- 11. Clinical calculations against hand-computed reference values'
SELECT t_ok(registry.ldl_pct_reduction(160, 70) = 56.3, 'LDL 160 -> 70 mg/dL = 56.3% reduction');
SELECT t_ok(registry.ldl_pct_reduction(0, 70) IS NULL, 'no % reduction from a zero baseline');
SELECT t_ok(registry.ldl_friedewald(200, 40, 150) = 130.0, 'Friedewald 200 - 40 - 150/5 = 130');
SELECT t_ok(registry.ldl_friedewald(200, 40, 450) IS NULL, 'Friedewald not computed when TG >= 400');
SELECT t_ok(registry.statin_intensity((SELECT rule_set_id FROM ref.rule_sets WHERE rule_set_code = 'ACC_AHA_2018'),
  (SELECT drug_id FROM ref.drugs WHERE drug_code = 'ATORVASTATIN'), 40) = 'high', 'atorvastatin 40 mg = high intensity');
SELECT t_ok(registry.statin_intensity((SELECT rule_set_id FROM ref.rule_sets WHERE rule_set_code = 'ACC_AHA_2018'),
  (SELECT drug_id FROM ref.drugs WHERE drug_code = 'ROSUVASTATIN_EZETIMIBE'), 10) = 'moderate',
  'rosuvastatin/ezetimibe 10 mg = moderate-intensity statin');
SELECT t_ok(registry.ldl_target_met((SELECT rule_set_id FROM ref.rule_sets WHERE rule_set_code = 'ESC_EAS_2019'),
  'very_high', 50, 56.3), 'very high risk: 50 mg/dL with 56% reduction meets target');
SELECT t_ok(NOT registry.ldl_target_met((SELECT rule_set_id FROM ref.rule_sets WHERE rule_set_code = 'ESC_EAS_2019'),
  'very_high', 50, 40), 'very high risk: 50 mg/dL with only 40% reduction does not');
RESET ROLE; RESET SESSION AUTHORIZATION;
SELECT t_fails($$INSERT INTO registry.lipid_assessment_data (assessment_id, patient_id, centre_id, lipid_test_status, target_status)
  VALUES ('17000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  'not_tested','not_at_target_on_max_tolerated')$$, 'lipid visit without a test cannot be called not-at-target', '23');
SELECT t_ok(registry.classify_hf_phenotype(35) = 'HFrEF' AND registry.classify_hf_phenotype(45) = 'HFmrEF'
  AND registry.classify_hf_phenotype(55) = 'HFpEF' AND registry.classify_hf_phenotype(45, 30) = 'HFimpEF'
  AND registry.classify_hf_phenotype(45, 38) = 'HFmrEF', 'HF phenotype by LVEF, incl. HFimpEF (+10 points from <= 40)');
