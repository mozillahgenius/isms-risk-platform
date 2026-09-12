SET ROLE schema_owner;

DROP TRIGGER IF EXISTS trg_normalize_auto_update_check_signal ON app.device_snapshots;
DROP FUNCTION IF EXISTS app.normalize_auto_update_check_signal();

RESET ROLE;
