-- =====================================================================
-- CardioEMR  migration 0007_web_app_support   (2026-11-23)
-- What the web app needs before a centre is chosen:
--   1. app.subject_memberships: after sign-in, the centres and roles the
--      token's user holds, so the app can offer a centre and role picker.
--      Every other request still names one centre and one role, and RLS
--      limits it to that centre as before.  No patient data is read.
--   2. Generated local patient codes skip codes already in use (codes typed
--      by hand or imported from an older system no longer collide with the
--      counter), and a clash on a typed code is a 409.
-- =====================================================================
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION app.subject_memberships(p_provider text, p_subject text)
RETURNS TABLE (user_id uuid, full_name text, email text, platform_role text,
               centre_id uuid, centre_name text, centre_code text, centre_timezone text,
               organisation_id uuid, organisation_name text, role text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, iam AS $$
  SELECT u.user_id, u.full_name, u.email::text, u.platform_role,
         c.centre_id, c.centre_name, c.centre_code, c.timezone,
         o.organisation_id, o.organisation_name, r.role
    FROM iam.users u
    LEFT JOIN iam.user_centre_roles r
           ON r.user_id = u.user_id AND r.status = 'active'
          AND current_date >= r.valid_from AND (r.valid_to IS NULL OR current_date <= r.valid_to)
    LEFT JOIN iam.centres c ON c.centre_id = r.centre_id AND c.status = 'active'
    LEFT JOIN iam.organisations o ON o.organisation_id = c.organisation_id AND o.status = 'active'
   WHERE u.auth_provider = p_provider AND u.auth_subject = p_subject AND u.status = 'active'
     AND (r.user_id IS NULL OR o.organisation_id IS NOT NULL)
   ORDER BY o.organisation_name, c.centre_name, r.role
$$;
REVOKE EXECUTE ON FUNCTION app.subject_memberships(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.subject_memberships(text, text) TO r_assistant, r_nurse, r_clinician,
  r_research_coordinator, r_principal_investigator, r_centre_admin, r_platform_admin, r_audit_reader;

CREATE OR REPLACE FUNCTION clinical._next_local_patient_code(v_centre uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, clinical, iam AS $$
DECLARE v_n bigint; v_prefix text; v_code text;
BEGIN
  IF NOT app._centre_arg_ok(v_centre) THEN RAISE EXCEPTION 'no active centre' USING ERRCODE = 'insufficient_privilege'; END IF;
  SELECT centre_code INTO v_prefix FROM iam.centres WHERE centre_id = v_centre;
  LOOP
    INSERT INTO clinical.centre_code_counters (centre_id, last_value) VALUES (v_centre, 1)
    ON CONFLICT (centre_id) DO UPDATE SET last_value = centre_code_counters.last_value + 1
    RETURNING last_value INTO v_n;
    v_code := v_prefix || '-' || lpad(v_n::text, 6, '0');
    EXIT WHEN NOT EXISTS (SELECT 1 FROM clinical.patient_registrations
                           WHERE centre_id = v_centre AND local_patient_code = v_code);
  END LOOP;
  RETURN v_code;
END $$;

INSERT INTO ref.api_error_map (source_kind, source_name, error_code, http_status, title) VALUES
 ('constraint','patient_registrations_centre_id_local_patient_code_key','CONFLICT',409,
  'This local patient code is already in use at this centre')
ON CONFLICT DO NOTHING;
