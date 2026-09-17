-- 0043 down: 0005時点のトリガー定義へ戻す
--
-- 注: BEGIN/COMMITはここには書かない。scripts/migrate.shがファイル全体を
-- 既に1トランザクションで包んでいる。

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
