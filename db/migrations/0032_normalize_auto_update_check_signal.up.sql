-- v2 names the softwareupdate --schedule signal accurately. Keep the
-- normalized legacy column during the rollback window, but derive it from
-- the v2 field (and accept the v1 field for old agents).

SET ROLE schema_owner;

CREATE OR REPLACE FUNCTION app.normalize_auto_update_check_signal() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  NEW.auto_update_enabled := COALESCE(
    NULLIF(NEW.payload->>'auto_update_checks_enabled', '')::boolean,
    NULLIF(NEW.payload->>'auto_update_enabled', '')::boolean,
    NEW.auto_update_enabled
  );
  RETURN NEW;
END $$;
ALTER FUNCTION app.normalize_auto_update_check_signal() OWNER TO schema_owner;

CREATE TRIGGER trg_normalize_auto_update_check_signal
  BEFORE INSERT OR UPDATE OF payload ON app.device_snapshots
  FOR EACH ROW EXECUTE FUNCTION app.normalize_auto_update_check_signal();

RESET ROLE;
