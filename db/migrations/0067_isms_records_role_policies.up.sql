-- @run-as: admin
-- 0067: Restrict writes to the records tables by role in the DB as well (Codex review 2026-09-12 round 3; user decision "enforce it in the DB too").
--
-- Until now the design was that server actions call app.require_records_role(kind) and then write via app_rw (0063).
-- Calling the function is merely a caller-side convention; a forgotten call or another write path would let anyone in the tenant
-- (even auditors or members) write. As a prerequisite for offering this to other companies (design doc §6), the table side rejects too.
--
-- Targets are the new tables written only by the records screens (created in 0063-0066):
--   control_effectiveness (effectiveness), context_issues / interested_parties (context), legal_requirements (legal)
-- Existing tables (audits, findings, corrective actions, reviews, objectives, evidence, exceptions, vendor assessments) have other write
-- paths such as check execution and work assignment, so they are not restricted here (that would break those paths; roles are checked in server actions as before).
--
-- Shape:
--   - Per-kind permissions live in one place, app.records_role_allows(kind); require_records_role just calls it
--     (so the table policies and the function never disagree on the permission table). Future kinds only replace records_role_allows.
--   - Each table gets 3 RESTRICTIVE policies for INSERT / UPDATE / DELETE. Reads are not restricted (readable regardless of role).
--     RESTRICTIVE is ANDed with the existing tenant_isolation (PERMISSIVE), so the tenant boundary is unchanged.
--   - The condition takes the form (SELECT app.records_role_allows('<kind>')) (the role is not looked up again per row).
--   - Names, shape and target tables are fixed by check_rls.sql.

SET ROLE schema_owner;

CREATE FUNCTION app.records_role_allows(p_kind text) RETURNS boolean
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
  -- Deny when the actor is unknown (no session).
  IF app.current_session_user() IS NULL THEN
    RETURN false;
  END IF;
  v_role := app.current_management_role();
  -- NULL = ANY yields NULL (not false), so NULL is explicitly turned into false.
  RETURN v_role IS NOT NULL AND v_role = ANY (v_allowed);
END $$;
ALTER FUNCTION app.records_role_allows(text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.records_role_allows(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.records_role_allows(text) TO app_rw;

COMMENT ON FUNCTION app.records_role_allows(text) IS
  '記録の種類ごとに、今の本人の役割で書いてよいか。許可の表の唯一の置き場所（require_records_role と各表の records_role_* ポリシーが使う）。';

-- The role check function holds no permission table and just calls records_role_allows (behavior same as 0066).
CREATE OR REPLACE FUNCTION app.require_records_role(p_kind text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF app.current_session_user() IS NULL THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  -- Unknown kinds are rejected by records_role_allows with 'unknown record kind'.
  IF NOT app.records_role_allows(p_kind) THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN app.current_management_role();
END $$;

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('control_effectiveness', 'effectiveness'),
      ('context_issues',        'context'),
      ('interested_parties',    'context'),
      ('legal_requirements',    'legal')) AS v(tbl, kind)
  LOOP
    EXECUTE format('CREATE POLICY records_role_insert ON app.%I AS RESTRICTIVE FOR INSERT TO app_rw '
                   'WITH CHECK ((SELECT app.records_role_allows(%L)))', r.tbl, r.kind);
    EXECUTE format('CREATE POLICY records_role_update ON app.%I AS RESTRICTIVE FOR UPDATE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L))) WITH CHECK ((SELECT app.records_role_allows(%L)))',
                   r.tbl, r.kind, r.kind);
    EXECUTE format('CREATE POLICY records_role_delete ON app.%I AS RESTRICTIVE FOR DELETE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L)))', r.tbl, r.kind);
  END LOOP;
END $$;

RESET ROLE;
