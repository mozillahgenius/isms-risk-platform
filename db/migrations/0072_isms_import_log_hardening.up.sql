-- @run-as: admin
-- 0072: Harden the import records (0071) (Codex review 2026-09-12).
--   1. Do not let updates change created_at of assets and risks. 0071's item guard identifies "rows created in this transaction"
--      by "created_at is now (this transaction)", so if app_rw rewrote an existing row's created_at to now, a pre-existing row could
--      be attached to the import's items and retired by an undo.
--   2. Consistency between items and import records: kind matches target (no risks on an asset import), row numbers within row count,
--      item count equals created count (checked at commit).
--   3. The DB counts undo totals (written values are not trusted). Rows retired in this transaction are "retired"; the rest "not applicable".

SET ROLE schema_owner;

CREATE FUNCTION app.keep_created_at() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  -- Creation time is when it was created. Updates do not change it (silently restored).
  NEW.created_at := OLD.created_at;
  RETURN NEW;
END $$;

-- Item guard (0071's version plus kind match, row-number range, and count upper bound).
CREATE OR REPLACE FUNCTION app.import_items_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  v_ok      boolean;
  v_kind    text;
  v_rows    integer;
  v_created integer;
  v_items   integer;
BEGIN
  SELECT (b.imported_at = now() AND b.imported_by = app.current_session_user()), b.kind, b.row_count, b.created_count,
         (SELECT count(*) FROM app.import_batch_items x WHERE x.tenant_id = b.tenant_id AND x.batch_id = b.id)
    INTO v_ok, v_kind, v_rows, v_created, v_items
    FROM app.import_batches b WHERE b.tenant_id = NEW.tenant_id AND b.id = NEW.batch_id;
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'import items can only be added to a batch created in this transaction'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF (v_kind = 'assets' AND NEW.target_type <> 'asset') OR (v_kind = 'risks' AND NEW.target_type <> 'risk') THEN
    RAISE EXCEPTION 'import item type does not match the batch kind' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.row_no > v_rows THEN
    RAISE EXCEPTION 'import item row is outside the batch' USING ERRCODE = 'check_violation';
  END IF;
  IF v_items >= v_created THEN
    RAISE EXCEPTION 'import items exceed the created count' USING ERRCODE = 'check_violation';
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

-- At commit, check that the item count equals the created count (do not leave imports that forgot to add items midway).
CREATE FUNCTION app.import_batch_complete() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  n integer;
BEGIN
  SELECT count(*) INTO n FROM app.import_batch_items WHERE tenant_id = NEW.tenant_id AND batch_id = NEW.id;
  IF n <> NEW.created_count THEN
    RAISE EXCEPTION 'import batch items (%) do not match the created count (%)', n, NEW.created_count
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER import_batches_complete AFTER INSERT ON app.import_batches
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION app.import_batch_complete();

-- Who/when (0071's version) plus DB-side counting of undo totals.
-- Retired: rows among this import's items retired in this transaction (xmin is the current transaction). Not applicable: the rest.
CREATE OR REPLACE FUNCTION app.import_log_stamp() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  v_retired integer;
  v_total   integer;
BEGIN
  IF TG_TABLE_NAME = 'import_batches' THEN
    NEW.imported_by := app.current_session_user();
    NEW.imported_at := now();
  ELSIF TG_TABLE_NAME = 'import_undos' THEN
    NEW.undone_by := app.current_session_user();
    NEW.undone_at := now();
    SELECT count(*) FILTER (WHERE s.retired_here), count(*) INTO v_retired, v_total
      FROM (
        SELECT CASE i.target_type
                 WHEN 'asset' THEN EXISTS (
                   SELECT 1 FROM app.assets a
                    WHERE a.tenant_id = i.tenant_id AND a.id = i.target_id
                      AND a.status = 'retired' AND a.xmin = pg_current_xact_id()::xid)
                 ELSE EXISTS (
                   SELECT 1 FROM app.risk_scenarios r
                    WHERE r.tenant_id = i.tenant_id AND r.id = i.target_id
                      AND r.status = 'retired' AND r.xmin = pg_current_xact_id()::xid)
               END AS retired_here
          FROM app.import_batch_items i
         WHERE i.tenant_id = NEW.tenant_id AND i.batch_id = NEW.batch_id
      ) s;
    NEW.retired_count := v_retired;
    NEW.skipped_count := v_total - v_retired;
  END IF;
  RETURN NEW;
END $$;

RESET ROLE;

-- Asset/risk tables are not necessarily owned by schema_owner, so the trigger is attached as superuser (same as 0063's corrective action constraint).
CREATE TRIGGER assets_keep_created_at BEFORE UPDATE ON app.assets
  FOR EACH ROW EXECUTE FUNCTION app.keep_created_at();
CREATE TRIGGER risk_scenarios_keep_created_at BEFORE UPDATE ON app.risk_scenarios
  FOR EACH ROW EXECUTE FUNCTION app.keep_created_at();
