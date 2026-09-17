-- 0015 全 app テーブルへの RLS 一括適用と、実効権限の付与（設計書 2.2.1 / 9.1 / 9.2）
--
-- 人手で 1 テーブルずつ書かない。tenant_id を持つ app の表を列挙して展開する。
-- 漏れは CI（scripts/ci/check_rls.sql）が落とす。
--
-- 除外する表（定義者専用。app_rw / app_ro にテーブル権限を与えない）:
--   app.sessions             … 0005 で ctx_session_lookup ポリシーを張り済み。
--                               読み書きは 0006 の SECURITY DEFINER 関数経由のみ
--   app.tenant_context_keys  … tenant_id を持たないのでループ対象外だが明示する
-- 既に 0005 で個別にポリシーを張っている app.tenants はループ対象外（tenant_id 列が無い）。

DO $$
DECLARE
  r record;
  excluded constant text[] := ARRAY['sessions','tenant_context_keys'];
  -- 追記のみの表（設計書 2.6）。UPDATE / DELETE を与えると
  -- 「追記のみ」という主張がコメントだけのものになる。
  append_only constant text[] := ARRAY['device_snapshots','graph_events'];
BEGIN
  FOR r IN SELECT c.relname FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id'
                                AND NOT a.attisdropped
            WHERE n.nspname = 'app' AND c.relkind = 'r'
              AND NOT (c.relname = ANY(excluded))
            ORDER BY c.relname
  LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', r.relname);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY', r.relname);

    -- 既存があれば必ず作り直す。「同名があればスキップ」にすると、
    -- 内容が誤っているポリシーが黙って残る。
    EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON app.%I', r.relname);
    EXECUTE format('DROP POLICY IF EXISTS tenant_read      ON app.%I', r.relname);

    EXECUTE format($f$CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw
                      USING (tenant_id = app.current_tenant())
                      WITH CHECK (tenant_id = app.current_tenant())$f$, r.relname);
    EXECUTE format($f$CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro
                      USING (tenant_id = app.current_tenant())$f$, r.relname);

    -- 実効権限。GRANT ALL は使わない（TRUNCATE / REFERENCES / TRIGGER を含めない）。
    -- 念のため PUBLIC からは明示的に剥がす（既定で付くことは無いが、
    -- 手作業で付けられていた場合に黙って通さない）。
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC', r.relname);
    IF r.relname = ANY(append_only) THEN
      EXECUTE format('GRANT SELECT, INSERT ON app.%I TO app_rw', r.relname);
    ELSE
      EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON app.%I TO app_rw', r.relname);
    END IF;
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro', r.relname);
  END LOOP;
END $$;

-- app.tenants は tenant_id 列を持たない（id がテナント識別子）。0005 でポリシー済み。
GRANT SELECT, INSERT, UPDATE, DELETE ON app.tenants TO app_rw;
GRANT SELECT ON app.tenants TO app_ro;

-- catalog は読み取り専用（設計書 2.1）
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.relname FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'catalog' AND c.relkind = 'r'
  LOOP
    EXECUTE format('GRANT SELECT ON catalog.%I TO app_rw, app_ro', r.relname);
  END LOOP;
END $$;

-- 定義者専用テーブルに権限が漏れていないことを、この場で実測して落とす。
DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(format('%s:%s:%s', t.relname, g.grantee, g.privilege_type), ', ')
    INTO v_bad
    FROM pg_class t
    JOIN pg_namespace n ON n.oid = t.relnamespace
    CROSS JOIN LATERAL aclexplode(coalesce(t.relacl, acldefault('r', t.relowner))) g
   WHERE n.nspname = 'app'
     AND t.relname IN ('sessions','tenant_context_keys')
     AND g.grantee::regrole::text IN ('app_rw','app_ro','auditlogd','audit_verifier');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'definer-only tables leaked privileges: %', v_bad;
  END IF;
END $$;
