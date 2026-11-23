-- CardioEMR migration 0008: acceptance tests.  Runs after test_0007 (same database).
\set ON_ERROR_STOP 1
\echo '--- 20. Migration 0008: consultation support'
RESET ROLE; RESET SESSION AUTHORIZATION;
SELECT t_ok((SELECT count(*) FROM ref.drugs WHERE drug_code IN ('AMLODIPINE','ISOSORBIDE_MONONITRATE','METFORMIN',
             'ATENOLOL','RANOLAZINE')) = 5, 'common outpatient drugs are in the catalogue');
SELECT t_ok(NOT EXISTS (SELECT 1 FROM ref.drug_class_members m JOIN ref.drugs d USING (drug_id)
             WHERE d.drug_code IN ('ATENOLOL','PROPRANOLOL') AND m.drug_class_code = 'BETA_BLOCKER'),
  'atenolol and propranolol are not evidence-based HF beta-blockers');
SELECT t_ok(NOT EXISTS (SELECT 1 FROM ref.drugs d WHERE NOT EXISTS
             (SELECT 1 FROM ref.drug_class_members m WHERE m.drug_id = d.drug_id)), 'every drug has a class');
SELECT t_as('clinician','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-00000000c0a1');
SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_clinician;
INSERT INTO clinical.encounters (encounter_id, patient_id, centre_id, clinician_id, encounter_type)
VALUES ('16000000-0000-0000-0000-000000000801','10000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-00000000c0a1','00000000-0000-0000-0000-0000000000d1','follow_up');
INSERT INTO clinical.encounter_complaints (encounter_id, patient_id, centre_id, complaint_concept_id)
SELECT '16000000-0000-0000-0000-000000000801','10000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-00000000c0a1', concept_id FROM ref.concepts WHERE concept_code IN ('CX_CHEST_PAIN','CX_SYNCOPE');
DELETE FROM clinical.encounter_complaints WHERE encounter_id = '16000000-0000-0000-0000-000000000801'
   AND complaint_concept_id = (SELECT concept_id FROM ref.concepts WHERE concept_code = 'CX_SYNCOPE');
SELECT t_ok((SELECT count(*) FROM clinical.encounter_complaints
             WHERE encounter_id = '16000000-0000-0000-0000-000000000801') = 1, 'a complaint can be removed from a draft');
UPDATE clinical.encounters SET status = 'signed', signed_at = now(), signed_by = '00000000-0000-0000-0000-0000000000d1'
 WHERE encounter_id = '16000000-0000-0000-0000-000000000801';
SELECT t_fails($$DELETE FROM clinical.encounter_complaints WHERE encounter_id = '16000000-0000-0000-0000-000000000801'$$,
  'complaints of a signed consultation cannot be removed', '42501');
RESET ROLE; SET ROLE r_assistant;
SELECT t_fails($$DELETE FROM clinical.encounter_complaints WHERE encounter_id = '16000000-0000-0000-0000-000000000801'$$,
  'assistants cannot remove complaints', '42501');
RESET ROLE; RESET SESSION AUTHORIZATION;
SELECT t_ok(EXISTS (SELECT 1 FROM ref.api_error_map WHERE source_name = 'cemr:ENCOUNTER_SIGNED'),
  'signed-encounter error is mapped');
