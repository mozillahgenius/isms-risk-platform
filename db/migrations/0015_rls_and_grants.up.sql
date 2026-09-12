-- 0015 Bulk RLS for all app tables and grants of effective privileges (design doc 2.2.1 / 9.1 / 9.2)
--
-- Not written by hand one table at a time: app tables with tenant_id are enumerated and expanded.
-- Omissions are caught by CI (scripts/ci/check_rls.sql).
--
-- Excluded tables (definer-only; app_rw / app_ro get no table privileges):
--   app.sessions             … ctx_session_lookup policy already set in 0005.
--                               Read/write only via the SECURITY DEFINER functions in 0006
--   app.tenant_context_keys  … has no tenant_id so is outside the loop anyway, but listed explicitly
-- app.tenants, which already has its own policy from 0005, is outside the loop (no tenant_id column).

DO $$
DECLARE
  r record;
  excluded constant text[] := ARRAY['sessions','tenant_context_keys'];
  -- Append-only tables (design doc 2.6). Granting UPDATE / DELETE would make
  -- the "append-only" claim exist only in comments.
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

    -- Always recreate existing policies. "Skip if one with the same name exists" would
    -- silently leave a policy with wrong content in place.
    EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON app.%I', r.relname);
    EXECUTE format('DROP POLICY IF EXISTS tenant_read      ON app.%I', r.relname);

    EXECUTE format($f$CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw
                      USING (tenant_id = app.current_tenant())
                      WITH CHECK (tenant_id = app.current_tenant())$f$, r.relname);
    EXECUTE format($f$CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro
                      USING (tenant_id = app.current_tenant())$f$, r.relname);

    -- Effective privileges. GRANT ALL is not used (TRUNCATE / REFERENCES / TRIGGER are excluded).
    -- Explicitly revoke from PUBLIC just in case (never granted by default, but
    -- do not silently let through a grant that was added by hand).
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC', r.relname);
    IF r.relname = ANY(append_only) THEN
      EXECUTE format('GRANT SELECT, INSERT ON app.%I TO app_rw', r.relname);
    ELSE
      EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON app.%I TO app_rw', r.relname);
    END IF;
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro', r.relname);
  END LOOP;
END $$;

-- app.tenants has no tenant_id column (id is the tenant identifier). Policy already set in 0005.
GRANT SELECT, INSERT, UPDATE, DELETE ON app.tenants TO app_rw;
GRANT SELECT ON app.tenants TO app_ro;

-- catalog is read-only (design doc 2.1)
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

-- Measure right here that no privileges leaked onto definer-only tables, and fail if they did.
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
