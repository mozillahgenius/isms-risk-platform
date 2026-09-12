-- @run-as: admin
-- Rollback of 0065. Removes the organizational issues and interested parties tables and restores the role kinds to the 0064 version.
--
-- **Do not roll back when data exists** (same as 0055; 4.1 / 4.2 decisions must not silently vanish on down).
-- The guard goes before SET ROLE and takes a SHARE lock before counting (see 0055's down for why).
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  -- For each table, lock and count only if it exists (so DROP ... IF EXISTS is still reached if one is missing or partially rolled back).
  IF to_regclass('app.context_issues') IS NOT NULL THEN
    LOCK TABLE app.context_issues IN SHARE MODE;
    SELECT count(*) INTO n FROM app.context_issues;
    IF n > 0 THEN
      RAISE EXCEPTION '0065 rollback refused: context issues would be lost (% rows)', n;
    END IF;
  END IF;
  IF to_regclass('app.interested_parties') IS NOT NULL THEN
    LOCK TABLE app.interested_parties IN SHARE MODE;
    SELECT count(*) INTO n FROM app.interested_parties;
    IF n > 0 THEN
      RAISE EXCEPTION '0065 rollback refused: interested parties would be lost (% rows)', n;
    END IF;
  END IF;
END $$;

SET ROLE schema_owner;

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
  END;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'unknown record kind: %', p_kind;
  END IF;
  IF v_role IS NULL OR NOT (v_role = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_role;
END $$;

DROP TABLE IF EXISTS app.interested_parties;
DROP TABLE IF EXISTS app.context_issues;

RESET ROLE;
