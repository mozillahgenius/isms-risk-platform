-- @run-as: admin
-- Rollback of 0068. Removes the business continuity plan/test tables and restores the permission table to 0067's version.
--
-- **Does not roll back when data exists** (same as 0055; A.5.29 / 5.30 records are not silently deleted by down).
-- The guard sits before SET ROLE and, per table, takes a SHARE lock and counts only if the table exists (same as 0065's down).
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  IF to_regclass('app.continuity_tests') IS NOT NULL THEN
    LOCK TABLE app.continuity_tests IN SHARE MODE;
    SELECT count(*) INTO n FROM app.continuity_tests;
    IF n > 0 THEN
      RAISE EXCEPTION '0068 rollback refused: continuity tests would be lost (% rows)', n;
    END IF;
  END IF;
  IF to_regclass('app.continuity_plans') IS NOT NULL THEN
    LOCK TABLE app.continuity_plans IN SHARE MODE;
    SELECT count(*) INTO n FROM app.continuity_plans;
    IF n > 0 THEN
      RAISE EXCEPTION '0068 rollback refused: continuity plans would be lost (% rows)', n;
    END IF;
  END IF;
END $$;

SET ROLE schema_owner;

-- Dropping the tables also drops the role policies attached to them.
DROP TABLE IF EXISTS app.continuity_tests;
DROP TABLE IF EXISTS app.continuity_plans;

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
