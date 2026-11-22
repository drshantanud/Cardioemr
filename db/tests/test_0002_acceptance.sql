-- CardioEMR migration 0002: acceptance tests.  Runs after test_0001 on the same database.
\set ON_ERROR_STOP 1
\echo '--- 12. Migration 0002: D5 sacubitril/valsartan strengths'
SELECT t_ok((SELECT array_agg(reference_strength ORDER BY reference_strength) FROM ref.drug_products p
             JOIN ref.drugs d USING (drug_id) WHERE d.drug_code = 'SACUBITRIL_VALSARTAN') = ARRAY[25,50,100,200]::numeric[],
  'sacubitril/valsartan strengths 25, 50, 100, 200 mg (labelled total)');
SELECT t_ok((SELECT round(100.0 * 2 * 25 / target_daily_dose, 1) FROM ref.hf_target_doses t JOIN ref.drugs d USING (drug_id)
             WHERE d.drug_code = 'SACUBITRIL_VALSARTAN') = 12.5, '25 mg BD = 12.5% of the 400 mg/day target');

\echo '--- 13. Migration 0002: D8 ESC/EAS and LAI targets side by side'
SELECT t_ok((SELECT ldl_secondary_rule_set_id FROM registry.registry_protocols WHERE protocol_code = 'CEMR-LIPID')
            = (SELECT rule_set_id FROM ref.rule_sets WHERE rule_set_code = 'LAI_2020'), 'lipid protocol names LAI as secondary guideline');
SELECT t_ok((SELECT status = 'draft' OR approved_at IS NOT NULL FROM ref.rule_sets WHERE rule_set_code = 'LAI_2020'), 'LAI rule set is draft until verified (active only with an approval date)');

SET SESSION AUTHORIZATION cardioemr_api; SET ROLE r_clinician;
SELECT t_as('clinician','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-00000000c0a1');
INSERT INTO registry.lipid_target_attainment (assessment_id, rule_set_id, patient_id, centre_id, is_primary, risk_category,
  ldl_mg_dl, ldl_pct_reduction)
SELECT '17000000-0000-0000-0000-000000000001', rule_set_id, '10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1', rule_set_code = 'ESC_EAS_2019', 'very_high', 52, 60
FROM ref.rule_sets WHERE rule_set_code IN ('ESC_EAS_2019','LAI_2020');
SELECT t_ok((SELECT target_met FROM registry.lipid_target_attainment t JOIN ref.rule_sets USING (rule_set_id)
             WHERE rule_set_code = 'ESC_EAS_2019'), 'LDL-C 52 mg/dL, 60% fall: meets ESC/EAS very-high (< 55)');
SELECT t_ok(NOT (SELECT target_met FROM registry.lipid_target_attainment t JOIN ref.rule_sets USING (rule_set_id)
             WHERE rule_set_code = 'LAI_2020'), 'same patient misses LAI very-high (< 50)');
SELECT t_ok((SELECT ldl_target_mg_dl FROM registry.lipid_target_attainment t JOIN ref.rule_sets USING (rule_set_id)
             WHERE rule_set_code = 'LAI_2020') = 50, 'target filled from the rule table, not typed');
SELECT t_ok(registry.ldl_target_met((SELECT rule_set_id FROM ref.rule_sets WHERE rule_set_code = 'LAI_2020'),
  'extreme_b', 30, NULL), 'LAI extreme risk B: 30 mg/dL meets the <= 30 goal');
SELECT t_fails($$INSERT INTO registry.lipid_target_attainment (assessment_id, rule_set_id, patient_id, centre_id, is_primary,
  risk_category, ldl_mg_dl) SELECT '17000000-0000-0000-0000-000000000001', rule_set_id, '10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-00000000c0a1', false, 'extreme_b', 52 FROM ref.rule_sets WHERE rule_set_code = 'ACC_AHA_2018'$$,
  'risk category must exist in that guideline', '23');
SELECT t_as('clinician','00000000-0000-0000-0000-0000000000d3','00000000-0000-0000-0000-00000000c0b1');
SELECT t_ok((SELECT count(*) FROM registry.lipid_target_attainment) = 0, 'attainment rows isolated by centre');
RESET ROLE; RESET SESSION AUTHORIZATION;
SELECT t_ok((SELECT bool_and(ok) FROM audit.verify_chain('00000000-0000-0000-0000-00000000c0b1')),
  'audit chain for centre B still verifies');
