-- 0043 down: revert to the trigger definitions as of 0005
--
-- Note: no BEGIN/COMMIT here. scripts/migrate.sh already wraps the whole file
-- in a single transaction.

DROP POLICY IF EXISTS ctx_user_lock ON app.users;

DROP TRIGGER IF EXISTS trg_department_owner_active ON app.departments;
DROP FUNCTION IF EXISTS app.check_department_owner_active();

DROP TRIGGER IF EXISTS trg_membership_active_user ON app.memberships;
DROP FUNCTION IF EXISTS app.check_membership_active_user();

CREATE OR REPLACE FUNCTION app.check_auditor_exclusivity() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM app.memberships m
    WHERE m.tenant_id = NEW.tenant_id AND m.user_id = NEW.user_id
      AND m.revoked_at IS NULL AND m.id <> NEW.id
      AND (m.role_key = 'auditor') <> (NEW.role_key = 'auditor')
  ) THEN
    RAISE EXCEPTION 'auditor role cannot be combined with other roles';
  END IF;
  RETURN NEW;
END $$;
