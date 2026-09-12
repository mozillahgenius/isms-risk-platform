-- @run-as: admin
-- 0074: Make undo counting not miss changes made inside savepoints (Codex review 2026-09-12).
--
-- 0072 / 0073 identified "rows retired (reverted) in this transaction" by xmin = pg_current_xact_id().
-- The xmin of a row updated inside a savepoint is the subtransaction ID, which does not match the top-level ID, so
-- rows actually retired were counted as "not applicable". Rows whose update time (updated_at) is now (the transaction start time) are also
-- counted as "changed in this transaction" (the undo process writes updated_at = now()).
-- Departments are counted by whether the row disappeared, so they are unchanged.

SET ROLE schema_owner;

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

RESET ROLE;
