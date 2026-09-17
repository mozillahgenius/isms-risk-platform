SET ROLE schema_owner;

DROP INDEX IF EXISTS app.assets_location_system_idx;
ALTER TABLE app.assets DROP CONSTRAINT IF EXISTS assets_location_system_fk;
ALTER TABLE app.assets DROP COLUMN IF EXISTS location_note;
ALTER TABLE app.assets DROP COLUMN IF EXISTS location_system_id;

DROP TRIGGER IF EXISTS trg_guard_department_systems ON app.department_systems;
DROP FUNCTION IF EXISTS app.guard_department_systems();
DROP TABLE IF EXISTS app.department_systems;

DROP FUNCTION IF EXISTS app.update_system(uuid,text,text,text);
DROP FUNCTION IF EXISTS app.create_system(text,text,text,text);
DROP POLICY IF EXISTS tenant_security_definer_read ON app.assets;
DROP POLICY IF EXISTS tenant_security_definer ON app.application_catalog;
DROP TRIGGER IF EXISTS trg_guard_application_catalog ON app.application_catalog;
DROP FUNCTION IF EXISTS app.guard_application_catalog();
DROP FUNCTION IF EXISTS app.require_system_edit_permission();

-- up が付けたコメントを外す。0045 は application_catalog にコメントを
-- 付けていない（付けているのは provisioning_requests だけ。実測）ので、
-- NULL に戻すのが元の状態と一致する。
COMMENT ON TABLE app.application_catalog IS NULL;

RESET ROLE;
