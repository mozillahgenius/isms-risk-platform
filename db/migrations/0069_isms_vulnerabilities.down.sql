-- @run-as: admin
-- Rollback of 0069. Removes the vulnerabilities table and reverts the permission table to 0068's version.
--
-- **Do not roll back when data exists** (same as 0055; do not silently delete A.8.8 records in down).
-- The guard is placed before SET ROLE, and takes a SHARE lock and counts only when the table exists (same as 0065's down).
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  IF to_regclass('app.vulnerabilities') IS NOT NULL THEN
    LOCK TABLE app.vulnerabilities IN SHARE MODE;
    SELECT count(*) INTO n FROM app.vulnerabilities;
    IF n > 0 THEN
      RAISE EXCEPTION '0069 rollback refused: vulnerabilities would be lost (% rows)', n;
    END IF;
  END IF;
END $$;

SET ROLE schema_owner;

-- Dropping the table also drops its role policies and indexes.
DROP TABLE IF EXISTS app.vulnerabilities;

CREATE OR REPLACE FUNCTION app.records_role_allows(p_kind text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text;
  v_allowed text[];
BEGIN
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
    WHEN 'continuity'        THEN ARRAY['owner','admin','manager']
  END;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'unknown record kind: %', p_kind;
  END IF;
  IF app.current_session_user() IS NULL THEN
    RETURN false;
  END IF;
  v_role := app.current_management_role();
  RETURN v_role IS NOT NULL AND v_role = ANY (v_allowed);
END $$;

RESET ROLE;
