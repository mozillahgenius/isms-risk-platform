-- @run-as: admin
-- 0021 テナントの作成経路と、チェックの合格ゲート。
--
-- admin で流す。CREATE ROLE は schema_owner（NOCREATEROLE）では通らないため。
-- ロール作成以外は SET ROLE schema_owner で行い、所有者を揃える。
--
-- ここで足すもの:
--   (A) app.provision_tenant() — テナント・初期利用者・membership・標準規程の展開を
--       ひとまとまりで作る。これが無いと、テナントが 1 つも作れないため
--       運用データが永遠に空のままになる（画面も「読めない」以上のことを言えない）。
--   (B) app.check_runs の合格ゲート — **壊して落ちることを確かめていないチェックを
--       pass として記録させない**。これを運用の心がけではなく DB の制約として置く。
--
-- なぜ (B) を DB に置くか:
--   検査は「通ったこと」ではなく「落ちるべき時に落ちること」で初めて検査になる。
--   人が確認する運用にすると、忙しい日に飛ばされ、そのまま緑が並ぶ。
--   記録する側が制約に従うほかない形にすれば、飛ばした時点で記録できない。

SET ROLE schema_owner;

-- ============================================================ (A) 作成経路

-- 作成中だけ立てる目印。下の provisioning ポリシーはこの値と一致する行しか通さない。
-- 「schema_owner なら何でも入れられる」ではなく「いま作っているテナントの行だけ」に絞る。
CREATE OR REPLACE FUNCTION app.provisioning_target() RETURNS uuid
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT NULLIF(pg_catalog.current_setting('app.provisioning', true), '')::uuid
$$;
ALTER FUNCTION app.provisioning_target() OWNER TO schema_owner;

-- 定義者（schema_owner）向けの INSERT ポリシー。
-- schema_owner は NOLOGIN で、ここを通れるのは所有者が書いた SECURITY DEFINER 関数だけ。
-- それでも「どのテナントの行でも入れられる」形にはしない。
CREATE POLICY prov_tenant_insert ON app.tenants
  FOR INSERT TO schema_owner WITH CHECK (id = app.provisioning_target());
CREATE POLICY prov_user_insert ON app.users
  FOR INSERT TO schema_owner WITH CHECK (tenant_id = app.provisioning_target());
CREATE POLICY prov_membership_insert ON app.memberships
  FOR INSERT TO schema_owner WITH CHECK (tenant_id = app.provisioning_target());
CREATE POLICY prov_policy_insert ON app.policies
  FOR INSERT TO schema_owner WITH CHECK (tenant_id = app.provisioning_target());
CREATE POLICY prov_policy_version_insert ON app.policy_versions
  FOR INSERT TO schema_owner WITH CHECK (tenant_id = app.provisioning_target());

-- テナントを作る唯一の経路。
-- 標準規程 12 本をそのまま展開する（受入 #1「テナント作成直後に標準が有効」の土台）。
CREATE OR REPLACE FUNCTION app.provision_tenant(
  p_name text, p_domain text, p_admin_email text, p_admin_name text,
  p_fiscal_start_month smallint DEFAULT 4, p_industry_preset text DEFAULT 'general'
) RETURNS TABLE (tenant_id uuid, user_id uuid, policies_expanded int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  v_tenant uuid := public.gen_random_uuid();
  v_user   uuid := public.gen_random_uuid();
  v_dom    uuid;
  v_count  int;
BEGIN
  IF coalesce(pg_catalog.btrim(p_name), '') = '' OR coalesce(pg_catalog.btrim(p_domain), '') = ''
     OR coalesce(pg_catalog.btrim(p_admin_email), '') = '' THEN
    RAISE EXCEPTION '名称・ドメイン・管理者メールは必須です';
  END IF;

  SELECT id INTO v_dom FROM catalog.dom_versions WHERE is_current;
  IF v_dom IS NULL THEN
    RAISE EXCEPTION '現行 DOM がありません。先に DOM を投入してください';
  END IF;

  -- 作成中の目印。トランザクション内だけで効く（set_config の第3引数 true）。
  PERFORM pg_catalog.set_config('app.provisioning', v_tenant::text, true);

  INSERT INTO app.tenants (id, name, domain, fiscal_start_month, industry_preset, dom_version_id)
  VALUES (v_tenant, p_name, p_domain, p_fiscal_start_month, p_industry_preset, v_dom);

  INSERT INTO app.users (id, tenant_id, email, display_name)
  VALUES (v_user, v_tenant, p_admin_email, p_admin_name);

  -- 最初の 1 人は経営責任者（CISO）。受容判断と承認の担い手が居ない組織を作らない。
  INSERT INTO app.memberships (tenant_id, user_id, role_key) VALUES (v_tenant, v_user, 'ciso');

  -- 標準規程の展開。本文は DOM の標準をそのまま写す。
  -- 差分を持たせるのはテナント側の判断で、その差分が逸脱として記録される（設計書 1.6）。
  --
  -- **INSERT ... RETURNING を使わない。** RETURNING は返す行に SELECT のポリシーを要求し、
  -- 定義者には読み取りのポリシーを与えていないため、そこで落ちる（実測）。
  -- 読み取りを広げて回避すると、作成のためだけに定義者へ全テナントの閲覧を渡すことになる。
  -- id を先に決めてしまえば、書き戻して読む必要が無い。
  WITH src AS MATERIALIZED (
    -- gen_random_uuid() は volatile。2 度参照するので必ず 1 回で確定させる。
    SELECT public.gen_random_uuid() AS policy_id, d.key, d.title_ja, d.body_md
      FROM catalog.policies_default d
      JOIN catalog.dom_versions v ON v.id = d.dom_version_id AND v.is_current
  ), ins AS (
    INSERT INTO app.policies (id, tenant_id, catalog_key, title)
    SELECT policy_id, v_tenant, key, title_ja FROM src
  )
  INSERT INTO app.policy_versions (tenant_id, policy_id, version, body_md, diff_clause_count)
  SELECT v_tenant, policy_id, 1, body_md, 0 FROM src;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  PERFORM pg_catalog.set_config('app.provisioning', '', true);

  tenant_id := v_tenant; user_id := v_user; policies_expanded := v_count;
  RETURN NEXT;
END $$;
ALTER FUNCTION app.provision_tenant(text, text, text, text, smallint, text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.provision_tenant(text, text, text, text, smallint, text) FROM PUBLIC;

-- 作成専用のロール。表への権限は持たせない（この関数を呼ぶことしかできない）。
-- app_rw に持たせると、業務用の接続がテナントを作れることになる。
-- CREATE ROLE は schema_owner では通らないので、ここだけ admin へ戻す。
RESET ROLE;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provisioner') THEN
    CREATE ROLE provisioner;
    COMMENT ON ROLE provisioner IS 'created-by:isms-platform-migration';
  END IF;
END $$;
ALTER ROLE provisioner NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION LOGIN;
GRANT USAGE ON SCHEMA app TO provisioner;
GRANT EXECUTE ON FUNCTION app.provision_tenant(text, text, text, text, smallint, text) TO provisioner;

-- ============================================================ (B) 合格ゲート

SET ROLE schema_owner;

-- negative_verified: そのチェックの negative_fixture を流し、**検査が実際に違反を
--   検出したこと**を確認できたか。
-- verified_digest: 確認した時点の query_sql と negative_fixture の指紋。
--   チェックの中身が書き換わったら、前の確認は根拠にならない。
ALTER TABLE app.check_runs
  ADD COLUMN negative_verified boolean NOT NULL DEFAULT false,
  ADD COLUMN verified_digest   text;

ALTER TABLE app.check_runs
  ADD CONSTRAINT check_runs_pass_requires_negative_verification
  CHECK (result <> 'pass' OR (negative_verified AND verified_digest IS NOT NULL));

ALTER TABLE app.check_runs
  ADD CONSTRAINT check_runs_digest_shape
  CHECK (verified_digest IS NULL OR verified_digest ~ '^[0-9a-f]{64}$');

COMMENT ON COLUMN app.check_runs.negative_verified IS
  '壊して落ちることを確かめたか。false のまま pass では記録できない（制約で強制）。';
COMMENT ON COLUMN app.check_runs.verified_digest IS
  '確認した時点の query_sql と negative_fixture の SHA-256。中身が変われば確認はやり直し。';

RESET ROLE;
