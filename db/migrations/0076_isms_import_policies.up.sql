-- @run-as: admin
-- 0076: add policies to the initial data import (§8) (design decision of 2026-09-12; drafts only).
--   One row is one draft version of one policy. With a catalog_key the version is added to that policy; otherwise to the single policy whose title matches.
--   If nothing matches, a new policy is created with version 1. Approval and activation are not part of the import (only the
--   screen paths approve_policy_version / activate_policy_version).
--   Items: the added version (policy_version) and any newly created policy (policy).
--   Undo: only deletes versions that are unapproved, unedited, unreferenced and still the latest; a newly created policy is deleted only once it has no versions
--   (that judgment is made by the Web undo process; the DB counts by whether the row is gone, same as departments).

SET ROLE schema_owner;

ALTER TABLE app.import_batches DROP CONSTRAINT import_batches_kind_check;
ALTER TABLE app.import_batches ADD CONSTRAINT import_batches_kind_check
  CHECK (kind IN ('assets','risks','departments','assignments','policies'));
-- A row that creates a new policy yields 2 items (policy and version), so the item count can exceed the row count.
ALTER TABLE app.import_batches DROP CONSTRAINT import_batches_check;
ALTER TABLE app.import_batches ADD CONSTRAINT import_batches_check
  CHECK (created_count >= 0 AND (kind IN ('assignments','policies') OR created_count <= row_count));

ALTER TABLE app.import_batch_items DROP CONSTRAINT import_batch_items_target_type_check;
ALTER TABLE app.import_batch_items ADD CONSTRAINT import_batch_items_target_type_check
  CHECK (target_type IN ('asset','risk','department','membership','policy','policy_version'));
DROP INDEX app.import_batch_items_created_once;
CREATE UNIQUE INDEX import_batch_items_created_once ON app.import_batch_items (tenant_id, target_type, target_id)
  WHERE target_type IN ('asset','risk','department','policy','policy_version');

-- Item guard (the 0075 version plus policies and versions).
--   Policies: rows created in this transaction (created_at is now; keep_created_at ensures updates cannot change it)
--   Versions: unapproved rows created in this transaction
CREATE OR REPLACE FUNCTION app.import_items_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  v_ok      boolean;
  v_kind    text;
  v_rows    integer;
  v_created integer;
  v_items   integer;
  v_moved   boolean;
  v_first   text;
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
       OR (v_kind = 'assignments' AND NEW.target_type = 'membership')
       OR (v_kind = 'policies' AND NEW.target_type IN ('policy','policy_version'))) THEN
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
  ELSIF NEW.target_type = 'policy' THEN
    SELECT (p.created_at = now()) INTO v_ok FROM app.policies p WHERE p.tenant_id = NEW.tenant_id AND p.id = NEW.target_id;
  ELSIF NEW.target_type = 'policy_version' THEN
    SELECT (v.created_at = now() AND v.approved_at IS NULL) INTO v_ok
      FROM app.policy_versions v WHERE v.tenant_id = NEW.tenant_id AND v.id = NEW.target_id;
  ELSE
    SELECT true, t.old_value INTO v_moved, v_first
      FROM app.row_transitions t
     WHERE t.tenant_id = NEW.tenant_id AND t.target_type = 'membership' AND t.target_id = NEW.target_id
       AND t.xact_id = pg_current_xact_id()
     ORDER BY t.seq LIMIT 1;
    SELECT (m.revoked_at IS NULL AND m.department_id = NEW.new_department_id
            AND CASE WHEN v_moved THEN v_first IS NOT DISTINCT FROM NEW.prev_department_id::text
                     ELSE NEW.prev_department_id IS NOT DISTINCT FROM NEW.new_department_id END)
      INTO v_ok
      FROM app.memberships m WHERE m.tenant_id = NEW.tenant_id AND m.id = NEW.target_id;
    IF v_ok IS NOT TRUE THEN
      RAISE EXCEPTION 'import items must point to memberships assigned in this transaction from the recorded department'
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

-- Who and when, and undo counts (the 0075 version plus policies and versions; for both, rows that no longer exist count as "undone").
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
                    WHERE a.tenant_id = i.tenant_id AND a.id = i.target_id AND a.status = 'retired')
                   AND EXISTS (
                   SELECT 1 FROM app.row_transitions t
                    WHERE t.tenant_id = i.tenant_id AND t.target_type = 'asset' AND t.target_id = i.target_id
                      AND t.xact_id = pg_current_xact_id() AND t.new_value = 'retired')
                 WHEN 'risk' THEN EXISTS (
                   SELECT 1 FROM app.risk_scenarios r
                    WHERE r.tenant_id = i.tenant_id AND r.id = i.target_id AND r.status = 'retired')
                   AND EXISTS (
                   SELECT 1 FROM app.row_transitions t
                    WHERE t.tenant_id = i.tenant_id AND t.target_type = 'risk' AND t.target_id = i.target_id
                      AND t.xact_id = pg_current_xact_id() AND t.new_value = 'retired')
                 WHEN 'department' THEN NOT EXISTS (
                   SELECT 1 FROM app.departments d WHERE d.tenant_id = i.tenant_id AND d.id = i.target_id)
                 WHEN 'policy' THEN NOT EXISTS (
                   SELECT 1 FROM app.policies p WHERE p.tenant_id = i.tenant_id AND p.id = i.target_id)
                 WHEN 'policy_version' THEN NOT EXISTS (
                   SELECT 1 FROM app.policy_versions v WHERE v.tenant_id = i.tenant_id AND v.id = i.target_id)
                 ELSE EXISTS (
                   SELECT 1 FROM app.memberships m
                    WHERE m.tenant_id = i.tenant_id AND m.id = i.target_id
                      AND m.department_id IS NOT DISTINCT FROM i.prev_department_id)
                   AND EXISTS (
                   SELECT 1 FROM app.row_transitions t
                    WHERE t.tenant_id = i.tenant_id AND t.target_type = 'membership' AND t.target_id = i.target_id
                      AND t.xact_id = pg_current_xact_id()
                      AND t.new_value IS NOT DISTINCT FROM i.prev_department_id::text)
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

-- Also prevent updates from changing the creation time of policies and versions (so "created in this transaction" cannot be faked; same as 0072 / 0073).
CREATE TRIGGER policies_keep_created_at BEFORE UPDATE ON app.policies
  FOR EACH ROW EXECUTE FUNCTION app.keep_created_at();
CREATE TRIGGER policy_versions_keep_created_at BEFORE UPDATE ON app.policy_versions
  FOR EACH ROW EXECUTE FUNCTION app.keep_created_at();
