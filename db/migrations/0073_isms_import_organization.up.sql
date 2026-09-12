-- @run-as: admin
-- 0073: add organization to the initial data import (§8) (design decision of 2026-09-12).
--   Departments: distinguished from existing ones by name (a collision is an error); the parent is referenced by name.
--     Created rows can be removed by undo (only those unreferenced and not edited after the import; that judgment is made by the Web undo process).
--   Assignments: put the same department on every non-revoked membership row of an existing user. Roles are not written.
--     Each row keeps its original and assigned department, and undo restores the original (only rows still on the assigned department).
-- Write permissions are left to the existing DB restrictions (departments: org_manage in guard_org_department; memberships:
-- member_manage in guard_org_membership; the top executive's row: role_manage). All this adds is letting import records handle organization.

SET ROLE schema_owner;

-- Widen the import kinds and item target types.
ALTER TABLE app.import_batches DROP CONSTRAINT import_batches_kind_check;
ALTER TABLE app.import_batches ADD CONSTRAINT import_batches_kind_check
  CHECK (kind IN ('assets','risks','departments','assignments'));
-- For assignments one person (one row) can have several membership rows, so the item count (created/edited) can exceed the row count.
ALTER TABLE app.import_batches DROP CONSTRAINT import_batches_check;
ALTER TABLE app.import_batches ADD CONSTRAINT import_batches_check
  CHECK (created_count >= 0 AND (kind = 'assignments' OR created_count <= row_count));

ALTER TABLE app.import_batch_items DROP CONSTRAINT import_batch_items_target_type_check;
ALTER TABLE app.import_batch_items ADD CONSTRAINT import_batch_items_target_type_check
  CHECK (target_type IN ('asset','risk','department','membership'));
-- Only membership items carry the original department (restored by undo) and the assigned department.
ALTER TABLE app.import_batch_items ADD COLUMN prev_department_id uuid;
ALTER TABLE app.import_batch_items ADD COLUMN new_department_id uuid;
ALTER TABLE app.import_batch_items ADD CONSTRAINT import_batch_items_membership_values CHECK (
  ((target_type = 'membership') = (new_department_id IS NOT NULL))
  AND (target_type = 'membership' OR prev_department_id IS NULL)
);
-- One CSV row can become several membership rows, so the target is part of the primary key.
ALTER TABLE app.import_batch_items DROP CONSTRAINT import_batch_items_pkey;
ALTER TABLE app.import_batch_items ADD PRIMARY KEY (tenant_id, batch_id, row_no, target_type, target_id);
-- "A row is created by only one import" applies only to created rows (assets, risks, departments).
-- For assignments, the same person can be reassigned by a later import.
ALTER TABLE app.import_batch_items DROP CONSTRAINT import_batch_items_tenant_id_target_type_target_id_key;
CREATE UNIQUE INDEX import_batch_items_created_once ON app.import_batch_items (tenant_id, target_type, target_id)
  WHERE target_type IN ('asset','risk','department');

-- Item guard (the 0072 version plus departments and memberships).
--   Departments: rows created in this transaction (created_at is now; keep_created_at ensures updates cannot change it)
--   Memberships: non-revoked rows changed in this transaction to the department written on the item (xmin is the current transaction)
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

-- Who and when, and undo counts (the 0072 version plus departments and memberships).
--   Departments: rows that no longer exist (deleted) count as "undone"
--   Memberships: rows restored to their original department in this transaction count as "undone"
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
                    WHERE a.tenant_id = i.tenant_id AND a.id = i.target_id
                      AND a.status = 'retired' AND a.xmin = pg_current_xact_id()::xid)
                 WHEN 'risk' THEN EXISTS (
                   SELECT 1 FROM app.risk_scenarios r
                    WHERE r.tenant_id = i.tenant_id AND r.id = i.target_id
                      AND r.status = 'retired' AND r.xmin = pg_current_xact_id()::xid)
                 WHEN 'department' THEN NOT EXISTS (
                   SELECT 1 FROM app.departments d WHERE d.tenant_id = i.tenant_id AND d.id = i.target_id)
                 ELSE EXISTS (
                   SELECT 1 FROM app.memberships m
                    WHERE m.tenant_id = i.tenant_id AND m.id = i.target_id
                      AND m.department_id IS NOT DISTINCT FROM i.prev_department_id
                      AND m.xmin = pg_current_xact_id()::xid)
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

-- Also prevent updates from changing a department's creation time (so "department created in this transaction" cannot be faked; same as 0072).
CREATE TRIGGER departments_keep_created_at BEFORE UPDATE ON app.departments
  FOR EACH ROW EXECUTE FUNCTION app.keep_created_at();
