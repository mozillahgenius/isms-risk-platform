-- @run-as: admin
-- 0076: 初期データの取り込み（§8）に規程を足す（2026-09-12 goto-twin 決定。下書きまで）。
--   1 行が 1 つの規程の下書きの版 1 つ。catalog_key があればその規程に、無ければ題名で 1 件だけ一致する規程に版を足す。
--   一致が無ければ規程を新しく作って版 1 を入れる。承認・有効化は取り込みに入れない（approve_policy_version /
--   activate_policy_version の画面の経路だけ）。
--   明細: 足した版（policy_version）と、新しく作った規程（policy）。
--   取り消し: 未承認・未修正・参照が無く、まだ最新の版だけを消し、新しく作った規程は版が無くなったときだけ消す
--   （その判定は Web の取り消し処理。件数は行が無くなったかどうかで DB が数える。部署と同じ）。

SET ROLE schema_owner;

ALTER TABLE app.import_batches DROP CONSTRAINT import_batches_kind_check;
ALTER TABLE app.import_batches ADD CONSTRAINT import_batches_kind_check
  CHECK (kind IN ('assets','risks','departments','assignments','policies'));
-- 規程を新しく作る行は、規程と版の 2 つの明細になるので、明細の数が行数を超えることがある。
ALTER TABLE app.import_batches DROP CONSTRAINT import_batches_check;
ALTER TABLE app.import_batches ADD CONSTRAINT import_batches_check
  CHECK (created_count >= 0 AND (kind IN ('assignments','policies') OR created_count <= row_count));

ALTER TABLE app.import_batch_items DROP CONSTRAINT import_batch_items_target_type_check;
ALTER TABLE app.import_batch_items ADD CONSTRAINT import_batch_items_target_type_check
  CHECK (target_type IN ('asset','risk','department','membership','policy','policy_version'));
DROP INDEX app.import_batch_items_created_once;
CREATE UNIQUE INDEX import_batch_items_created_once ON app.import_batch_items (tenant_id, target_type, target_id)
  WHERE target_type IN ('asset','risk','department','policy','policy_version');

-- 明細の守り（0075 の版に、規程と版を足した）。
--   規程: このトランザクションで作った行（created_at が今。更新で変えられないのは keep_created_at が守る）
--   版:   このトランザクションで作った、未承認の行
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

-- 誰がいつ・取り消しの件数（0075 の版に、規程と版を足した。どちらも行が無くなったものを「取り消した」）。
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

-- 規程と版の作成日時も更新で変えさせない（「このトランザクションで作った」の判定を偽らせない。0072 / 0073 と同じ）。
CREATE TRIGGER policies_keep_created_at BEFORE UPDATE ON app.policies
  FOR EACH ROW EXECUTE FUNCTION app.keep_created_at();
CREATE TRIGGER policy_versions_keep_created_at BEFORE UPDATE ON app.policy_versions
  FOR EACH ROW EXECUTE FUNCTION app.keep_created_at();
