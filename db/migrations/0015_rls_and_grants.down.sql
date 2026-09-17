-- 0015 の巻き戻し。ポリシーと権限を外す（表そのものは 0002〜0013 の down が落とす）。
DO $$
DECLARE
  r record;
  excluded constant text[] := ARRAY['sessions','tenant_context_keys'];
BEGIN
  FOR r IN SELECT c.relname FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id'
                                AND NOT a.attisdropped
            WHERE n.nspname = 'app' AND c.relkind = 'r'
              AND NOT (c.relname = ANY(excluded))
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON app.%I', r.relname);
    EXECUTE format('DROP POLICY IF EXISTS tenant_read      ON app.%I', r.relname);
    EXECUTE format('REVOKE ALL ON app.%I FROM app_rw, app_ro', r.relname);
    EXECUTE format('ALTER TABLE app.%I NO FORCE ROW LEVEL SECURITY', r.relname);
    EXECUTE format('ALTER TABLE app.%I DISABLE ROW LEVEL SECURITY', r.relname);
  END LOOP;

  FOR r IN SELECT c.relname FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'catalog' AND c.relkind = 'r'
  LOOP
    EXECUTE format('REVOKE ALL ON catalog.%I FROM app_rw, app_ro', r.relname);
  END LOOP;
END $$;

REVOKE ALL ON app.tenants FROM app_rw, app_ro;
