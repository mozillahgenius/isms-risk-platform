-- @run-as: admin
-- 0056: Function that records approval of the ISMS scope (4.3).
--
-- Only the scope had no approval path; the only option was a direct INSERT into app.approvals.
-- A direct INSERT means the DB does not check "who may approve", so align it with policy approval
-- (app.approve_policy_version in 0034).
--
-- Three points are aligned:
--   1. Only the executive (ciso) can approve
--   2. The hash of the body at approval time is bound to the approval record
--      (even if the body is edited later, "what was approved" remains)
--   3. The same body cannot be approved twice
--      (if the body has changed, it can be approved again)

SET ROLE schema_owner;

CREATE FUNCTION app.approve_iso_scope(p_comment text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant uuid := app.current_tenant();
  v_user   uuid := app.current_session_user();
  v_scope  text;
  v_hash   bytea;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM app.memberships m
      JOIN app.users u ON u.tenant_id = m.tenant_id AND u.id = m.user_id
     WHERE m.tenant_id = v_tenant AND m.user_id = v_user AND m.role_key = 'ciso'
       AND m.revoked_at IS NULL AND u.status = 'active'
  ) THEN
    RAISE EXCEPTION 'executive role required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- **Do not add FOR UPDATE.** Row locks also require an UPDATE policy, but
  -- schema_owner has only SELECT (ctx_tenant_lookup) and INSERT
  -- policies on app.tenants. With it, no row is visible and the body is misjudged as empty (measured).
  -- Records stay consistent even without a lock. The hash is taken from **the body just read**, so
  -- the approval record always points to "the body at approval time".
  SELECT iso_scope_statement INTO v_scope
    FROM app.tenants WHERE id = v_tenant;
  IF v_scope IS NULL OR length(btrim(v_scope)) = 0 THEN
    RAISE EXCEPTION 'iso scope statement is empty';
  END IF;

  v_hash := public.digest(pg_catalog.convert_to(v_scope, 'UTF8'), 'sha256');

  -- **Do not approve the same body twice.** If the body has changed, allow it
  -- (re-approving on every revision is how 4.3 is operated).
  IF EXISTS (
    SELECT 1 FROM app.approvals
     WHERE tenant_id = v_tenant AND target_type = 'iso_scope'
       AND target_id = v_tenant AND target_version_hash = v_hash
  ) THEN
    RAISE EXCEPTION 'this iso scope statement is already approved';
  END IF;

  INSERT INTO app.approvals
    (tenant_id, target_type, target_id, target_version_hash,
     approver_user_id, comment, created_by)
  VALUES (v_tenant, 'iso_scope', v_tenant, v_hash, v_user, p_comment, v_user);
END $$;
ALTER FUNCTION app.approve_iso_scope(text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.approve_iso_scope(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.approve_iso_scope(text) TO app_rw;

COMMENT ON FUNCTION app.approve_iso_scope(text) IS
  'ISMS 適用範囲（4.3）の承認。ciso のみ実行でき、承認時の本文のハッシュを app.approvals へ結ぶ。同じ本文の二重承認は拒否する。';

RESET ROLE;
