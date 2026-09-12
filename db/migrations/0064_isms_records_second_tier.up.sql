-- @run-as: admin
-- 0064: Second tier of ISMS operational records (design doc 2026-09-11 §5.3, item 2: information security objectives, vendor assessments, evidence, exceptions).
--
-- All tables already exist (0010 / 0011 / 0055). All that is added is the kinds that roles may write:
--   objective  registering information security objectives (6.2) and evaluating achievement : owner / admin
--   evidence   registering manual evidence                                                : owner / admin / manager
--              (these are records of control operation, so auditors, who don't write business data, can't write them)
--   exception  approving exceptions to findings (accepting as risk instead of correcting): owner only (an executive decision)
-- Vendor assessments use the existing app.require_work_permission('vendor_assessment', …) (aligned with work assignment).
-- Don't rewrite 0063; only replace the function (down restores 0063's version).

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
  -- Also reject when the role is NULL (same as 0063; NULL = ANY yields NULL, so the IF would slip through).
  IF v_role IS NULL OR NOT (v_role = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_role;
END $$;

RESET ROLE;
