-- Rollback of 0021
SET ROLE schema_owner;

ALTER TABLE app.check_runs DROP CONSTRAINT IF EXISTS check_runs_digest_shape;
ALTER TABLE app.check_runs DROP CONSTRAINT IF EXISTS check_runs_pass_requires_negative_verification;
ALTER TABLE app.check_runs DROP COLUMN IF EXISTS verified_digest;
ALTER TABLE app.check_runs DROP COLUMN IF EXISTS negative_verified;

DROP FUNCTION IF EXISTS app.provision_tenant(text, text, text, text, smallint, text);

DROP POLICY IF EXISTS prov_policy_version_insert ON app.policy_versions;
DROP POLICY IF EXISTS prov_policy_insert ON app.policies;
DROP POLICY IF EXISTS prov_membership_insert ON app.memberships;
DROP POLICY IF EXISTS prov_user_insert ON app.users;
DROP POLICY IF EXISTS prov_tenant_insert ON app.tenants;

DROP FUNCTION IF EXISTS app.provisioning_target();

RESET ROLE;

-- Only drop roles that carry the marker showing this migration created them (same practice as 0001).
--
-- Roles exist **cluster-wide**, so they cannot be dropped while another DB in the same cluster (e.g. dev and CI
-- side by side) still references them. An unconditional DROP would always fail, and
-- the rollback itself would not go through. Keep them while dependencies from other DBs remain.
DO $$
DECLARE n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provisioner') THEN
    RETURN;
  END IF;

  -- Remove this DB's privileges first (clean up here even if other DBs still reference the role).
  EXECUTE 'REVOKE ALL ON SCHEMA app FROM provisioner';

  IF NOT EXISTS (
    SELECT 1 FROM pg_shdescription sd
      JOIN pg_roles ro ON ro.oid = sd.objoid
     WHERE ro.rolname = 'provisioner'
       AND sd.classoid = 'pg_authid'::regclass
       AND sd.description = 'created-by:isms-platform-migration'
  ) THEN
    RAISE NOTICE 'ロール provisioner は この migration が作ったものではないので残します';
    RETURN;
  END IF;

  SELECT count(*) INTO n
    FROM pg_shdepend d
    JOIN pg_roles ro ON ro.oid = d.refobjid
   WHERE ro.rolname = 'provisioner' AND d.dbid <> 0
     AND d.dbid <> (SELECT oid FROM pg_database WHERE datname = current_database());
  IF n > 0 THEN
    RAISE NOTICE 'ロール provisioner は他のデータベースが参照中（% 件）のため残します', n;
  ELSE
    EXECUTE 'DROP OWNED BY provisioner';
    EXECUTE 'DROP ROLE provisioner';
  END IF;
END $$;
