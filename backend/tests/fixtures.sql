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

UPDATE registry.registry_protocols SET status = 'active', approved_at = now() WHERE protocol_code IN ('CEMR-HF','CEMR-CAD');
INSERT INTO registry.protocol_sites (protocol_id, centre_id, ethics_approval_ref, site_status)
SELECT protocol_id, c, 'EC/2027/001', 'active' FROM registry.registry_protocols,
  unnest(ARRAY['00000000-0000-0000-0000-00000000c0a1','00000000-0000-0000-0000-00000000c0b1']::uuid[]) c
 WHERE protocol_code IN ('CEMR-HF','CEMR-CAD');

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
