-- @run-as: admin
-- 0001 初期化（設計書 2.2）。拡張・スキーマ・ロール・テナント文脈関数の仮定義。
--
-- ここだけ superuser で実行する。CREATE EXTENSION と CREATE ROLE は
-- schema_owner の権限では通らない。0002 以降は SET ROLE schema_owner。

CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_uuid(), hmac(), digest()
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- EXCLUDE 制約で uuid の等価比較を使うため
CREATE EXTENSION IF NOT EXISTS citext;      -- メールアドレスの大小無視比較

CREATE SCHEMA IF NOT EXISTS catalog;        -- DOM（共有マスタ。tenant_id を持たない）
CREATE SCHEMA IF NOT EXISTS app;            -- テナントデータ
CREATE SCHEMA IF NOT EXISTS audit;          -- 監査ログ

-- ロール（設計書 9.1）。いずれにも BYPASSRLS を与えない。
-- schema_owner は DDL 専用かつ SECURITY DEFINER 関数の所有者を兼ねるため
-- LOGIN を持たせない（app_rw/app_ro から SET ROLE する経路も作らない）。
-- 既に同名ロールがある環境（開発機の使い回し等）で属性が設計どおりとは限らない。
-- CREATE だけでは既存ロールの SUPERUSER / BYPASSRLS が残るので、必ず ALTER で固定する。
DO $$
DECLARE
  r record;
  -- auth_svc は設計書 9.1 に無い追加のロール。セッション発行だけを担う。
  -- app_rw に発行権限を持たせると、app_rw が任意テナント向けのセッションを作って
  -- そのトークンで文脈を確立でき、テナント分離が丸ごと無効になる（docs/DECISIONS.md D-12）。
  roles constant text[] := ARRAY['schema_owner','app_rw','app_ro','auth_svc',
                                 'auditlogd','audit_verifier'];
  logins constant text[] := ARRAY['app_rw','app_ro','auth_svc','auditlogd','audit_verifier'];
  name text;
BEGIN
  FOREACH name IN ARRAY roles LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = name) THEN
      EXECUTE format('CREATE ROLE %I', name);
      -- 「この migration が作ったロール」であることを印として残す。
      -- down はこの印があるものだけ落とす。もともと在ったロールを消して
      -- その所有物ごと巻き添えにしないため（DROP OWNED BY は破壊的）。
      EXECUTE format('COMMENT ON ROLE %I IS %L', name, 'created-by:isms-platform-migration');
    END IF;
    -- 属性は毎回明示的に固定する（冪等かつ是正的）
    EXECUTE format(
      'ALTER ROLE %I NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION %s',
      name,
      CASE WHEN name = ANY(logins) THEN 'LOGIN' ELSE 'NOLOGIN' END);
  END LOOP;

  -- 設計 9.1「いずれにも BYPASSRLS を与えない」を、この時点で実測して落とす
  FOR r IN SELECT rolname FROM pg_roles
            WHERE rolname = ANY(roles) AND (rolsuper OR rolbypassrls) LOOP
    RAISE EXCEPTION 'role % still has SUPERUSER or BYPASSRLS', r.rolname;
  END LOOP;
END $$;

ALTER SCHEMA catalog OWNER TO schema_owner;
ALTER SCHEMA app     OWNER TO schema_owner;
ALTER SCHEMA audit   OWNER TO schema_owner;

GRANT USAGE ON SCHEMA catalog TO app_rw, app_ro;
GRANT USAGE ON SCHEMA app     TO app_rw, app_ro;
-- audit の USAGE を app_rw/app_ro にも与えるのは設計書 2.2 / 8.3 の意図どおり。
-- 監査ログの閲覧は CISO・事務局・監査人の権限（9.5 権限マトリクス）であり、
-- テーブル側は SELECT のみ・RLS でテナント限定・UPDATE/DELETE は REVOKE 済み（0014）。
GRANT USAGE ON SCHEMA audit   TO app_rw, app_ro, auditlogd, audit_verifier;

-- 誰も public スキーマにオブジェクトを作れないようにする（既定の落とし穴）
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- ALTER DEFAULT PRIVILEGES は「その実行者が今後作るオブジェクト」にしか効かず、
-- 既存には遡及しない。実効権限は 0015 で明示 GRANT し、CI が実オブジェクトを直接検査する。
ALTER DEFAULT PRIVILEGES FOR ROLE schema_owner IN SCHEMA catalog
  GRANT SELECT ON TABLES TO app_rw, app_ro;

-- ------------------------------------------------------------------
-- テナント文脈（仮定義）
--
-- 設計書 2.2 / 9.2 の実装をそのまま置くと GUC app.tenant_id を app_rw が
-- 自分で SET でき、受入 #7 を満たさない。0006 で HMAC 署名を検証する版へ
-- CREATE OR REPLACE する。ここでは鍵テーブルがまだ無いので仮実装を置く。
-- 「証明できる性質の範囲」は docs/DECISIONS.md を参照。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.current_tenant() RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE v text := current_setting('app.tenant_id', true);
BEGIN
  IF v IS NULL OR v = '' THEN
    RAISE EXCEPTION 'tenant context is not set' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v::uuid;
END $$;

ALTER FUNCTION app.current_tenant() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.current_tenant() FROM PUBLIC;
-- app_ro も RLS ポリシー式の評価でこの関数を呼ぶため EXECUTE が要る
-- （Codex 指摘: 関数ごとの実行権限表は docs/DECISIONS.md）。
GRANT EXECUTE ON FUNCTION app.current_tenant() TO app_rw, app_ro;
