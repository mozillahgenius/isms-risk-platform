-- @run-as: admin
-- Rollback of 0070. Removes the change request table, decision function and transition trigger, and restores the permission table to the 0069 version.
-- Approval records left in app.approvals are not deleted (audit records are never rewritten afterwards; same as 0063).
--
-- **Do not roll back when data exists** (same as 0055; A.8.32 records must not silently vanish on down).
-- The guard goes before SET ROLE, and takes a SHARE lock and counts only when the table exists (same as 0065's down).
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  -- Lock the approval records first. The decision function touches request (FOR UPDATE) -> approval record (INSERT) in that order, so
  -- going request -> approval record here would make the two wait on each other (Codex review 2026-09-12). Align the lock order.
  LOCK TABLE app.approvals IN SHARE MODE;
  IF to_regclass('app.change_requests') IS NOT NULL THEN
    LOCK TABLE app.change_requests IN SHARE MODE;
    SELECT count(*) INTO n FROM app.change_requests;
    IF n > 0 THEN
      RAISE EXCEPTION '0070 rollback refused: change requests would be lost (% rows)', n;
    END IF;
  END IF;
  -- Also do not roll back while approval records (change_request) remain. Rolling back and recreating would link old approvals to a request with the same ID.
  SELECT count(*) INTO n FROM app.approvals WHERE target_type = 'change_request';
  IF n > 0 THEN
    RAISE EXCEPTION '0070 rollback refused: change request approvals remain (% rows)', n;
  END IF;
END $$;

SET ROLE schema_owner;

DROP FUNCTION IF EXISTS app.decide_change_request(uuid, boolean, text);
-- Dropping the table also drops its policies, triggers and indexes.
DROP TABLE IF EXISTS app.change_requests;
DROP FUNCTION IF EXISTS app.change_requests_guard();

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
