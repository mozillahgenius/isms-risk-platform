-- 0021 の巻き戻し
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

-- ロールは、この migration が作った印があるものだけ落とす（0001 と同じ作法）。
--
-- ロールは **クラスタ全体**の存在なので、同じクラスタの別 DB（開発用と CI 用を
-- 並べている等）がまだ参照していると落とせない。無条件に DROP すると必ず失敗し、
-- 巻き戻し自体が通らなくなる。他 DB からの依存が残っている間は残す。
DO $$
DECLARE n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provisioner') THEN
    RETURN;
  END IF;

  -- この DB 側の権限は先に外す（他 DB が参照していても、ここは掃除しておく）。
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
