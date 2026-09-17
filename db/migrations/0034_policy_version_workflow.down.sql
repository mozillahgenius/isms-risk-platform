-- 0034 down: 規程文書の版管理・承認・有効化ワークフローを取り除く

DROP FUNCTION IF EXISTS app.activate_policy_version(uuid, date);
DROP FUNCTION IF EXISTS app.approve_policy_version(uuid, text);

DROP TRIGGER IF EXISTS trg_protect_approved_policy_version_delete ON app.policy_versions;
DROP FUNCTION IF EXISTS app.protect_approved_policy_version_delete();

DROP TRIGGER IF EXISTS trg_protect_approved_policy_version ON app.policy_versions;
DROP FUNCTION IF EXISTS app.protect_approved_policy_version();

DROP INDEX IF EXISTS app.policy_versions_current;

DROP FUNCTION IF EXISTS app.current_session_user();

-- set_tenant_context を 0006 の元の定義へ戻す（セッション利用者 GUC を張らない版）。
CREATE OR REPLACE FUNCTION app.set_tenant_context(p_token text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE v_tenant uuid;
BEGIN
  IF p_token IS NULL OR pg_catalog.length(p_token) < 32 THEN
    RAISE EXCEPTION 'invalid session' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT m.tenant_id INTO v_tenant
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
  RETURN v_tenant;
END $$;
ALTER FUNCTION app.set_tenant_context(text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.set_tenant_context(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.set_tenant_context(text) TO app_rw, app_ro;

DROP FUNCTION IF EXISTS app.session_context_signature(uuid, uuid);
