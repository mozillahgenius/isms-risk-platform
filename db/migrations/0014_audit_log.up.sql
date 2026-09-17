-- 0014 audit: 操作監査ログ（設計書 8.3）
-- chain_seq は追記サービス（auditlogd）が単一直列点で採番する。
-- DB のシーケンスは使わない（ロールバック・並行実行で欠番・逆転が起きるため）。

CREATE TABLE audit.audit_log (
  chain_seq      bigint      NOT NULL,
  tenant_id      uuid        NOT NULL,
  occurred_at    timestamptz NOT NULL,   -- 業務上の発生時刻
  appended_at    timestamptz NOT NULL,   -- 採番・署名した時刻
  actor_id       uuid, actor_type text
                   CHECK (actor_type IN ('user','agent','connector','system','platform_admin')),
  action         text NOT NULL,
  target_type    text, target_id uuid,
  changed_fields jsonb,                  -- 項目許可リストを通した差分のみ
  reason         text,
  source_ip      inet, user_agent text, session_id uuid,
  prev_hash      bytea,
  hash           bytea NOT NULL,
  signature      bytea NOT NULL,
  PRIMARY KEY (chain_seq)                -- 欠番・重複を構造的に排除
);

ALTER TABLE audit.audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit.audit_log FORCE ROW LEVEL SECURITY;

-- auditlogd に直接 INSERT を与えない。与えると audit.append() を迂回して
-- 任意の chain_seq・prev_hash・hash を書き込め、チェーン検証を通る偽の行を作れる。
-- 追記は必ず audit.append()（SECURITY DEFINER）経由にする。
REVOKE ALL ON audit.audit_log FROM auditlogd, app_rw, app_ro, PUBLIC;

GRANT SELECT ON audit.audit_log TO app_rw, app_ro;
CREATE POLICY audit_read ON audit.audit_log FOR SELECT TO app_rw, app_ro
  USING (tenant_id = app.current_tenant());

GRANT SELECT ON audit.audit_log TO audit_verifier;
CREATE POLICY audit_verify ON audit.audit_log FOR SELECT TO audit_verifier USING (true);
GRANT EXECUTE ON FUNCTION app.current_tenant() TO auditlogd;

-- 追記ヘルパ（下の audit.append）は SECURITY DEFINER なので、実際に INSERT する
-- のは所有者 schema_owner になる。FORCE RLS は所有者にも効くため、明示的に
-- ポリシーを張らないと追記できない。
-- INSERT と SELECT だけを許し、UPDATE / DELETE のポリシーは作らない。
-- ＝所有者であっても RLS の段階で過去行を書き換えられない（設計書 8.3 不変条件 6 を
--   REVOKE より強く担保する）。
CREATE POLICY audit_definer_insert ON audit.audit_log FOR INSERT TO schema_owner
  WITH CHECK (true);
CREATE POLICY audit_definer_read   ON audit.audit_log FOR SELECT TO schema_owner
  USING (true);

-- ------------------------------------------------------------------
-- ハッシュチェーンの検証（受入 #5）。設計書 8.3 の不変条件 4 を実装する。
-- 1 行でも改ざんされていれば false を返す。
-- hash = sha256(prev_hash || chain_seq || tenant_id || occurred_at || action
--                || coalesce(target_type,'') || coalesce(target_id,'') || changed_fields)
-- 署名（signature）は auditlogd が別鍵で付けるため、ここでは検証しない
-- （検証は独立プロセス side の責務。設計書 8.3 不変条件 4）。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.chain_payload(r audit.audit_log) RETURNS bytea
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT convert_to(
    coalesce(encode(r.prev_hash, 'hex'), '') || '|' ||
    r.chain_seq::text                        || '|' ||
    r.tenant_id::text                        || '|' ||
    to_char(r.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|' ||
    r.action                                 || '|' ||
    coalesce(r.target_type, '')              || '|' ||
    coalesce(r.target_id::text, '')          || '|' ||
    coalesce(r.changed_fields::text, ''), 'UTF8')
$$;
ALTER FUNCTION audit.chain_payload(audit.audit_log) OWNER TO schema_owner;

CREATE OR REPLACE FUNCTION audit.verify_chain()
RETURNS TABLE (ok boolean, checked bigint, first_bad_seq bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE r audit.audit_log; v_prev bytea := NULL; v_n bigint := 0; v_bad bigint := NULL;
BEGIN
  FOR r IN SELECT * FROM audit.audit_log ORDER BY chain_seq LOOP
    v_n := v_n + 1;
    IF r.prev_hash IS DISTINCT FROM v_prev
       OR r.hash <> public.digest(audit.chain_payload(r), 'sha256') THEN
      v_bad := r.chain_seq;
      EXIT;
    END IF;
    v_prev := r.hash;
  END LOOP;
  RETURN QUERY SELECT (v_bad IS NULL), v_n, v_bad;
END $$;
ALTER FUNCTION audit.verify_chain() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION audit.verify_chain() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit.verify_chain() TO audit_verifier, app_rw, app_ro;

-- 追記ヘルパ。auditlogd だけが呼べる。chain_seq と prev_hash / hash を
-- ここで採番・計算するので、呼出側がチェーンを壊せない。
CREATE OR REPLACE FUNCTION audit.append(
  p_tenant uuid, p_occurred timestamptz, p_actor uuid, p_actor_type text,
  p_action text, p_target_type text, p_target_id uuid,
  p_changed jsonb, p_reason text, p_signature bytea)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE v_seq bigint; v_prev bytea; r audit.audit_log;
BEGIN
  -- 単一直列点。並行追記でも欠番・逆転が起きないようにロックで直列化する。
  PERFORM pg_advisory_xact_lock(8891234502);
  SELECT coalesce(max(chain_seq), 0) + 1 INTO v_seq FROM audit.audit_log;
  SELECT hash INTO v_prev FROM audit.audit_log ORDER BY chain_seq DESC LIMIT 1;

  r.chain_seq := v_seq; r.tenant_id := p_tenant; r.occurred_at := p_occurred;
  r.action := p_action; r.target_type := p_target_type; r.target_id := p_target_id;
  r.changed_fields := p_changed; r.prev_hash := v_prev;

  INSERT INTO audit.audit_log (chain_seq, tenant_id, occurred_at, appended_at,
    actor_id, actor_type, action, target_type, target_id, changed_fields, reason,
    prev_hash, hash, signature)
  VALUES (v_seq, p_tenant, p_occurred, now(), p_actor, p_actor_type, p_action,
    p_target_type, p_target_id, p_changed, p_reason, v_prev,
    public.digest(audit.chain_payload(r), 'sha256'), p_signature);
  RETURN v_seq;
END $$;
ALTER FUNCTION audit.append(uuid, timestamptz, uuid, text, text, text, uuid, jsonb, text, bytea)
  OWNER TO schema_owner;
REVOKE ALL ON FUNCTION audit.append(uuid, timestamptz, uuid, text, text, text, uuid, jsonb, text, bytea)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit.append(uuid, timestamptz, uuid, text, text, text, uuid, jsonb, text, bytea)
  TO auditlogd;
