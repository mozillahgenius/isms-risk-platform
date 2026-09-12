-- 0034 app: versioning, approval and activation workflow for policy documents
--
-- The existing app.policies / app.policy_versions / app.approvals (0011) were
-- not used by the Web side at all, and the following were missing:
--   (1) no DB constraint that "only one version is currently effective"
--   (2) no mechanism preventing approved versions from being rewritten
--   (3) no path making approval and activation one consistent operation
--   (4) no path that actually uses app.approvals
--   (5) no user identification on the write path to record "who approved"
--       (app.set_tenant_context only puts the tenant ID in a GUC)
--
-- Unless (5) is filled first, approved_by / approver_user_id in (3)(4) are always NULL.

-- ============================================================
-- (5) Allow the session user's identity to be held in a signed GUC, like the tenant context
--     Same approach as app.tenant_context_signature (0006). The key table is reused too.
-- ============================================================

CREATE OR REPLACE FUNCTION app.session_context_signature(p_tenant uuid, p_user uuid) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE v_secret bytea; v_payload text;
BEGIN
  IF p_tenant IS NULL OR p_user IS NULL THEN
    RAISE EXCEPTION 'tenant or user is null' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT secret INTO STRICT v_secret FROM app.tenant_context_keys WHERE id = 1;
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'tenant context key is missing' USING ERRCODE = 'insufficient_privilege';
  END IF;
  v_payload := 'v1:' || p_tenant::text || ':' || p_user::text || ':' || pg_catalog.pg_backend_pid()::text;
  RETURN pg_catalog.encode(
           public.hmac(pg_catalog.convert_to(v_payload, 'UTF8'), v_secret, 'sha256'), 'hex');
END $$;
ALTER FUNCTION app.session_context_signature(uuid, uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.session_context_signature(uuid, uuid) FROM PUBLIC;

-- Replace set_tenant_context so it also sets the session-user GUCs in the same transaction.
-- Return value, arguments and existing validation logic are unchanged (backward compatible). The only
-- additions are the 2 GUCs app.session_user_id / app.session_user_sig.
CREATE OR REPLACE FUNCTION app.set_tenant_context(p_token text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE v_tenant uuid; v_user uuid;
BEGIN
  IF p_token IS NULL OR pg_catalog.length(p_token) < 32 THEN
    RAISE EXCEPTION 'invalid session' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT m.tenant_id, s.user_id INTO v_tenant, v_user
    FROM app.sessions s
    JOIN app.memberships m
      ON m.user_id = s.user_id AND m.tenant_id = s.tenant_id AND m.revoked_at IS NULL
    JOIN app.users u   ON u.tenant_id = s.tenant_id AND u.id = s.user_id
    JOIN app.tenants t ON t.id = s.tenant_id
   WHERE s.token_hash = public.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256')
     AND s.expires_at > pg_catalog.now()
     AND s.revoked_at IS NULL
     AND u.status = 'active'
     AND t.status = 'active'
   LIMIT 1;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'invalid session' USING ERRCODE = 'insufficient_privilege';
  END IF;
  PERFORM pg_catalog.set_config('app.tenant_id',  v_tenant::text, true);
  PERFORM pg_catalog.set_config('app.tenant_sig', app.tenant_context_signature(v_tenant), true);
  PERFORM pg_catalog.set_config('app.session_user_id',  v_user::text, true);
  PERFORM pg_catalog.set_config('app.session_user_sig', app.session_context_signature(v_tenant, v_user), true);
  RETURN v_tenant;
END $$;
ALTER FUNCTION app.set_tenant_context(text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.set_tenant_context(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.set_tenant_context(text) TO app_rw, app_ro;

-- Read function paired with current_tenant(). Applies the same validation (signature check).
CREATE OR REPLACE FUNCTION app.current_session_user() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE
  v_tenant uuid := app.current_tenant(); -- raises here if not set
  v_id  text := pg_catalog.current_setting('app.session_user_id',  true);
  v_sig text := pg_catalog.current_setting('app.session_user_sig', true);
  v_user uuid;
BEGIN
  IF v_id IS NULL OR v_id = '' THEN
    RAISE EXCEPTION 'session user context is not set' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_sig IS NULL OR pg_catalog.length(v_sig) <> 64 THEN
    RAISE EXCEPTION 'session user context is not signed' USING ERRCODE = 'insufficient_privilege';
  END IF;
  BEGIN
    v_user := v_id::uuid;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'session user context is malformed' USING ERRCODE = 'insufficient_privilege';
  END;
  IF v_sig <> app.session_context_signature(v_tenant, v_user) THEN
    RAISE EXCEPTION 'session user context signature mismatch' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_user;
END $$;
ALTER FUNCTION app.current_session_user() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.current_session_user() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.current_session_user() TO app_rw, app_ro;

-- ============================================================
-- (1) Only one currently effective version per (tenant_id, policy_id)
--     Same shape as risk_assessments_current on app.risk_assessments (0008).
-- ============================================================

CREATE UNIQUE INDEX policy_versions_current
  ON app.policy_versions (tenant_id, policy_id)
  WHERE effective_from IS NOT NULL AND superseded_at IS NULL;

-- ============================================================
-- (2) An approved version's body, version number and approval info cannot be rewritten
--     To change content, add a new version (a new row).
--     Updating effective_from / superseded_at (= activation / supersession) is allowed.
-- ============================================================

CREATE OR REPLACE FUNCTION app.protect_approved_policy_version() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF OLD.approved_at IS NOT NULL THEN
    IF NEW.body_md           IS DISTINCT FROM OLD.body_md
       OR NEW.version        IS DISTINCT FROM OLD.version
       OR NEW.policy_id      IS DISTINCT FROM OLD.policy_id
       OR NEW.diff_clause_count IS DISTINCT FROM OLD.diff_clause_count
       OR NEW.approved_at    IS DISTINCT FROM OLD.approved_at
       OR NEW.approved_by    IS DISTINCT FROM OLD.approved_by THEN
      RAISE EXCEPTION 'approved policy version is immutable; create a new version instead'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  END IF;
  -- The transition to approved from unapproved (OLD.approved_at IS NULL) cannot be detected by the
  -- block above (which only looks at already-approved rows). app_rw has ordinary UPDATE privilege
  -- on app.policy_versions, so without this guard one could bypass approve_policy_version() and,
  -- in the same transaction, rewrite body_md and forge approved_at/approved_by with a direct UPDATE
  -- (measured in the Codex review of 2026-09-02: a direct UPDATE was confirmed to go through).
  -- Require a session flag that is SET LOCAL only inside approve_policy_version().
  IF OLD.approved_at IS NULL AND NEW.approved_at IS NOT NULL THEN
    IF pg_catalog.current_setting('app.policy_approval_in_progress', true) IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'approval must go through app.approve_policy_version()'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_protect_approved_policy_version
  BEFORE UPDATE ON app.policy_versions
  FOR EACH ROW EXECUTE FUNCTION app.protect_approved_policy_version();

CREATE OR REPLACE FUNCTION app.protect_approved_policy_version_delete() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'approved policy version cannot be deleted'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER trg_protect_approved_policy_version_delete
  BEFORE DELETE ON app.policy_versions
  FOR EACH ROW EXECUTE FUNCTION app.protect_approved_policy_version_delete();

-- ============================================================
-- (3)(4) Functions that make approval and activation a single operation
--     Called from app_rw's ordinary connection (not SECURITY DEFINER).
--     Reuses the validation in app.current_tenant() / app.current_session_user() as-is.
-- ============================================================

CREATE OR REPLACE FUNCTION app.approve_policy_version(
  p_policy_version_id uuid, p_comment text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant uuid := app.current_tenant();
  v_user   uuid := app.current_session_user();
  v_body   text;
  v_already_approved timestamptz;
BEGIN
  SELECT body_md, approved_at INTO v_body, v_already_approved
    FROM app.policy_versions
   WHERE tenant_id = v_tenant AND id = p_policy_version_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'policy version not found';
  END IF;
  IF v_already_approved IS NOT NULL THEN
    RAISE EXCEPTION 'policy version is already approved';
  END IF;

  -- Session-local flag that lets trg_protect_approved_policy_version reject approval transitions
  -- (OLD.approved_at IS NULL → NEW.approved_at IS NOT NULL) from any other path.
  -- Equivalent to SET LOCAL, so it disappears at transaction end.
  PERFORM pg_catalog.set_config('app.policy_approval_in_progress', 'true', true);

  UPDATE app.policy_versions
     SET approved_by = v_user, approved_at = pg_catalog.now(), updated_at = pg_catalog.now(), updated_by = v_user
   WHERE tenant_id = v_tenant AND id = p_policy_version_id;

  INSERT INTO app.approvals
    (tenant_id, target_type, target_id, target_version_hash, approver_user_id, comment, created_by)
  VALUES
    (v_tenant, 'policy_version', p_policy_version_id,
     public.digest(pg_catalog.convert_to(v_body, 'UTF8'), 'sha256'), v_user, p_comment, v_user);
END $$;
ALTER FUNCTION app.approve_policy_version(uuid, text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.approve_policy_version(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.approve_policy_version(uuid, text) TO app_rw;

CREATE OR REPLACE FUNCTION app.activate_policy_version(
  p_policy_version_id uuid, p_effective_from date DEFAULT CURRENT_DATE
) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant    uuid := app.current_tenant();
  v_policy_id uuid;
  v_approved  timestamptz;
BEGIN
  SELECT policy_id, approved_at INTO v_policy_id, v_approved
    FROM app.policy_versions
   WHERE tenant_id = v_tenant AND id = p_policy_version_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'policy version not found';
  END IF;
  IF v_approved IS NULL THEN
    RAISE EXCEPTION 'policy version is not approved; approve before activating';
  END IF;

  -- Supersede the existing current version of the same policy (excluding the target itself).
  UPDATE app.policy_versions
     SET superseded_at = pg_catalog.now(), updated_at = pg_catalog.now()
   WHERE tenant_id = v_tenant AND policy_id = v_policy_id
     AND effective_from IS NOT NULL AND superseded_at IS NULL
     AND id <> p_policy_version_id;

  UPDATE app.policy_versions
     SET effective_from = p_effective_from, superseded_at = NULL, updated_at = pg_catalog.now()
   WHERE tenant_id = v_tenant AND id = p_policy_version_id;
END $$;
ALTER FUNCTION app.activate_policy_version(uuid, date) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.activate_policy_version(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.activate_policy_version(uuid, date) TO app_rw;
