-- API test fixture, loaded by the migration owner after migrations 0001-0005.
-- Two organisations, two centres; users map to token subjects 'sub-*'.
INSERT INTO iam.organisations (organisation_id, organisation_name, organisation_type) VALUES
 ('00000000-0000-0000-0000-0000000000a1','Heart Clinic Pune','clinic'),
 ('00000000-0000-0000-0000-0000000000b1','City Hospital Mumbai','hospital');
INSERT INTO iam.centres (centre_id, organisation_id, centre_name, centre_code) VALUES
 ('00000000-0000-0000-0000-00000000c0a1','00000000-0000-0000-0000-0000000000a1','Pune Main','PUN1'),
 ('00000000-0000-0000-0000-00000000c0b1','00000000-0000-0000-0000-0000000000b1','Mumbai Cardiology','MUM1');
INSERT INTO iam.users (user_id, full_name, email, auth_subject) VALUES
 ('00000000-0000-0000-0000-0000000000d1','Dr A','dra@example.org','sub-dra'),
 ('00000000-0000-0000-0000-0000000000d2','Assistant A','asa@example.org','sub-asa'),
 ('00000000-0000-0000-0000-0000000000d3','Dr B','drb@example.org','sub-drb'),
 ('00000000-0000-0000-0000-0000000000d4','PI A','pia@example.org','sub-pia'),
 ('00000000-0000-0000-0000-0000000000d7','Coordinator A','rca@example.org','sub-rca'),
 ('00000000-0000-0000-0000-0000000000d8','Nurse A','nua@example.org','sub-nua');
INSERT INTO iam.users (user_id, full_name, email, auth_subject, status) VALUES
 ('00000000-0000-0000-0000-0000000000d9','Suspended','sus@example.org','sub-sus','suspended');
INSERT INTO iam.user_centre_roles (user_id, organisation_id, centre_id, role) VALUES
 ('00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c0a1','clinician'),
 ('00000000-0000-0000-0000-0000000000d2','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c0a1','assistant'),
 ('00000000-0000-0000-0000-0000000000d3','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-00000000c0b1','clinician'),
 ('00000000-0000-0000-0000-0000000000d4','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c0a1','principal_investigator'),
 ('00000000-0000-0000-0000-0000000000d7','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c0a1','research_coordinator'),
 ('00000000-0000-0000-0000-0000000000d8','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c0a1','nurse');

UPDATE registry.registry_protocols SET status = 'active', approved_at = now()
 WHERE protocol_code IN ('CEMR-HF','CEMR-CAD','CEMR-LIPID');
INSERT INTO registry.protocol_sites (protocol_id, centre_id, ethics_approval_ref, site_status)
SELECT protocol_id, c, 'EC/2027/001', 'active' FROM registry.registry_protocols,
  unnest(ARRAY['00000000-0000-0000-0000-00000000c0a1','00000000-0000-0000-0000-00000000c0b1']::uuid[]) c
 WHERE protocol_code IN ('CEMR-HF','CEMR-CAD','CEMR-LIPID');

-- Patient at Pune, with clinical-care consent, HF research consent and an open HF suggestion.
SELECT set_config('app.centre_id', '00000000-0000-0000-0000-00000000c0a1', false),
       set_config('app.user_id', '00000000-0000-0000-0000-0000000000d1', false);
INSERT INTO clinical.patients (patient_id) VALUES ('10000000-0000-0000-0000-000000000001');
INSERT INTO clinical.patient_registrations (registration_id, patient_id, centre_id, local_patient_code, first_name,
  last_name, date_of_birth, sex, mobile)
VALUES ('11000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','PUN1-000001','Ramesh','Kulkarni','1968-03-14','male','9822000001');
INSERT INTO clinical.patient_consents (consent_id, patient_id, centre_id, consent_type, consent_form_version, consent_date,
  consent_method) VALUES ('15000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1','clinical_care','v1', current_date,'written');
INSERT INTO clinical.patient_consents (consent_id, patient_id, centre_id, consent_type, protocol_id, consent_form_version,
  consent_date, consent_method)
SELECT '15000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1',
  'research_registry', protocol_id, 'HF-ICF v1.0', current_date, 'written'
  FROM registry.registry_protocols WHERE protocol_code = 'CEMR-HF';
INSERT INTO registry.registry_suggestions (suggestion_id, patient_id, centre_id, registry_code) VALUES
 ('18000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1','HF');
SELECT set_config('app.centre_id', '', false), set_config('app.user_id', '', false);

-- Patient 2 at Pune: a charted HFrEF patient for prefill, GDMT, lipid targets and PCI.
-- Female, born 1958-07-02; consents for HF, lipid and CAD research.
SELECT set_config('app.centre_id', '00000000-0000-0000-0000-00000000c0a1', false),
       set_config('app.user_id', '00000000-0000-0000-0000-0000000000d1', false);
INSERT INTO clinical.patients (patient_id) VALUES ('10000000-0000-0000-0000-000000000002');
INSERT INTO clinical.patient_registrations (registration_id, patient_id, centre_id, local_patient_code, first_name,
  last_name, date_of_birth, sex, mobile)
VALUES ('11000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-00000000c0a1','PUN1-000002','Sunita','Deshpande','1958-07-02','female','9822000002');
INSERT INTO clinical.patient_consents (consent_id, patient_id, centre_id, consent_type, protocol_id, consent_form_version,
  consent_date, consent_method)
SELECT c.id::uuid, '10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0a1',
  'research_registry', p.protocol_id, 'ICF v1.0', current_date, 'written'
  FROM (VALUES ('15000000-0000-0000-0000-000000000012','CEMR-HF'), ('15000000-0000-0000-0000-000000000013','CEMR-LIPID'),
               ('15000000-0000-0000-0000-000000000014','CEMR-CAD')) c(id, code)
  JOIN registry.registry_protocols p ON p.protocol_code = c.code;

INSERT INTO clinical.encounters (encounter_id, patient_id, centre_id, clinician_id, encounter_type, encounter_start)
VALUES ('16000000-0000-0000-0000-000000000021','10000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-00000000c0a1','00000000-0000-0000-0000-0000000000d1','follow_up','2026-11-21 10:00+05:30');
INSERT INTO clinical.clinical_assessments (encounter_id, patient_id, centre_id, nyha_class, jvp, peripheral_oedema,
  congestion_status)
VALUES ('16000000-0000-0000-0000-000000000021','10000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-00000000c0a1','III','raised','ankle','mild');

-- Vitals: one inside the baseline window, one older that must not be used.
INSERT INTO clinical.vital_signs (vital_id, patient_id, centre_id, measured_at, height_cm, weight_kg, systolic_bp,
  diastolic_bp, heart_rate) VALUES
 ('17000000-0000-0000-0000-000000000021','10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0a1',
  '2026-11-21 10:05+05:30', 158, 64.0, 108, 68, 64),
 ('17000000-0000-0000-0000-000000000022','10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0a1',
  '2026-10-01 10:05+05:30', NULL, 66.0, 130, 80, 88);

INSERT INTO clinical.investigations (investigation_id, patient_id, centre_id, investigation_type, performed_on) VALUES
 ('19000000-0000-0000-0000-000000000021','10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0a1',
  'lab','2026-11-18'),
 ('19000000-0000-0000-0000-000000000022','10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0a1',
  'echo','2026-11-12');
INSERT INTO clinical.lab_results (investigation_id, patient_id, centre_id, analyte_code, collected_at, value_reported,
  unit_reported, method)
SELECT '19000000-0000-0000-0000-000000000021','10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0a1',
  a, '2026-11-18 08:00+05:30', v, u, m
  FROM (VALUES ('CREATININE',1.0,'mg/dL',NULL), ('NT_PROBNP',1850,'pg/mL',NULL), ('HB',11.8,'g/dL',NULL),
               ('K',4.8,'mmol/L',NULL), ('NA',137,'mmol/L',NULL), ('LDL_C',88,'mg/dL','direct'),
               ('HDL_C',42,'mg/dL',NULL), ('TC',150,'mg/dL',NULL), ('TG',120,'mg/dL',NULL)) x(a, v, u, m);
INSERT INTO clinical.echo_reports (investigation_id, patient_id, centre_id, lvef, lvef_method, lvedd_mm, lvesd_mm,
  tapse_mm, rv_function, rwma)
VALUES ('19000000-0000-0000-0000-000000000022','10000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-00000000c0a1', 30, 'biplane_simpson', 61, 50, 16, 'mildly_reduced', true);

INSERT INTO clinical.diagnoses (patient_id, centre_id, concept_id, diagnosis_text, diagnosis_role, certainty)
SELECT '10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0a1', concept_id, display_name,
  'final', cert
  FROM (VALUES ('DX_HF','confirmed'), ('DX_DM','confirmed'), ('DX_HTN','confirmed'), ('DX_CAD','confirmed'),
               ('DX_AF','suspected')) x(code, cert)
  JOIN ref.concepts ON concept_code = x.code;
UPDATE registry.registry_suggestions SET status = 'dismissed', dismiss_reason = 'fixture'
 WHERE patient_id = '10000000-0000-0000-0000-000000000002';
INSERT INTO clinical.lifestyle_observations (patient_id, centre_id, observed_on, smoking_status)
VALUES ('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0a1','2026-06-01','former');

-- Medicines: ARNI 25 %, carvedilol up-titrated to 50 %, dapagliflozin at target, spironolactone stopped,
-- aspirin + clopidogrel, atorvastatin 40 mg.
INSERT INTO clinical.medication_courses (course_id, patient_id, centre_id, drug_id, started_on)
SELECT c.id::uuid, '10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0a1', d.drug_id, c.started::date
  FROM (VALUES ('1a000000-0000-0000-0000-000000000001','SACUBITRIL_VALSARTAN','2026-10-01'),
               ('1a000000-0000-0000-0000-000000000002','CARVEDILOL','2026-10-01'),
               ('1a000000-0000-0000-0000-000000000003','DAPAGLIFLOZIN','2026-10-01'),
               ('1a000000-0000-0000-0000-000000000004','SPIRONOLACTONE','2026-10-01'),
               ('1a000000-0000-0000-0000-000000000005','ASPIRIN','2026-01-10'),
               ('1a000000-0000-0000-0000-000000000006','CLOPIDOGREL','2026-01-10'),
               ('1a000000-0000-0000-0000-000000000007','ATORVASTATIN','2026-01-10')) c(id, code, started)
  JOIN ref.drugs d ON d.drug_code = c.code;
INSERT INTO clinical.medication_events (course_id, patient_id, centre_id, event_type, effective_date, drug_id,
  daily_dose, frequency_code, prescribed_by, reason_text, recorded_at)
SELECT e.course::uuid, '10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000c0a1', e.kind,
  e.eff::date, c.drug_id, e.dose, e.freq, CASE WHEN e.kind <> 'discontinue' THEN '00000000-0000-0000-0000-0000000000d1'::uuid END,
  e.reason, e.eff::timestamptz
  FROM (VALUES ('1a000000-0000-0000-0000-000000000001','initiate','2026-10-01',100,'BD',NULL),
               ('1a000000-0000-0000-0000-000000000002','initiate','2026-10-01',12.5,'BD',NULL),
               ('1a000000-0000-0000-0000-000000000002','increase','2026-11-05',25,'BD',NULL),
               ('1a000000-0000-0000-0000-000000000003','initiate','2026-10-01',10,'OD',NULL),
               ('1a000000-0000-0000-0000-000000000004','initiate','2026-10-01',25,'OD',NULL),
               ('1a000000-0000-0000-0000-000000000004','discontinue','2026-11-10',NULL,NULL,'Potassium 5.8'),
               ('1a000000-0000-0000-0000-000000000005','initiate','2026-01-10',75,'OD',NULL),
               ('1a000000-0000-0000-0000-000000000006','initiate','2026-01-10',75,'OD',NULL),
               ('1a000000-0000-0000-0000-000000000007','initiate','2026-01-10',40,'OD',NULL))
       e(course, kind, eff, dose, freq, reason)
  JOIN clinical.medication_courses c ON c.course_id = e.course::uuid;
SELECT set_config('app.centre_id', '', false), set_config('app.user_id', '', false);

-- Patient 3 at Pune (migration 0006 tests): enrolled in HF and CAD 200 days ago, with a CAD baseline
-- visit that still misses mandatory values.  Born 1931, so over 89 at index (export age top-coding).
SELECT set_config('app.centre_id', '00000000-0000-0000-0000-00000000c0a1', false),
       set_config('app.user_id', '00000000-0000-0000-0000-0000000000d1', false);
INSERT INTO clinical.patients (patient_id) VALUES ('10000000-0000-0000-0000-000000000003');
INSERT INTO clinical.patient_registrations (registration_id, patient_id, centre_id, local_patient_code, first_name,
  last_name, date_of_birth, sex, mobile)
VALUES ('11000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003',
  '00000000-0000-0000-0000-00000000c0a1','PUN1-000003','Vasant','Joshi','1931-05-20','male','9822000003');
INSERT INTO clinical.patient_consents (consent_id, patient_id, centre_id, consent_type, protocol_id, consent_form_version,
  consent_date, consent_method)
SELECT c.id::uuid, '10000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-00000000c0a1',
  'research_registry', p.protocol_id, 'ICF v1.0', current_date - 205, 'written'
  FROM (VALUES ('15000000-0000-0000-0000-000000000032','CEMR-HF'), ('15000000-0000-0000-0000-000000000034','CEMR-CAD')) c(id, code)
  JOIN registry.registry_protocols p ON p.protocol_code = c.code;
INSERT INTO registry.enrolments (enrolment_id, patient_id, centre_id, registry_type_id, protocol_id, screening_date,
  enrolment_date, index_date, eligibility_status, eligibility_confirmed_by, eligibility_confirmed_at, consent_id,
  enrolment_status, enrolled_by)
SELECT e.id::uuid, '10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000c0a1', p.registry_type_id,
  p.protocol_id, current_date - 205, current_date - 200, current_date - 200, 'eligible',
  '00000000-0000-0000-0000-0000000000d1', now(), e.consent::uuid, 'enrolled', '00000000-0000-0000-0000-0000000000d1'
  FROM (VALUES ('1b000000-0000-0000-0000-000000000032','CEMR-HF','15000000-0000-0000-0000-000000000032'),
               ('1b000000-0000-0000-0000-000000000034','CEMR-CAD','15000000-0000-0000-0000-000000000034')) e(id, code, consent)
  JOIN registry.registry_protocols p ON p.protocol_code = e.code;
INSERT INTO registry.cad_enrolment_details (enrolment_id, patient_id, centre_id, presentation, categories, index_event_date)
VALUES ('1b000000-0000-0000-0000-000000000034','10000000-0000-0000-0000-000000000003',
  '00000000-0000-0000-0000-00000000c0a1','NSTEMI', ARRAY['acute_coronary_syndrome','NSTEMI'], current_date - 200);
INSERT INTO registry.assessments (assessment_id, enrolment_id, patient_id, centre_id, visit_code, assessment_type,
  assessment_date)
VALUES ('1c000000-0000-0000-0000-000000000034','1b000000-0000-0000-0000-000000000034',
  '10000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-00000000c0a1','BL','baseline', current_date - 198);
SELECT set_config('app.centre_id', '', false), set_config('app.user_id', '', false);

-- Study access for exports: the coordinator requests, the PI approves.
INSERT INTO registry.study_memberships (user_id, protocol_id, study_role, approved_by, can_export)
SELECT u.id::uuid, p.protocol_id, u.role, '00000000-0000-0000-0000-0000000000d4', true
  FROM registry.registry_protocols p,
       (VALUES ('00000000-0000-0000-0000-0000000000d4','chief_investigator'),
               ('00000000-0000-0000-0000-0000000000d7','data_manager')) u(id, role)
 WHERE p.protocol_code IN ('CEMR-HF','CEMR-CAD');
