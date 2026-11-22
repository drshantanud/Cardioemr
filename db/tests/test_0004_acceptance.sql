-- CardioEMR migration 0004: acceptance tests.  Runs after test_0003.
\set ON_ERROR_STOP 1
\echo '--- 17. Migration 0004: LAI targets verified'
SELECT t_ok((SELECT status = 'active' AND approved_at IS NOT NULL FROM ref.rule_sets WHERE rule_set_code = 'LAI_2020'),
  'LAI 2020 rule set active and approved');
SELECT t_ok((SELECT count(*) FROM ref.ldl_target_rules t JOIN ref.rule_sets rs USING (rule_set_id)
             WHERE rs.rule_set_code = 'LAI_2020') = 6, 'LAI targets unchanged: six risk categories');
SELECT t_ok((SELECT bool_and(status = 'draft') FROM ref.rule_sets WHERE rule_set_code <> 'LAI_2020'),
  'other rule sets remain draft until verified');
