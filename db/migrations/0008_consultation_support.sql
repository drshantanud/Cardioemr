-- =====================================================================
-- CardioEMR  migration 0008_consultation_support   (2026-11-23)
-- What the consultation screen and prescribing need:
--   1. Presenting complaints can be removed from a DRAFT consultation
--      (the API replaces the list on save).  Signed consultations stay
--      frozen: a delete is refused exactly like an insert or update.
--   2. More drugs that cardiology outpatients commonly take (anti-anginals,
--      calcium-channel blockers, thiazides, antiarrhythmics, diabetes,
--      gastroprotection), so a whole prescription can be written.  New
--      classes keep them out of the GDMT pillars; atenolol and propranolol
--      sit in their own class so they do not count as evidence-based
--      beta-blockers in heart failure.  FOR CLINICAL REVIEW.
--   3. Error map entries for the consultation rules.
-- =====================================================================
SET check_function_bodies = off;

-- 1. Complaints on a draft ---------------------------------------------
CREATE OR REPLACE FUNCTION clinical.encounter_child_delete_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM clinical.encounters WHERE encounter_id = OLD.encounter_id
               AND status IN ('signed','amended','entered_in_error')) THEN
    RAISE EXCEPTION '% belongs to a signed encounter; record an amendment instead', TG_TABLE_NAME
      USING ERRCODE = 'insufficient_privilege', HINT = 'cemr:ENCOUNTER_SIGNED';
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER encounter_complaints_delete_guard BEFORE DELETE ON clinical.encounter_complaints
  FOR EACH ROW EXECUTE FUNCTION clinical.encounter_child_delete_guard();
GRANT DELETE ON clinical.encounter_complaints TO r_clinician, r_nurse;

-- 2. Drugs ---------------------------------------------------------------
INSERT INTO ref.drug_classes (drug_class_code, display_name) VALUES
 ('CCB', 'Calcium-channel blocker'),
 ('NITRATE', 'Nitrate'),
 ('ANTIANGINAL_OTHER', 'Other anti-anginal'),
 ('THIAZIDE', 'Thiazide or thiazide-like diuretic'),
 ('ANTIARRHYTHMIC', 'Antiarrhythmic'),
 ('VASODILATOR', 'Vasodilator'),
 ('ALPHA_BLOCKER', 'Alpha-blocker'),
 ('BETA_BLOCKER_NON_HF', 'Beta-blocker (not an evidence-based HF beta-blocker)'),
 ('SGC_STIMULATOR', 'Soluble guanylate cyclase stimulator'),
 ('VASOPRESSIN_ANTAGONIST', 'Vasopressin antagonist'),
 ('FIBRATE', 'Fibrate'),
 ('ANTIDIABETIC', 'Glucose-lowering drug'),
 ('PPI', 'Proton-pump inhibitor'),
 ('POTASSIUM', 'Potassium supplement');

INSERT INTO ref.drugs (drug_code, generic_name, atc_code, is_combination, reference_ingredient, reference_unit,
                       default_route) VALUES
 ('AMLODIPINE','Amlodipine','C08CA01',false,'amlodipine','mg','oral'),
 ('CILNIDIPINE','Cilnidipine','C08CA14',false,'cilnidipine','mg','oral'),
 ('DILTIAZEM','Diltiazem','C08DB01',false,'diltiazem','mg','oral'),
 ('VERAPAMIL','Verapamil','C08DA01',false,'verapamil','mg','oral'),
 ('ISOSORBIDE_MONONITRATE','Isosorbide mononitrate','C01DA14',false,'isosorbide mononitrate','mg','oral'),
 ('ISOSORBIDE_DINITRATE','Isosorbide dinitrate','C01DA08',false,'isosorbide dinitrate','mg','oral'),
 ('GLYCERYL_TRINITRATE','Glyceryl trinitrate (nitroglycerin)','C01DA02',false,'glyceryl trinitrate','mg','sublingual'),
 ('NICORANDIL','Nicorandil','C01DX16',false,'nicorandil','mg','oral'),
 ('RANOLAZINE','Ranolazine','C01EB18',false,'ranolazine','mg','oral'),
 ('TRIMETAZIDINE','Trimetazidine','C01EB15',false,'trimetazidine','mg','oral'),
 ('AMIODARONE','Amiodarone','C01BD01',false,'amiodarone','mg','oral'),
 ('HYDROCHLOROTHIAZIDE','Hydrochlorothiazide','C03AA03',false,'hydrochlorothiazide','mg','oral'),
 ('CHLORTHALIDONE','Chlorthalidone','C03BA04',false,'chlorthalidone','mg','oral'),
 ('METOLAZONE','Metolazone','C03BA08',false,'metolazone','mg','oral'),
 ('HYDRALAZINE','Hydralazine','C02DB02',false,'hydralazine','mg','oral'),
 ('PRAZOSIN','Prazosin','C02CA01',false,'prazosin','mg','oral'),
 ('ATENOLOL','Atenolol','C07AB03',false,'atenolol','mg','oral'),
 ('PROPRANOLOL','Propranolol','C07AA05',false,'propranolol','mg','oral'),
 ('VERICIGUAT','Vericiguat','C01DX22',false,'vericiguat','mg','oral'),
 ('TOLVAPTAN','Tolvaptan','C03XA01',false,'tolvaptan','mg','oral'),
 ('FENOFIBRATE','Fenofibrate','C10AB05',false,'fenofibrate','mg','oral'),
 ('METFORMIN','Metformin','A10BA02',false,'metformin','mg','oral'),
 ('SITAGLIPTIN','Sitagliptin','A10BH01',false,'sitagliptin','mg','oral'),
 ('PANTOPRAZOLE','Pantoprazole','A02BC02',false,'pantoprazole','mg','oral'),
 ('POTASSIUM_CHLORIDE','Potassium chloride','A12BA01',false,'potassium chloride','mg','oral');

INSERT INTO ref.drug_class_members (drug_id, drug_class_code)
SELECT d.drug_id, m.cls FROM ref.drugs d JOIN (VALUES
 ('AMLODIPINE','CCB'), ('CILNIDIPINE','CCB'), ('DILTIAZEM','CCB'), ('VERAPAMIL','CCB'),
 ('ISOSORBIDE_MONONITRATE','NITRATE'), ('ISOSORBIDE_DINITRATE','NITRATE'), ('GLYCERYL_TRINITRATE','NITRATE'),
 ('NICORANDIL','ANTIANGINAL_OTHER'), ('RANOLAZINE','ANTIANGINAL_OTHER'), ('TRIMETAZIDINE','ANTIANGINAL_OTHER'),
 ('AMIODARONE','ANTIARRHYTHMIC'), ('HYDROCHLOROTHIAZIDE','THIAZIDE'), ('CHLORTHALIDONE','THIAZIDE'),
 ('METOLAZONE','THIAZIDE'), ('HYDRALAZINE','VASODILATOR'), ('PRAZOSIN','ALPHA_BLOCKER'),
 ('ATENOLOL','BETA_BLOCKER_NON_HF'), ('PROPRANOLOL','BETA_BLOCKER_NON_HF'), ('VERICIGUAT','SGC_STIMULATOR'),
 ('TOLVAPTAN','VASOPRESSIN_ANTAGONIST'), ('FENOFIBRATE','FIBRATE'), ('METFORMIN','ANTIDIABETIC'),
 ('SITAGLIPTIN','ANTIDIABETIC'), ('PANTOPRAZOLE','PPI'), ('POTASSIUM_CHLORIDE','POTASSIUM')
) m(code, cls) ON m.code = d.drug_code;

-- 3. Errors --------------------------------------------------------------
INSERT INTO ref.api_error_map (source_kind, source_name, error_code, http_status, title) VALUES
 ('hint','cemr:ENCOUNTER_SIGNED','ENCOUNTER_SIGNED',409,'The consultation is signed; record an amendment instead')
ON CONFLICT DO NOTHING;
