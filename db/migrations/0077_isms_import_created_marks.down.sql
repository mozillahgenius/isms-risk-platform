-- @run-as: admin
-- Rollback of 0077. Stop recording created rows; restore the transition-record function to 0075's version and the detail guard to 0076's version.
-- Created-row records are judged using only rows of the current transaction, so delete them before restoring constraints (same idea as 0075's down).
SET LOCAL lock_timeout = '10s';

DROP TRIGGER IF EXISTS assets_created_transition ON app.assets;
DROP TRIGGER IF EXISTS risk_scenarios_created_transition ON app.risk_scenarios;
DROP TRIGGER IF EXISTS departments_created_transition ON app.departments;
DROP TRIGGER IF EXISTS policies_created_transition ON app.policies;
DROP TRIGGER IF EXISTS policy_versions_created_transition ON app.policy_versions;

DELETE FROM app.row_transitions
 WHERE target_type IN ('department','policy','policy_version') OR (old_value IS NULL AND new_value = 'created');

SET ROLE schema_owner;

ALTER TABLE app.row_transitions DROP CONSTRAINT row_transitions_target_type_check;
ALTER TABLE app.row_transitions ADD CONSTRAINT row_transitions_target_type_check
  CHECK (target_type IN ('asset','risk','membership'));

-- Restore to 0075's version.
CREATE OR REPLACE FUNCTION app.record_row_transition() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_type text;
  v_old  text;
  v_new  text;
BEGIN
  IF app.current_tenant_or_null() IS DISTINCT FROM NEW.tenant_id THEN
    RETURN NULL;
  END IF;
  IF TG_TABLE_NAME = 'memberships' THEN
    v_type := 'membership';
    v_old := OLD.department_id::text;
    v_new := NEW.department_id::text;
  ELSE
    v_type := CASE TG_TABLE_NAME WHEN 'assets' THEN 'asset' ELSE 'risk' END;
    v_old := OLD.status::text;
    v_new := NEW.status::text;
  END IF;
  INSERT INTO app.row_transitions (tenant_id, xact_id, target_type, target_id, old_value, new_value)
  VALUES (NEW.tenant_id, pg_current_xact_id(), v_type, NEW.id, v_old, v_new);
  RETURN NULL;
END $$;

-- Restore to 0076's version.
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

RESET ROLE;
