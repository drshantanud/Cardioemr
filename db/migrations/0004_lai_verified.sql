-- =====================================================================
-- CardioEMR  migration 0004_lai_verified   (2026-11-22)
-- The clinical lead (product owner) verified the LAI 2020 LDL-C goals
-- seeded in 0002 against his LAI source on 2026-11-22, values unchanged.
-- The LAI rule set becomes active.  The other rule sets stay draft.
-- =====================================================================
UPDATE ref.rule_sets
   SET status = 'active', approved_at = '2026-11-22 18:39:00+05:30',
       source_citation = 'LAI expert consensus 2020; values verified by the clinical lead 2026-11-22'
 WHERE rule_set_code = 'LAI_2020' AND version = 1 AND status = 'draft';
