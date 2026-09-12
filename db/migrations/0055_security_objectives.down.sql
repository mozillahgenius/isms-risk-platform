-- @run-as: admin

-- **Do not roll back when data exists.** Information security objectives and their achievement evaluations are
-- 6.2 records and must not silently disappear on down.
--
-- The guard goes **before SET ROLE**. After switching to schema_owner,
-- the RLS policy management_definer_access requires app.current_tenant(), and
-- a migration without a tenant context fails before it can count rows (measured).
-- The connecting user is superuser with BYPASSRLS, so it can count across all tenants
-- (measured in production: postgres / super=true / bypassrls=true).
--
-- **Take the lock before counting.** Without it, another session could INSERT between count and DROP,
-- and those rows would be dropped right after the 0-row verdict.
-- migrate.sh's run_file wraps both up and down in BEGIN ... COMMIT, so
-- the lock taken here is held until DROP TABLE (confirmed by measurement).
--
-- **SHARE is enough.** What we want to block is INSERT/UPDATE/DELETE (ROW EXCLUSIVE);
-- SHARE conflicts with that while letting SELECT through. ACCESS EXCLUSIVE would
-- make us wait, before even returning the refusal, merely because some session is reading.
--
-- Bound the lock wait so deployment does not hang. If the lock cannot be taken, fail,
-- turning "unknown whether it can be rolled back" into "do not roll back".
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  LOCK TABLE app.security_objectives IN SHARE MODE;
  SELECT count(*) INTO n FROM app.security_objectives;
  IF n > 0 THEN
    RAISE EXCEPTION '0055 rollback refused: security objectives would be lost (% rows)', n;
  END IF;
END $$;

SET ROLE schema_owner;

DROP TABLE IF EXISTS app.security_objectives;

RESET ROLE;
