-- @run-as: admin
-- 0073: 初期データの取り込み（§8）に組織を足す（2026-09-12 goto-twin 決定）。
--   部署（departments）: 名前で既存と見分け（重なれば誤り）、上位は名前で指す。作った行は取り消しで消せる
--     （参照されておらず、取り込み後に直されていないものだけ。その判定は Web の取り消し処理）。
--   所属の割り当て（assignments）: 既にいる利用者の、失効していない所属の行すべてに同じ部署を入れる。役割は書かない。
--     行ごとに元の部署と入れた部署を残し、取り消しで元へ戻す（今も入れた部署のままの行だけ）。
-- 書き込みの権限は既存の DB の縛りに任せる（部署は guard_org_department の org_manage、所属は guard_org_membership の
-- member_manage。最高責任者の行は role_manage）。ここで足すのは取り込みの記録が組織を扱えるようにすることだけ。

SET ROLE schema_owner;

-- 取り込みの種類と明細の対象を広げる。
ALTER TABLE app.import_batches DROP CONSTRAINT import_batches_kind_check;
ALTER TABLE app.import_batches ADD CONSTRAINT import_batches_kind_check
  CHECK (kind IN ('assets','risks','departments','assignments'));
-- 割り当ては 1 人（1 行）が複数の所属の行を持てるので、明細の数（作った・直した件数）が行数を超えることがある。
ALTER TABLE app.import_batches DROP CONSTRAINT import_batches_check;
ALTER TABLE app.import_batches ADD CONSTRAINT import_batches_check
  CHECK (created_count >= 0 AND (kind = 'assignments' OR created_count <= row_count));

ALTER TABLE app.import_batch_items DROP CONSTRAINT import_batch_items_target_type_check;
ALTER TABLE app.import_batch_items ADD CONSTRAINT import_batch_items_target_type_check
  CHECK (target_type IN ('asset','risk','department','membership'));
-- 所属の明細だけが、元の部署（取り消しで戻す先）と入れた部署を持つ。
ALTER TABLE app.import_batch_items ADD COLUMN prev_department_id uuid;
ALTER TABLE app.import_batch_items ADD COLUMN new_department_id uuid;
ALTER TABLE app.import_batch_items ADD CONSTRAINT import_batch_items_membership_values CHECK (
  ((target_type = 'membership') = (new_department_id IS NOT NULL))
  AND (target_type = 'membership' OR prev_department_id IS NULL)
);
-- 1 つの CSV の行が複数の所属の行になるので、主キーに対象を含める。
ALTER TABLE app.import_batch_items DROP CONSTRAINT import_batch_items_pkey;
ALTER TABLE app.import_batch_items ADD PRIMARY KEY (tenant_id, batch_id, row_no, target_type, target_id);
-- 「1 つの行は 1 回の取り込みでしか作られない」は、作った行（資産・リスク・部署）にだけ掛ける。
-- 所属の割り当ては、同じ人を後の取り込みでもう一度割り当て直せる。
ALTER TABLE app.import_batch_items DROP CONSTRAINT import_batch_items_tenant_id_target_type_target_id_key;
CREATE UNIQUE INDEX import_batch_items_created_once ON app.import_batch_items (tenant_id, target_type, target_id)
  WHERE target_type IN ('asset','risk','department');

-- 明細の守り（0072 の版に、部署と所属を足した）。
--   部署: このトランザクションで作った行（created_at が今。更新で変えられないのは keep_created_at が守る）
--   所属: このトランザクションで、明細に書いた部署へ直した、失効していない行（xmin が今のトランザクション）
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

-- 誰がいつ・取り消しの件数（0072 の版に、部署と所属を足した）。
--   部署: 行がもう無い（消した）ものを「取り消した」
--   所属: このトランザクションで、元の部署へ戻した行を「取り消した」
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

-- 部署の作成日時も更新で変えさせない（「このトランザクションで作った部署」の判定を偽らせない。0072 と同じ）。
CREATE TRIGGER departments_keep_created_at BEFORE UPDATE ON app.departments
  FOR EACH ROW EXECUTE FUNCTION app.keep_created_at();
