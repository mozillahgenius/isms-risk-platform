-- 0022 チェックの合格ゲートを「形の検査」から「中身の照合」へ上げる。
--
-- 0021 の制約は result='pass' に negative_verified と 64 桁の verified_digest を
-- 求めるだけだった。つまり **書ける主体が true と適当な 64 桁を入れれば pass にできた**。
-- 形は合っているが中身を見ていないので、ゲートとしては素通しに近い。
--
-- ここで足すもの:
--   (A) catalog.check_digest() — チェックの中身から指紋を作る。**DB を唯一の計算元にする**。
--       実行側（scripts/checker.py）もこの関数を呼ぶので、2 か所で同じ式を書かない
--       （書くと必ずどちらかがずれて、ずれた側が黙って通る）。
--   (B) app.check_runs のトリガ — negative_verified を立てるなら、verified_digest が
--       **いまのカタログの中身と一致していること**を求める。
--       中身が書き換わったチェックを「確認済み」として記録できない。
--
-- これで防げること: 適当な 64 桁での偽装、確認後にチェックを書き換えて通すこと。
-- これで防げないこと: 「fixture を本当に流したか」そのもの。
--   それは実行側の仕事で、DB からは見えない（docs/DECISIONS.md D-27）。

SET ROLE schema_owner;

-- ------------------------------------------------------------------ (A) 指紋
-- 合否の決め方に関わるものを全部入れる。expect を緩めれば別の指紋になる。
-- jsonb の ::text は鍵順が正規化されるので、書き方の揺れで指紋が動かない。
CREATE OR REPLACE FUNCTION catalog.check_digest(p_key text) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT pg_catalog.encode(
           public.digest(
             c.query_sql        || pg_catalog.chr(31) ||
             c.negative_fixture || pg_catalog.chr(31) ||
             c.expect::text     || pg_catalog.chr(31) ||
             c.coverage_required::text,
             'sha256'),
           'hex')
    FROM catalog.checks c WHERE c.key = p_key
$$;
ALTER FUNCTION catalog.check_digest(text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION catalog.check_digest(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION catalog.check_digest(text) TO app_rw, app_ro;

COMMENT ON FUNCTION catalog.check_digest(text) IS
  'チェックの中身の指紋。実行側もトリガもこの関数だけを使う（式を二重に書かない）。';

-- ------------------------------------------------------------------ (B) 照合
CREATE OR REPLACE FUNCTION app.enforce_check_digest() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE v_expected text;
BEGIN
  IF NOT NEW.negative_verified THEN
    -- 確認していないと言っているなら、指紋は持たせない（持てば紛らわしい）。
    IF NEW.verified_digest IS NOT NULL THEN
      RAISE EXCEPTION '確認していない実行に verified_digest は付けられません'
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;

  v_expected := catalog.check_digest(NEW.check_key);
  IF v_expected IS NULL THEN
    RAISE EXCEPTION 'チェック % がカタログにありません', NEW.check_key
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF NEW.verified_digest IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION '確認した中身といまのカタログが一致しません（チェック %）', NEW.check_key
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
ALTER FUNCTION app.enforce_check_digest() OWNER TO schema_owner;

CREATE TRIGGER trg_check_runs_digest
  BEFORE INSERT OR UPDATE ON app.check_runs
  FOR EACH ROW EXECUTE FUNCTION app.enforce_check_digest();

-- ------------------------------------------------------------------ 乗っ取り対策
-- 0021 の provision_tenant は public.gen_random_uuid() を名指ししていた。
-- search_path を固定していても、public に関数を作れる主体が居れば差し替えられる。
-- この DB では PUBLIC から CREATE を剥がしてあるが、依存しない形にしておく。
-- gen_random_uuid は PostgreSQL 13 以降は組み込み（pg_catalog）。
CREATE OR REPLACE FUNCTION app.provision_tenant(
  p_name text, p_domain text, p_admin_email text, p_admin_name text,
  p_fiscal_start_month smallint DEFAULT 4, p_industry_preset text DEFAULT 'general'
) RETURNS TABLE (tenant_id uuid, user_id uuid, policies_expanded int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  v_tenant uuid := pg_catalog.gen_random_uuid();
  v_user   uuid := pg_catalog.gen_random_uuid();
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

  PERFORM pg_catalog.set_config('app.provisioning', v_tenant::text, true);

  INSERT INTO app.tenants (id, name, domain, fiscal_start_month, industry_preset, dom_version_id)
  VALUES (v_tenant, p_name, p_domain, p_fiscal_start_month, p_industry_preset, v_dom);

  INSERT INTO app.users (id, tenant_id, email, display_name)
  VALUES (v_user, v_tenant, p_admin_email, p_admin_name);

  INSERT INTO app.memberships (tenant_id, user_id, role_key) VALUES (v_tenant, v_user, 'ciso');

  WITH src AS MATERIALIZED (
    SELECT pg_catalog.gen_random_uuid() AS policy_id, d.key, d.title_ja, d.body_md
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
GRANT EXECUTE ON FUNCTION app.provision_tenant(text, text, text, text, smallint, text) TO provisioner;

RESET ROLE;
