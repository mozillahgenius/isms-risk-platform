-- @run-as: admin
-- Rollback of 0075. Removes the transition records and restores the item guard to 0073's version and undo counting to 0074's.
--
-- Roll back even if transition records remain. The guard and counting read only rows of "the current transaction"; past rows are not used for decisions
-- (the import records themselves = import_batches / items / undos are protected by the downs of 0071 and 0073).
-- A row is created on every asset retirement or department change, so rejecting when rows exist would make a DB in normal use impossible to roll back.
SET LOCAL lock_timeout = '10s';

DROP TRIGGER IF EXISTS assets_status_transition ON app.assets;
DROP TRIGGER IF EXISTS risk_scenarios_status_transition ON app.risk_scenarios;
DROP TRIGGER IF EXISTS memberships_department_transition ON app.memberships;

SET ROLE schema_owner;

-- Restore 0073's version.
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
  IF NOT ((v_kind = 'assets' AND NEW.target_type = 'asset') OR (v_kind = 'risks' AND NEW.target_type = 'risk')
       OR (v_kind = 'departments' AND NEW.target_type = 'department')
       OR (v_kind = 'assignments' AND NEW.target_type = 'membership')) THEN
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
  ELSIF NEW.target_type = 'risk' THEN
    SELECT (r.created_at = now()) INTO v_ok FROM app.risk_scenarios r WHERE r.tenant_id = NEW.tenant_id AND r.id = NEW.target_id;
  ELSIF NEW.target_type = 'department' THEN
    SELECT (d.created_at = now()) INTO v_ok FROM app.departments d WHERE d.tenant_id = NEW.tenant_id AND d.id = NEW.target_id;
  ELSE
    SELECT (m.xmin = pg_current_xact_id()::xid AND m.revoked_at IS NULL AND m.department_id = NEW.new_department_id) INTO v_ok
      FROM app.memberships m WHERE m.tenant_id = NEW.tenant_id AND m.id = NEW.target_id;
    IF v_ok IS NOT TRUE THEN
      RAISE EXCEPTION 'import items must point to memberships assigned in this transaction'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
  END IF;
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'import items must point to rows created in this transaction'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;

-- Restore 0074's version.
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
    SELECT count(*) FILTER (WHERE s.done_here), count(*) INTO v_retired, v_total
      FROM (
        SELECT CASE i.target_type
                 WHEN 'asset' THEN EXISTS (
                   SELECT 1 FROM app.assets a
                    WHERE a.tenant_id = i.tenant_id AND a.id = i.target_id AND a.status = 'retired'
                      AND (a.xmin = pg_current_xact_id()::xid OR a.updated_at = now()))
                 WHEN 'risk' THEN EXISTS (
                   SELECT 1 FROM app.risk_scenarios r
                    WHERE r.tenant_id = i.tenant_id AND r.id = i.target_id AND r.status = 'retired'
                      AND (r.xmin = pg_current_xact_id()::xid OR r.updated_at = now()))
                 WHEN 'department' THEN NOT EXISTS (
                   SELECT 1 FROM app.departments d WHERE d.tenant_id = i.tenant_id AND d.id = i.target_id)
                 ELSE EXISTS (
                   SELECT 1 FROM app.memberships m
                    WHERE m.tenant_id = i.tenant_id AND m.id = i.target_id
                      AND m.department_id IS NOT DISTINCT FROM i.prev_department_id
                      AND (m.xmin = pg_current_xact_id()::xid OR m.updated_at = now()))
               END AS done_here
          FROM app.import_batch_items i
         WHERE i.tenant_id = NEW.tenant_id AND i.batch_id = NEW.batch_id
      ) s;
    NEW.retired_count := v_retired;
    NEW.skipped_count := v_total - v_retired;
  END IF;
  RETURN NEW;
END $$;

DROP FUNCTION IF EXISTS app.record_row_transition();
DROP TABLE IF EXISTS app.row_transitions;

RESET ROLE;
