-- @run-as: admin
-- Rollback of 0067. Removes the role policies on the records tables, restores require_records_role to the 0066 version (which holds its own permission table),
-- and drops records_role_allows. Only policies and functions are affected, so no record data is lost (no data protection needed).

SET ROLE schema_owner;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['control_effectiveness','context_issues','interested_parties','legal_requirements'] LOOP
    IF to_regclass('app.' || t) IS NOT NULL THEN
      EXECUTE format('DROP POLICY IF EXISTS records_role_insert ON app.%I', t);
      EXECUTE format('DROP POLICY IF EXISTS records_role_update ON app.%I', t);
      EXECUTE format('DROP POLICY IF EXISTS records_role_delete ON app.%I', t);
    END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION app.require_records_role(p_kind text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text := app.current_management_role();
  v_allowed text[];
BEGIN
  IF app.current_session_user() IS NULL THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  v_allowed := CASE p_kind
    WHEN 'audit'             THEN ARRAY['owner','admin','auditor']
    WHEN 'corrective'        THEN ARRAY['owner','admin','manager']
    WHEN 'effectiveness'     THEN ARRAY['owner','admin']
    WHEN 'management_review' THEN ARRAY['owner','admin']
    WHEN 'objective'         THEN ARRAY['owner','admin']
    WHEN 'evidence'          THEN ARRAY['owner','admin','manager']
    WHEN 'exception'         THEN ARRAY['owner']
    WHEN 'context'           THEN ARRAY['owner','admin']
    WHEN 'legal'             THEN ARRAY['owner','admin','manager']
  END;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'unknown record kind: %', p_kind;
  END IF;
  IF v_role IS NULL OR NOT (v_role = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_role;
END $$;

DROP FUNCTION IF EXISTS app.records_role_allows(text);

RESET ROLE;
