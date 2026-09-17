-- @run-as: admin
-- 0077: 取り込みの明細の「このトランザクションで作った行」を、作成日時ではなくトランザクションの ID で見分ける
-- （Codex レビュー 2026-09-12）。
--
-- 0071〜0076 は created_at = now() で見分けていた。now() はトランザクションの開始時刻なので、同じマイクロ秒に始まった
-- 別のトランザクションが作った行も「今作った」に見え、その行を自分の取り込みの明細に付けて、取り消しで退役・削除させられる。
-- 0075 の変化の記録（row_transitions。トリガだけが書く）に「作った」を足し、明細の守りはそれを見る。
-- トランザクションの ID は pg_current_xact_id()（セーブポイントの中でもトップの ID）なので、開始時刻が重なっても混ざらない。

SET ROLE schema_owner;

ALTER TABLE app.row_transitions DROP CONSTRAINT row_transitions_target_type_check;
ALTER TABLE app.row_transitions ADD CONSTRAINT row_transitions_target_type_check
  CHECK (target_type IN ('asset','risk','membership','department','policy','policy_version'));

-- 0075 の版に、作った行の記録を足した（INSERT のときは old = NULL・new = 'created'）。
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
  IF TG_OP = 'INSERT' THEN
    v_type := CASE TG_TABLE_NAME
                WHEN 'assets' THEN 'asset' WHEN 'risk_scenarios' THEN 'risk' WHEN 'departments' THEN 'department'
                WHEN 'policies' THEN 'policy' WHEN 'policy_versions' THEN 'policy_version' END;
    v_old := NULL;
    v_new := 'created';
  ELSIF TG_TABLE_NAME = 'memberships' THEN
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

-- 明細の守り（0076 の版の「作った行」の判定を、変化の記録の「このトランザクションで作った」に替えた。他は同じ）。
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
  IF NEW.target_type = 'membership' THEN
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
  -- 作った行: このトランザクションで「作った」が記録されている（トリガだけが書く）。版はさらに未承認であること。
  v_ok := EXISTS (SELECT 1 FROM app.row_transitions t
                   WHERE t.tenant_id = NEW.tenant_id AND t.target_type = NEW.target_type AND t.target_id = NEW.target_id
                     AND t.xact_id = pg_current_xact_id() AND t.old_value IS NULL AND t.new_value = 'created');
  IF v_ok AND NEW.target_type = 'policy_version' THEN
    SELECT (v.approved_at IS NULL) INTO v_ok
      FROM app.policy_versions v WHERE v.tenant_id = NEW.tenant_id AND v.id = NEW.target_id;
  END IF;
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'import items must point to rows created in this transaction'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;

RESET ROLE;

-- 作ったときにも記録する（AFTER INSERT の行トリガ）。資産・リスクの状態、所属の部署の変化は 0075 のトリガのまま。
CREATE TRIGGER assets_created_transition AFTER INSERT ON app.assets
  FOR EACH ROW EXECUTE FUNCTION app.record_row_transition();
CREATE TRIGGER risk_scenarios_created_transition AFTER INSERT ON app.risk_scenarios
  FOR EACH ROW EXECUTE FUNCTION app.record_row_transition();
CREATE TRIGGER departments_created_transition AFTER INSERT ON app.departments
  FOR EACH ROW EXECUTE FUNCTION app.record_row_transition();
CREATE TRIGGER policies_created_transition AFTER INSERT ON app.policies
  FOR EACH ROW EXECUTE FUNCTION app.record_row_transition();
CREATE TRIGGER policy_versions_created_transition AFTER INSERT ON app.policy_versions
  FOR EACH ROW EXECUTE FUNCTION app.record_row_transition();
