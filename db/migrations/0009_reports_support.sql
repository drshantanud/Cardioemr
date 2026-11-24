-- =====================================================================
-- CardioEMR  migration 0009_reports_support   (2026-11-24)
-- Nurses book registry follow-up visits (GET /protocols/{id}/follow-up-due)
-- but have no grant on registry protocols, so the app could not list which
-- protocols to report on.  This narrow definer function returns only the
-- protocols with an active site at the caller's centre, and only their
-- names: no criteria, rules or data dictionary.
-- =====================================================================
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION registry.centre_protocols()
RETURNS TABLE (registry_code text, registry_name text, protocol_id uuid, protocol_code text, protocol_version text,
               status text, site_status text)
LANGUAGE sql STABLE AS $$ SELECT * FROM registry._centre_protocols(app.visible_centre()) $$;

CREATE OR REPLACE FUNCTION registry._centre_protocols(p_centre uuid)
RETURNS TABLE (registry_code text, registry_name text, protocol_id uuid, protocol_code text, protocol_version text,
               status text, site_status text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, registry AS $$
BEGIN
  IF NOT app._centre_arg_ok(p_centre) THEN
    RAISE EXCEPTION 'no active centre' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY
    SELECT rt.registry_code, rt.registry_name, p.protocol_id, p.protocol_code, p.protocol_version::text, p.status,
           ps.site_status
      FROM registry.registry_protocols p
      JOIN registry.registry_types rt USING (registry_type_id)
      JOIN registry.protocol_sites ps ON ps.protocol_id = p.protocol_id AND ps.centre_id = p_centre
     WHERE rt.status = 'active' AND p.status = 'active' AND ps.site_status = 'active'
     ORDER BY rt.registry_code, p.protocol_code, p.protocol_version;
END $$;

REVOKE EXECUTE ON FUNCTION registry.centre_protocols(), registry._centre_protocols(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION registry.centre_protocols(), registry._centre_protocols(uuid) TO r_nurse;
