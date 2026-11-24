-- =====================================================================
-- CardioEMR  migration 0010_stent_catalogue   (2026-11-24)
-- Seeds ref.stent_devices (created empty in 0001) so PCI entry can pick
-- the stent from a list instead of typing its make and model.  Typed
-- device_text stays as the fallback for stents not in the catalogue.
--
-- Adds what a registry analysis of DES generations needs: polymer kind
-- (durable / biodegradable / polymer-free), polymer, strut thickness range
-- across sizes, other names, and a review status.  Every row is seeded
-- 'pending_clinical_review': the device facts were filled from published
-- manufacturer data from memory and must be checked by the clinical lead
-- before research use.  FOR CLINICAL REVIEW.
-- =====================================================================
SET check_function_bodies = off;

ALTER TABLE ref.stent_devices
  ADD COLUMN polymer_type text CHECK (polymer_type IN ('durable','biodegradable','polymer_free')),
  ADD COLUMN polymer text,
  ADD COLUMN strut_thickness_min_um numeric(5,1) CHECK (strut_thickness_min_um BETWEEN 20 AND 250),
  ADD COLUMN strut_thickness_max_um numeric(5,1) CHECK (strut_thickness_max_um BETWEEN 20 AND 250),
  ADD COLUMN aliases text[] NOT NULL DEFAULT '{}',
  ADD COLUMN review_status text NOT NULL DEFAULT 'pending_clinical_review'
    CHECK (review_status IN ('pending_clinical_review','verified')),
  ADD COLUMN review_note text,
  ADD COLUMN sort_order smallint NOT NULL DEFAULT 100,
  ADD CONSTRAINT stent_devices_strut_range CHECK (strut_thickness_max_um >= strut_thickness_min_um),
  ADD CONSTRAINT stent_devices_des_drug CHECK (device_type NOT IN ('DES','DCB') OR drug IS NOT NULL);

INSERT INTO ref.stent_devices (manufacturer, platform_name, device_type, drug, strut_material, polymer_type, polymer,
                               strut_thickness_min_um, strut_thickness_max_um, aliases, review_note, sort_order) VALUES
 ('Abbott Vascular', 'XIENCE Skypoint', 'DES', 'everolimus', 'cobalt-chromium (L-605)', 'durable',
  'fluoropolymer (PBMA + PVDF-HFP)', 81, 81, ARRAY['Xience', 'Skypoint'],
  'Strut thickness of the 4.5-5.0 mm sizes to confirm', 10),
 ('Medtronic', 'Onyx Frontier', 'DES', 'zotarolimus', 'cobalt alloy with platinum-iridium core (core wire)', 'durable',
  'BioLinx', 81, 91, ARRAY['Resolute Onyx Frontier', 'Onyx'],
  '81 um up to 4.0 mm, 91 um for 4.5-5.0 mm', 20),
 ('Terumo', 'Ultimaster Nagomi', 'DES', 'sirolimus', 'cobalt-chromium', 'biodegradable',
  'PDLLA-PCL, abluminal gradient coating', 80, 80, ARRAY['Ultimaster', 'Nagomi'], NULL, 30),
 ('Boston Scientific', 'SYNERGY XD', 'DES', 'everolimus', 'platinum-chromium', 'biodegradable',
  'PLGA, abluminal', 74, 81, ARRAY['Synergy'],
  '74 um small, 79 um 4.0 mm, 81 um 4.5-5.0 mm', 40),
 ('Boston Scientific', 'SYNERGY MEGATRON', 'DES', 'everolimus', 'platinum-chromium', 'biodegradable',
  'PLGA, abluminal', 89, 89, ARRAY['Megatron'],
  'Large-vessel / left main platform (3.5-5.0 mm); strut thickness to confirm', 50),
 ('iVascular', 'Angiolite', 'DES', 'sirolimus', 'cobalt-chromium', 'durable',
  'fluoroacrylate', 75, 75, ARRAY['Angiolite'],
  'Polymer kind (durable fluoroacrylate) to confirm', 60),
 ('Sahajanand Medical Technologies (SMT)', 'Supraflex Cruz', 'DES', 'sirolimus', 'cobalt-chromium (L-605)', 'biodegradable',
  'PLLA, PLGA, PLC and PVP blend', 60, 60, ARRAY['Supraflex', 'SMT'], NULL, 70),
 ('Biotronik', 'Orsiro', 'DES', 'sirolimus', 'cobalt-chromium (L-605)', 'biodegradable',
  'PLLA (BIOlute) over PROBIO silicon carbide', 60, 80, ARRAY['Orsiro Mission'],
  '60 um up to 3.0 mm, 80 um 3.5-4.0 mm; Orsiro Mission is the same stent on a newer delivery system', 80),
 ('Biosensors International', 'BioMatrix Flex', 'DES', 'biolimus A9', 'stainless steel (316L)', 'biodegradable',
  'PLA, abluminal', 120, 120, ARRAY['BioMatrix', 'Biomatrix'],
  'Named "Biomatrix" by the requester; confirm the model used (Flex: stainless steel; Alpha: cobalt-chromium)', 90);

-- The API reads the catalogue through a view that shows active devices in
-- picker order; every role that reads ref tables can read it.
CREATE VIEW ref.v_stent_catalogue AS
  SELECT stent_device_id, manufacturer, platform_name, platform_name || ' (' || manufacturer || ')' AS display_name,
         device_type, drug, strut_material, polymer_type, polymer, strut_thickness_min_um, strut_thickness_max_um,
         aliases, review_status, review_note, status, sort_order
    FROM ref.stent_devices;
GRANT SELECT ON ref.v_stent_catalogue TO r_assistant, r_nurse, r_clinician, r_research_coordinator,
  r_principal_investigator, r_centre_admin, r_platform_admin;

-- A retired device stays on stents that already name it, but cannot be
-- put on a new stent or swapped in on an edit.
CREATE OR REPLACE FUNCTION clinical.pci_stent_device_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stent_device_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.stent_device_id IS DISTINCT FROM OLD.stent_device_id)
     AND EXISTS (SELECT 1 FROM ref.stent_devices WHERE stent_device_id = NEW.stent_device_id AND status = 'retired') THEN
    RAISE EXCEPTION 'this stent is retired from the catalogue; pick another or type the make and model'
      USING ERRCODE = 'check_violation', HINT = 'cemr:STENT_RETIRED';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER pci_stents_device_guard BEFORE INSERT OR UPDATE OF stent_device_id ON clinical.pci_stents
  FOR EACH ROW EXECUTE FUNCTION clinical.pci_stent_device_guard();

INSERT INTO ref.api_error_map (source_kind, source_name, error_code, http_status, title) VALUES
 ('hint','cemr:STENT_RETIRED','STENT_RETIRED',422,'This stent is retired from the catalogue'),
 ('constraint','pci_stents_stent_device_id_fkey','STENT_UNKNOWN',422,'This stent is not in the catalogue')
ON CONFLICT DO NOTHING;
