-- @run-as: admin
-- 0075: 取り込みの「元の部署」と取り消しの件数を、DB が実際に見た変化から決める（Codex レビュー 2026-09-12 r11）。
--
-- 0073 は所属の明細の元の部署（prev_department_id）を書き手の申告のまま受けていた（A→B と直してから元を C と書ける。
-- 取り消しで C へ戻すと元のデータを壊す）。0074 は取り消しの件数を updated_at = now() でも数え、既に退役していた行を
-- 同じトランザクションで別の欄だけ直すと「退役にした」と数えていた。どちらも「このトランザクションで何が何から何へ
-- 変わったか」を DB が知らないのが原因。
--
-- row_transitions: 資産・リスクの状態、所属の部署が変わるたびに、トリガが「どのトランザクションで・何から・何へ」を 1 行残す。
--   書くのはトリガの関数（schema_owner 所有・SECURITY DEFINER）だけで、app_rw には読むことしか渡さない（偽の変化を書かせない）。
--   トランザクションの ID は pg_current_xact_id()（セーブポイントの中でもトップの ID）。
--   テナントの文脈が無い変更（保守・同期の処理）は残さない（取り込みはいつもテナントの文脈で書く。残らなければ明細は拒否になる）。
-- 明細の守り: 所属は「このトランザクションで最初に変わる前の部署」が元の部署と一致し、今の部署が入れた部署であること。
--   このトランザクションで変わっていない（もともと入れる部署だった）行は、元の部署 = 入れた部署 = 今の部署のときだけ受ける。
-- 取り消しの件数: 資産・リスクはこのトランザクションで退役に変わった行、所属はこのトランザクションで元の部署へ変わり
--   今も元の部署の行、部署は行が無くなったもの（0073 と同じ）。

SET ROLE schema_owner;

CREATE TABLE app.row_transitions (
  tenant_id    uuid NOT NULL,
  seq          bigint GENERATED ALWAYS AS IDENTITY,
  xact_id      xid8 NOT NULL,
  target_type  text NOT NULL CHECK (target_type IN ('asset','risk','membership')),
  target_id    uuid NOT NULL,
  old_value    text,
  new_value    text,
  changed_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, seq)
);
CREATE INDEX row_transitions_target ON app.row_transitions (tenant_id, target_type, target_id, xact_id, seq);

CREATE FUNCTION app.record_row_transition() RETURNS trigger
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
REVOKE ALL ON FUNCTION app.record_row_transition() FROM PUBLIC;

ALTER TABLE app.row_transitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.row_transitions FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.row_transitions FOR ALL TO app_rw
  USING (tenant_id = app.current_tenant()) WITH CHECK (tenant_id = app.current_tenant());
CREATE POLICY tenant_read ON app.row_transitions FOR SELECT TO app_ro USING (tenant_id = app.current_tenant());
-- トリガの関数（schema_owner）が書くための口（0062 と同じ書き方。文脈が無いと何も書けない）。
CREATE POLICY tenant_security_definer ON app.row_transitions FOR ALL TO schema_owner
  USING (tenant_id = (SELECT app.current_tenant_or_null())) WITH CHECK (tenant_id = (SELECT app.current_tenant_or_null()));
REVOKE ALL ON app.row_transitions FROM PUBLIC;
GRANT SELECT ON app.row_transitions TO app_ro, app_rw;

-- 明細の守り（0073 の版の所属の判定を、変化の記録で決めるようにした。他は同じ）。
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

-- 誰がいつ・取り消しの件数（0074 の版の数え方を、変化の記録で決めるようにした）。
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

-- 変わったときだけ残す（同じ値への更新は変化ではない）。
CREATE TRIGGER assets_status_transition AFTER UPDATE ON app.assets
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION app.record_row_transition();
CREATE TRIGGER risk_scenarios_status_transition AFTER UPDATE ON app.risk_scenarios
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION app.record_row_transition();
CREATE TRIGGER memberships_department_transition AFTER UPDATE ON app.memberships
  FOR EACH ROW WHEN (OLD.department_id IS DISTINCT FROM NEW.department_id) EXECUTE FUNCTION app.record_row_transition();

COMMENT ON TABLE app.row_transitions IS
  '資産・リスクの状態と所属の部署の変化（どのトランザクションで・何から・何へ）。トリガだけが書く。取り込みの明細の元の部署と取り消しの件数の根拠。';
