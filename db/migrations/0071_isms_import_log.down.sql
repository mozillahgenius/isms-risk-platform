-- @run-as: admin
-- Rollback of 0071. Remove the import-record tables and triggers, and restore the permission table to 0070's version.
-- Assets and risks created by imports are not deleted (they are register rows, not import records).
--
-- **Don't roll back while records exist** (same as 0055; don't silently delete import audit records in down).
-- The guard is placed before SET ROLE, and for each table takes a SHARE lock and counts only if it exists (same as 0065's down).
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE
  n integer;
  t text;
BEGIN
  -- Lock starting from the parent (import_batches). The import side INSERTs the parent and then the details, so
  -- locking from the child would deadlock (Codex review 2026-09-12). Keep the lock order consistent.
  FOREACH t IN ARRAY ARRAY['import_batches','import_batch_items','import_undos'] LOOP
    IF to_regclass('app.' || t) IS NOT NULL THEN
      EXECUTE format('LOCK TABLE app.%I IN SHARE MODE', t);
      EXECUTE format('SELECT count(*) FROM app.%I', t) INTO n;
      IF n > 0 THEN
        RAISE EXCEPTION '0071 rollback refused: import records would be lost (% rows in %)', n, t;
      END IF;
    END IF;
  END LOOP;
END $$;

SET ROLE schema_owner;

-- Dropping the tables also drops the attached policies, triggers, and indexes.
DROP TABLE IF EXISTS app.import_undos;
DROP TABLE IF EXISTS app.import_batch_items;
DROP TABLE IF EXISTS app.import_batches;
DROP FUNCTION IF EXISTS app.import_items_guard();
DROP FUNCTION IF EXISTS app.import_log_stamp();

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
    WHEN 'vulnerability'     THEN ARRAY['owner','admin','manager']
    WHEN 'change'            THEN ARRAY['owner','admin','manager','member']
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
