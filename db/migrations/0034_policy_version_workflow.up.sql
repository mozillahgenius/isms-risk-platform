-- 0034 app: 規程文書（policy）の版管理・承認・有効化ワークフロー
--
-- 既存の app.policies / app.policy_versions / app.approvals（0011）は
-- Web 側から一切使われておらず、以下が欠けていた。
--   (1) 「現在有効な版は1つだけ」という制約が DB に無い
--   (2) 承認済みの版が書き換えられることを防ぐ仕組みが無い
--   (3) 承認・有効化を1つの整合した操作にする経路が無い
--   (4) app.approvals を実際に使う経路が無い
--   (5) 「誰が承認したか」を残すための利用者識別が書き込み経路に無い
--       （app.set_tenant_context はテナントIDしか GUC に置いていない）
--
-- (5) を先に埋めないと (3)(4) の approved_by / approver_user_id が常に NULL になる。

-- ============================================================
-- (5) セッション利用者の識別を、テナント文脈と同じ署名つき GUC で持てるようにする
--     app.tenant_context_signature と同じ作法（0006）。鍵テーブルも使い回す。
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

-- set_tenant_context を置き換え、同じトランザクションでセッション利用者の GUC も張る。
-- 返り値・引数・既存の検証ロジックは変えない（後方互換）。追加するのは
-- app.session_user_id / app.session_user_sig の2 GUC だけ。
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

-- current_tenant() と対になる読み取り関数。同じ検証（署名照合）を課す。
CREATE OR REPLACE FUNCTION app.current_session_user() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE
  v_tenant uuid := app.current_tenant(); -- 未設定ならここで例外
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
-- (1) 現在有効な版は (tenant_id, policy_id) につき 1 つだけ
--     app.risk_assessments の risk_assessments_current（0008）と同じ形。
-- ============================================================

CREATE UNIQUE INDEX policy_versions_current
  ON app.policy_versions (tenant_id, policy_id)
  WHERE effective_from IS NOT NULL AND superseded_at IS NULL;

-- ============================================================
-- (2) 承認済みの版は本文・版番号・承認情報を書き換えられない
--     内容を変えたいときは新しい版（新しい行）を追加する。
--     effective_from / superseded_at の更新（＝有効化・失効）は許す。
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
  -- 未承認(OLD.approved_at IS NULL)からの承認遷移は、上のブロック(既に承認済みの
  -- 行しか見ていない)では検知できない。app_rw は app.policy_versions への通常の
  -- UPDATE権限を持つため、このガードが無いと approve_policy_version() を経由せず、
  -- 直接UPDATEでbody_mdの書き換えと approved_at/approved_by の詐称を同一トランザク
  -- ションで行えてしまう(Codexレビュー2026-09-02で実測: 直接UPDATEが通ることを確認)。
  -- approve_policy_version() 内でのみ SET LOCAL するセッションフラグを要求する。
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
-- (3)(4) 承認・有効化を1操作にまとめる関数
--     app_rw の通常接続から呼ぶ（SECURITY DEFINER にしない）。
--     app.current_tenant() / app.current_session_user() の検証をそのまま使う。
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

  -- trg_protect_approved_policy_version が、この経路以外からの承認遷移
  -- (OLD.approved_at IS NULL → NEW.approved_at IS NOT NULL)を拒否するための
  -- セッションローカルフラグ。SET LOCAL 相当なのでトランザクション終了で消える。
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

  -- 同一規程の既存の現行版を失効させる（対象自身は除く）。
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
