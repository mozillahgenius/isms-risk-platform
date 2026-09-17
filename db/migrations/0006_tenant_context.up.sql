-- 0006 app: テナント文脈（設計書 9.2 の実装。ただし設計書の素の実装は
-- 受入 #7 を満たさないため署名検証を足している。逸脱の理由と
-- 「証明できる性質の範囲」は docs/DECISIONS.md D-01 / D-02）。
--
-- 依存: 0005 の app.sessions / app.memberships、0001 の pgcrypto。

-- ------------------------------------------------------------------
-- 署名鍵。schema_owner だけが触れる。app_rw / app_ro には一切与えない。
-- singleton（1 行しか置けない）にして SELECT ... INTO STRICT で読む。
-- ------------------------------------------------------------------
CREATE TABLE app.tenant_context_keys (
  id         smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  secret     bytea NOT NULL CHECK (octet_length(secret) >= 32),
  rotated_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON TABLE app.tenant_context_keys FROM PUBLIC;
REVOKE ALL ON TABLE app.tenant_context_keys FROM app_rw, app_ro, auditlogd, audit_verifier;

INSERT INTO app.tenant_context_keys (id, secret) VALUES (1, gen_random_bytes(32));

-- ------------------------------------------------------------------
-- 署名の材料。区切りと版を明示して曖昧さを消す（連結の解釈揺れを防ぐ）。
-- pg_stat_activity は使わない（SECURITY DEFINER 内で所有者から他ロールの
-- セッション行が見えず backend_start が NULL になり得るため）。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.tenant_context_signature(p_tenant uuid) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE v_secret bytea; v_payload text;
BEGIN
  IF p_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant is null' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT secret INTO STRICT v_secret FROM app.tenant_context_keys WHERE id = 1;
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'tenant context key is missing' USING ERRCODE = 'insufficient_privilege';
  END IF;
  v_payload := 'v1:' || p_tenant::text || ':' || pg_catalog.pg_backend_pid()::text;
  RETURN pg_catalog.encode(
           public.hmac(pg_catalog.convert_to(v_payload, 'UTF8'), v_secret, 'sha256'), 'hex');
END $$;
ALTER FUNCTION app.tenant_context_signature(uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.tenant_context_signature(uuid) FROM PUBLIC;
-- 呼び出せるのは下の 2 関数だけ。アプリロールには EXECUTE を与えない
-- （与えると任意テナントの署名を作れてしまう）。

-- ------------------------------------------------------------------
-- 文脈の設定。引数は「呼出者が保持する秘密」＝セッショントークンそのもの。
-- DB にはハッシュしか無いので、トークンを知らない者は文脈を作れない。
-- set_config(..., true) = SET LOCAL 相当。トランザクション終了で消える
-- （接続プールへ返した後に文脈が残らない＝受入 #8）。
-- 呼び方は BEGIN → set_tenant_context → 業務クエリ → COMMIT。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.set_tenant_context(p_token text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE v_tenant uuid;
BEGIN
  IF p_token IS NULL OR pg_catalog.length(p_token) < 32 THEN
    RAISE EXCEPTION 'invalid session' USING ERRCODE = 'insufficient_privilege';
  END IF;
  -- 発行後に停止された利用者・テナントのセッションを生かしたままにしない。
  -- 期限切れと失効だけを見ていると、退職処理やテナント閉鎖をしても
  -- 手持ちのトークンでアクセスが続く。
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

-- ------------------------------------------------------------------
-- 文脈の参照。GUC を素通しで信じず、署名を再計算して照合する。
-- 直接 SET app.tenant_id した接続は署名を作れないので、ここで落ちる。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.current_tenant() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE
  v_id  text := pg_catalog.current_setting('app.tenant_id',  true);
  v_sig text := pg_catalog.current_setting('app.tenant_sig', true);
  v_tenant uuid;
BEGIN
  IF v_id IS NULL OR v_id = '' THEN
    RAISE EXCEPTION 'tenant context is not set' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_sig IS NULL OR pg_catalog.length(v_sig) <> 64 THEN
    RAISE EXCEPTION 'tenant context is not signed' USING ERRCODE = 'insufficient_privilege';
  END IF;
  BEGIN
    v_tenant := v_id::uuid;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'tenant context is malformed' USING ERRCODE = 'insufficient_privilege';
  END;
  IF v_sig <> app.tenant_context_signature(v_tenant) THEN
    RAISE EXCEPTION 'tenant context signature mismatch' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_tenant;
END $$;
ALTER FUNCTION app.current_tenant() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.current_tenant() FROM PUBLIC;
-- app_ro も RLS ポリシー式の評価で呼ぶので EXECUTE が要る。
GRANT EXECUTE ON FUNCTION app.current_tenant() TO app_rw, app_ro;

-- ------------------------------------------------------------------
-- セッション発行。トークンは呼出側が CSPRNG で作って渡し、DB にはハッシュだけが残る。
--
-- **実行権限は auth_svc だけに与える。app_rw には与えない。**
-- app_rw がこれを呼べると、任意テナントの uuid を指定してセッションを発行し、
-- そのトークンで set_tenant_context() を通せてしまう。署名検証も
-- トークンのハッシュ照合も、発行そのものが自由なら意味を成さない。
-- 認証経路（ログイン処理）だけが auth_svc で接続する。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.create_session(
  p_tenant uuid, p_user uuid, p_token text, p_ttl interval DEFAULT interval '12 hours')
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE v_id uuid;
BEGIN
  -- 32 文字未満は最低エントロピー不足として拒否（推奨は 32 バイト CSPRNG の hex = 64 文字）
  IF p_token IS NULL OR pg_catalog.length(p_token) < 32 THEN
    RAISE EXCEPTION 'session token is too short';
  END IF;
  IF p_ttl IS NULL OR p_ttl <= interval '0' OR p_ttl > interval '24 hours' THEN
    RAISE EXCEPTION 'session ttl must be within 24 hours';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app.memberships m
                   JOIN app.users u   ON u.tenant_id = m.tenant_id AND u.id = m.user_id
                   JOIN app.tenants t ON t.id = m.tenant_id
                  WHERE m.tenant_id = p_tenant AND m.user_id = p_user
                    AND m.revoked_at IS NULL
                    AND u.status = 'active' AND t.status = 'active') THEN
    RAISE EXCEPTION 'user has no active membership in an active tenant';
  END IF;
  INSERT INTO app.sessions (tenant_id, user_id, token_hash, expires_at)
  VALUES (p_tenant, p_user,
          public.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256'),
          pg_catalog.now() + p_ttl)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
ALTER FUNCTION app.create_session(uuid, uuid, text, interval) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.create_session(uuid, uuid, text, interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.create_session(uuid, uuid, text, interval) TO auth_svc;

-- 失効。ローテーションは「新しいトークンで create_session → 旧を revoke」で行う。
CREATE OR REPLACE FUNCTION app.revoke_session(p_token text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE v_n int;
BEGIN
  UPDATE app.sessions SET revoked_at = pg_catalog.now()
   WHERE token_hash = public.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256')
     AND revoked_at IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $$;
ALTER FUNCTION app.revoke_session(text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.revoke_session(text) FROM PUBLIC;
-- 失効はトークンを知っている者にしかできない（自分のセッションを切るのは正当）。
GRANT EXECUTE ON FUNCTION app.revoke_session(text) TO auth_svc, app_rw;

-- auth_svc は文脈確立や業務データへは触らせない。セッション発行だけの役。
GRANT USAGE ON SCHEMA app TO auth_svc;
