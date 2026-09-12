-- @run-as: admin
-- Rollback of 0001.
-- Extensions are not dropped (other schemas in the same DB may use them; that would be an excessive DROP).
-- Schemas are dropped without CASCADE. If the downs of 0002-0015 all ran, they should be empty;
-- if anything remains, DROP fails. That is welcome as detection of an incomplete rollback, so it is not swallowed.

DROP FUNCTION IF EXISTS app.set_tenant_context(text);
DROP FUNCTION IF EXISTS app.current_tenant();

-- Revoke ALTER DEFAULT PRIVILEGES (required before dropping the roles)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'catalog') THEN
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE schema_owner IN SCHEMA catalog
               REVOKE SELECT ON TABLES FROM app_rw, app_ro';
  END IF;
END $$;

DROP SCHEMA IF EXISTS audit;
DROP SCHEMA IF EXISTS app;
DROP SCHEMA IF EXISTS catalog;

-- CREATE privilege on the public schema is **not restored**.
-- up's REVOKE does not record "whether it was originally granted", so an unconditional re-GRANT
-- would undo, via rollback, hardening that was in place before this migration was applied.
-- Rather than move from the safe side to the dangerous side on rollback, it is better not to restore it.
-- To return to the original state, run `GRANT CREATE ON SCHEMA public TO PUBLIC` by hand.

-- Roles exist **cluster-wide**, not per database, so
-- they cannot be dropped while another DB in the same cluster (e.g. dev and CI side by side) still references them.
-- An unconditional DROP would either break that other DB or always fail here.
-- Keep them while dependencies from other DBs remain; drop them only when none remain.
DO $$
DECLARE
  r text;
  n int;
  roles constant text[] := ARRAY['audit_verifier','auditlogd','auth_svc',
                                 'app_ro','app_rw','schema_owner'];
BEGIN
  FOREACH r IN ARRAY roles LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN CONTINUE; END IF;

    -- Only roles created by up carry the marker. No marker = a pre-existing role, so
    -- leave it alone (DROP OWNED BY would take that role's owned objects down with it).
    IF NOT EXISTS (
      SELECT 1 FROM pg_shdescription sd
        JOIN pg_roles ro ON ro.oid = sd.objoid
       WHERE ro.rolname = r
         AND sd.classoid = 'pg_authid'::regclass
         AND sd.description = 'created-by:isms-platform-migration'
    ) THEN
      RAISE NOTICE 'ロール % は この migration が作ったものではないので残します', r;
      CONTINUE;
    END IF;

    SELECT count(*) INTO n
      FROM pg_shdepend d
      JOIN pg_roles ro ON ro.oid = d.refobjid
     WHERE ro.rolname = r AND d.dbid <> 0
       AND d.dbid <> (SELECT oid FROM pg_database WHERE datname = current_database());
    IF n > 0 THEN
      RAISE NOTICE 'ロール % は他のデータベースが参照中（% 件）のため残します', r, n;
    ELSE
      EXECUTE format('DROP OWNED BY %I', r);
      EXECUTE format('DROP ROLE %I', r);
    END IF;
  END LOOP;
END $$;
