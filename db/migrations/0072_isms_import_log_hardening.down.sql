-- @run-as: admin
-- 0072 の巻き戻し。取り込みの記録の守りを 0071 の版へ戻す（トリガと関数だけで、データは失われない）。

DROP TRIGGER IF EXISTS assets_keep_created_at ON app.assets;
DROP TRIGGER IF EXISTS risk_scenarios_keep_created_at ON app.risk_scenarios;
DROP TRIGGER IF EXISTS import_batches_complete ON app.import_batches;

SET ROLE schema_owner;

DROP FUNCTION IF EXISTS app.import_batch_complete();
DROP FUNCTION IF EXISTS app.keep_created_at();

CREATE OR REPLACE FUNCTION app.import_items_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  v_ok boolean;
BEGIN
  SELECT (b.imported_at = now() AND b.imported_by = app.current_session_user()) INTO v_ok
    FROM app.import_batches b WHERE b.tenant_id = NEW.tenant_id AND b.id = NEW.batch_id;
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'import items can only be added to a batch created in this transaction'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NEW.target_type = 'asset' THEN
    SELECT (a.created_at = now()) INTO v_ok FROM app.assets a WHERE a.tenant_id = NEW.tenant_id AND a.id = NEW.target_id;
  ELSE
    SELECT (r.created_at = now()) INTO v_ok FROM app.risk_scenarios r WHERE r.tenant_id = NEW.tenant_id AND r.id = NEW.target_id;
  END IF;
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'import items must point to rows created in this transaction'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION app.import_log_stamp() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF TG_TABLE_NAME = 'import_batches' THEN
    NEW.imported_by := app.current_session_user();
    NEW.imported_at := now();
  ELSIF TG_TABLE_NAME = 'import_undos' THEN
    NEW.undone_by := app.current_session_user();
    NEW.undone_at := now();
  END IF;
  RETURN NEW;
END $$;

RESET ROLE;
