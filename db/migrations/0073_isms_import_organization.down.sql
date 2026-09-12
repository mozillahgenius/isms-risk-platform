-- @run-as: admin
-- Rollback of 0073. Restores import records to 0072's shape (assets and risks only).
--
-- **Do not roll back when organization import records exist** (restoring the constraint would make those rows violate it, and
-- down would silently delete the import audit records). Lock from the parent down (same order as the import side; same as 0071's down).
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  LOCK TABLE app.import_batches IN SHARE MODE;
  LOCK TABLE app.import_batch_items IN SHARE MODE;
  SELECT (SELECT count(*) FROM app.import_batches WHERE kind IN ('departments','assignments'))
       + (SELECT count(*) FROM app.import_batch_items WHERE target_type IN ('department','membership')) INTO n;
  IF n > 0 THEN
    RAISE EXCEPTION '0073 rollback refused: organization import records remain (% rows)', n;
  END IF;
END $$;

DROP TRIGGER IF EXISTS departments_keep_created_at ON app.departments;

SET ROLE schema_owner;

DROP INDEX IF EXISTS app.import_batch_items_created_once;
ALTER TABLE app.import_batch_items ADD CONSTRAINT import_batch_items_tenant_id_target_type_target_id_key
  UNIQUE (tenant_id, target_type, target_id);
ALTER TABLE app.import_batch_items DROP CONSTRAINT import_batch_items_pkey;
ALTER TABLE app.import_batch_items ADD CONSTRAINT import_batch_items_pkey PRIMARY KEY (tenant_id, batch_id, row_no);
ALTER TABLE app.import_batch_items DROP CONSTRAINT import_batch_items_membership_values;
ALTER TABLE app.import_batch_items DROP COLUMN new_department_id;
ALTER TABLE app.import_batch_items DROP COLUMN prev_department_id;
ALTER TABLE app.import_batch_items DROP CONSTRAINT import_batch_items_target_type_check;
ALTER TABLE app.import_batch_items ADD CONSTRAINT import_batch_items_target_type_check
  CHECK (target_type IN ('asset','risk'));
ALTER TABLE app.import_batches DROP CONSTRAINT import_batches_check;
ALTER TABLE app.import_batches ADD CONSTRAINT import_batches_check
  CHECK (created_count >= 0 AND created_count <= row_count);
ALTER TABLE app.import_batches DROP CONSTRAINT import_batches_kind_check;
ALTER TABLE app.import_batches ADD CONSTRAINT import_batches_kind_check CHECK (kind IN ('assets','risks'));

-- Restore 0072's version.
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
