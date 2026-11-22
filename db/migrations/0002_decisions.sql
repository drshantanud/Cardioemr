-- =====================================================================
-- CardioEMR  migration 0002_decisions   (2026-11-22)
-- Applies product-owner decisions on spec v0.1:
--   D5  sacubitril/valsartan stays in labelled total (50/100/200 mg);
--       add the 25 mg strength.
--   D8  LDL-C targets: ESC/EAS 2019 stays primary; Lipid Association of
--       India (LAI) targets are stored alongside at every assessment.
--       LAI values are DRAFT, entered from memory of the LAI 2020
--       consensus, pending verification by the clinical lead.
-- =====================================================================
SET check_function_bodies = off;

-- D5 -----------------------------------------------------------------
INSERT INTO ref.drug_products (drug_id, brand_name, strength_label, reference_strength)
SELECT drug_id, 'Generic', '12/13 mg (25 mg)', 25 FROM ref.drugs WHERE drug_code = 'SACUBITRIL_VALSARTAN';

-- D8: LAI rule set ---------------------------------------------------
INSERT INTO ref.rule_sets (rule_kind, rule_set_code, version, title, source_citation, effective_from, status)
VALUES ('ldl_target','LAI_2020',1,'Lipid Association of India: LDL-C goals by risk category',
        'LAI expert consensus 2020 (to be confirmed by clinical lead)','2020-01-01','draft');

INSERT INTO ref.ldl_target_rules (rule_set_id, risk_category, ldl_target_mg_dl, target_operator, min_pct_reduction,
                                  non_hdl_target_mg_dl)
SELECT rs.rule_set_id, t.cat, t.ldl, t.op, NULL, t.nonhdl FROM ref.rule_sets rs, (VALUES
  ('extreme_a', 50, '<',  80),    -- optional goal <= 30 mg/dL: verify
  ('extreme_b', 30, '<=', 60),
  ('very_high', 50, '<',  80),
  ('high',      70, '<',  100),
  ('moderate', 100, '<',  130),
  ('low',      100, '<',  130)) t(cat, ldl, op, nonhdl)
WHERE rs.rule_set_code = 'LAI_2020';

-- Protocol may name a secondary LDL guideline.
ALTER TABLE registry.registry_protocols
  ADD COLUMN ldl_secondary_rule_set_id uuid REFERENCES ref.rule_sets,
  ADD CONSTRAINT protocols_ldl_secondary_differs
      CHECK (ldl_secondary_rule_set_id IS NULL OR ldl_secondary_rule_set_id <> ldl_target_rule_set_id);

UPDATE registry.registry_protocols
   SET ldl_secondary_rule_set_id = (SELECT rule_set_id FROM ref.rule_sets WHERE rule_set_code = 'LAI_2020')
 WHERE protocol_code = 'CEMR-LIPID';

-- One row per assessment per guideline.  lipid_assessment_data keeps the
-- primary (ESC/EAS) result in its typed columns for the dashboards; this
-- table holds every guideline's result, including the primary one.
CREATE TABLE registry.lipid_target_attainment (
  assessment_id    uuid NOT NULL,
  rule_set_id      uuid NOT NULL REFERENCES ref.rule_sets,
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  is_primary       boolean NOT NULL,
  risk_category    text NOT NULL,                -- category names differ per guideline
  ldl_target_mg_dl numeric(5,1) NOT NULL,
  ldl_mg_dl        numeric(5,1),
  ldl_pct_reduction numeric(5,1),
  target_met       boolean,                      -- NULL when no LDL-C in window
  calculated_at    timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  PRIMARY KEY (assessment_id, rule_set_id),
  FOREIGN KEY (assessment_id, patient_id, centre_id)
    REFERENCES registry.assessments (assessment_id, patient_id, centre_id) ON UPDATE CASCADE,
  FOREIGN KEY (rule_set_id, risk_category) REFERENCES ref.ldl_target_rules (rule_set_id, risk_category)
);
CREATE UNIQUE INDEX lipid_target_attainment_one_primary ON registry.lipid_target_attainment (assessment_id)
  WHERE is_primary;
CREATE INDEX lipid_target_attainment_centre ON registry.lipid_target_attainment (centre_id, rule_set_id, target_met);

-- Standard plumbing, as in 0001: row meta, organisation, audit, RLS, grants.
CREATE TRIGGER zz_touch_row BEFORE UPDATE ON registry.lipid_target_attainment
  FOR EACH ROW EXECUTE FUNCTION app.touch_row();
CREATE TRIGGER aa_set_organisation BEFORE INSERT OR UPDATE OF centre_id ON registry.lipid_target_attainment
  FOR EACH ROW EXECUTE FUNCTION app.set_organisation_from_centre();
CREATE TRIGGER zz_audit AFTER INSERT OR UPDATE OR DELETE ON registry.lipid_target_attainment
  FOR EACH ROW EXECUTE FUNCTION audit.capture('assessment_id','rule_set_id');
ALTER TABLE registry.lipid_target_attainment ENABLE ROW LEVEL SECURITY;
CREATE POLICY centre_isolation ON registry.lipid_target_attainment
  USING (centre_id = (SELECT app.visible_centre())) WITH CHECK (centre_id = (SELECT app.visible_centre()));
GRANT SELECT ON registry.lipid_target_attainment TO r_clinician, r_research_coordinator, r_principal_investigator,
  r_platform_admin;
GRANT INSERT, UPDATE ON registry.lipid_target_attainment TO r_clinician, r_research_coordinator, r_principal_investigator;

-- Fills target and attainment from the rule table, so callers pass only
-- the guideline, its risk category and the LDL-C values.
CREATE OR REPLACE FUNCTION registry.lipid_attainment_fill() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  SELECT ldl_target_mg_dl INTO NEW.ldl_target_mg_dl FROM ref.ldl_target_rules
   WHERE rule_set_id = NEW.rule_set_id AND risk_category = NEW.risk_category;
  IF NEW.ldl_target_mg_dl IS NULL THEN
    RAISE EXCEPTION 'risk category % is not defined in this guideline rule set', NEW.risk_category
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  NEW.target_met := registry.ldl_target_met(NEW.rule_set_id, NEW.risk_category, NEW.ldl_mg_dl, NEW.ldl_pct_reduction);
  NEW.calculated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER a_lipid_attainment_fill BEFORE INSERT OR UPDATE ON registry.lipid_target_attainment
  FOR EACH ROW EXECUTE FUNCTION registry.lipid_attainment_fill();

-- Research view: attainment under every guideline, pseudonymised.
CREATE OR REPLACE VIEW research.v_lipid_target_attainment AS
SELECT s.study_subject_code, a.visit_code, a.days_from_index,
       rs.rule_set_code || ' v' || rs.version AS guideline, t.is_primary, t.risk_category,
       t.ldl_target_mg_dl, t.ldl_mg_dl, t.ldl_pct_reduction, t.target_met
FROM registry.lipid_target_attainment t
JOIN registry.assessments a ON a.assessment_id = t.assessment_id
JOIN registry.enrolments e ON e.enrolment_id = a.enrolment_id
JOIN research.study_subjects s ON s.enrolment_id = e.enrolment_id
JOIN ref.rule_sets rs ON rs.rule_set_id = t.rule_set_id
WHERE e.centre_id = ANY (app.study_centres(e.protocol_id))
  AND NOT EXISTS (SELECT 1 FROM clinical.patient_consents pc
                  WHERE pc.consent_id = e.consent_id AND pc.withdrawal_scope = 'exclude_collected_data');
GRANT SELECT ON research.v_lipid_target_attainment TO r_research_coordinator, r_principal_investigator;

-- Dictionary: clarify the primary category label, add LAI variables.
UPDATE registry.variable_definitions SET variable_label = 'ESC/EAS risk category'
 WHERE variable_code = 'risk_category'
   AND registry_type_id = (SELECT registry_type_id FROM registry.registry_types WHERE registry_code = 'LIPID');
-- Generated by dictionaries.py: lipid dictionary additions for migration 0002
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'lai_risk_category', 'Risk and target', 'LAI risk category', 'coded', NULL, '[{"code": "extreme_a", "label": "extreme a"}, {"code": "extreme_b", "label": "extreme b"}, {"code": "very_high", "label": "very high"}, {"code": "high", "label": "high"}, {"code": "moderate", "label": "moderate"}, {"code": "low", "label": "low"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 0 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lai_risk_category' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 0 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lai_risk_category' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 0 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lai_risk_category' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'ldl_target_lai', 'Risk and target', 'LDL-C target under LAI rule set', 'numeric', 'mg/dL', NULL::jsonb, 10, 200, 'calculated', 'calc.ldl_target', 'ref.ldl_target_rules (secondary rule set)', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 1 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_lai' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 1 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_lai' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 1 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_lai' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 1 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_lai' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 1 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_lai' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'ldl_target_met_lai', 'Outcomes', 'LDL-C target attained under LAI', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.ldl_target_met', 'secondary rule set', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 2 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_met_lai' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 2 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_met_lai' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 2 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_met_lai' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 2 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_met_lai' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 2 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_met_lai' AND d.definition_version = 1;
