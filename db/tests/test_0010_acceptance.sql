-- CardioEMR migration 0010: acceptance tests.  Runs after test_0009 (same database).
\set ON_ERROR_STOP 1
\echo '--- 22. Migration 0010: stent catalogue'
RESET ROLE; RESET SESSION AUTHORIZATION;
SELECT t_ok((SELECT count(*) FROM ref.stent_devices WHERE platform_name IN ('XIENCE Skypoint','Onyx Frontier',
             'Ultimaster Nagomi','SYNERGY XD','SYNERGY MEGATRON','Angiolite','Supraflex Cruz','Orsiro','BioMatrix Flex')
             AND device_type = 'DES' AND status = 'active') = 9, 'the nine requested stents are in the catalogue');
SELECT t_ok(NOT EXISTS (SELECT 1 FROM ref.stent_devices WHERE drug IS NULL OR polymer_type IS NULL
             OR strut_thickness_min_um IS NULL), 'every seeded stent has its drug, polymer kind and strut thickness');
SELECT t_ok(NOT EXISTS (SELECT 1 FROM ref.stent_devices WHERE review_status <> 'pending_clinical_review'),
  'every seeded stent waits for clinical review');
SELECT t_fails($$INSERT INTO ref.stent_devices (manufacturer, platform_name, device_type) VALUES ('X','Y','DES')$$,
  'a DES needs its drug', '23514');

-- A clinician records stents from the catalogue and by typed name.
SELECT t_as('clinician','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-00000000c0a1');
SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_clinician;
SELECT t_ok((SELECT count(*) FROM ref.v_stent_catalogue) >= 9, 'a clinician reads the catalogue');
INSERT INTO clinical.pci_procedures (procedure_id, patient_id, centre_id, procedure_date, indication)
VALUES ('19000000-0000-0000-0000-000000001001','10000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-00000000c0a1', DATE '2026-11-20', 'chronic_coronary_syndrome');
INSERT INTO clinical.pci_lesions (lesion_id, procedure_id, patient_id, centre_id, lesion_number, vessel, treatment)
VALUES ('19000000-0000-0000-0000-000000001101','19000000-0000-0000-0000-000000001001',
        '10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1', 1, 'LAD', 'stent');
INSERT INTO clinical.pci_stents (stent_id, lesion_id, patient_id, centre_id, sequence_number, stent_device_id, diameter_mm, length_mm)
SELECT '19000000-0000-0000-0000-000000001201','19000000-0000-0000-0000-000000001101',
       '10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000c0a1', 1, stent_device_id, 3.0, 28
  FROM ref.stent_devices WHERE platform_name = 'Orsiro';
INSERT INTO clinical.pci_stents (lesion_id, patient_id, centre_id, sequence_number, device_text, diameter_mm, length_mm)
VALUES ('19000000-0000-0000-0000-000000001101','10000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-00000000c0a1', 2, 'Yukon Choice PC', 3.5, 12);
SELECT t_ok((SELECT count(*) FROM clinical.pci_stents WHERE lesion_id = '19000000-0000-0000-0000-000000001101') = 2,
  'stents are recorded from the catalogue and as typed text');
SELECT t_fails($$INSERT INTO ref.stent_devices (manufacturer, platform_name, device_type, drug)
                 VALUES ('X','Y','DES','sirolimus')$$, 'a clinician cannot add to the catalogue', '42501');

-- Retire a device: existing stents keep it, new stents cannot use it.
RESET ROLE; RESET SESSION AUTHORIZATION;
UPDATE ref.stent_devices SET status = 'retired' WHERE platform_name = 'Orsiro';
SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_clinician;
UPDATE clinical.pci_stents SET deployment_atm = 14 WHERE stent_id = '19000000-0000-0000-0000-000000001201';
SELECT t_ok((SELECT deployment_atm FROM clinical.pci_stents WHERE stent_id = '19000000-0000-0000-0000-000000001201') = 14,
  'a stent that names a retired device can still be edited');
SELECT t_fails($$INSERT INTO clinical.pci_stents (lesion_id, patient_id, centre_id, sequence_number, stent_device_id, diameter_mm, length_mm)
  SELECT '19000000-0000-0000-0000-000000001101','10000000-0000-0000-0000-000000000001',
         '00000000-0000-0000-0000-00000000c0a1', 3, stent_device_id, 3.0, 18 FROM ref.stent_devices WHERE platform_name = 'Orsiro'$$,
  'a retired device cannot go on a new stent', '23514');
SELECT t_fails($$INSERT INTO clinical.pci_stents (lesion_id, patient_id, centre_id, sequence_number, stent_device_id, diameter_mm, length_mm)
  VALUES ('19000000-0000-0000-0000-000000001101','10000000-0000-0000-0000-000000000001',
          '00000000-0000-0000-0000-00000000c0a1', 3, gen_random_uuid(), 3.0, 18)$$,
  'an unknown device is refused', '23503');
RESET ROLE; RESET SESSION AUTHORIZATION;
UPDATE ref.stent_devices SET status = 'active' WHERE platform_name = 'Orsiro';
SELECT t_ok(EXISTS (SELECT 1 FROM ref.api_error_map WHERE source_name = 'cemr:STENT_RETIRED')
        AND EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pci_stents_stent_device_id_fkey'),
  'stent errors are mapped');
