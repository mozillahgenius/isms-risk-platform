-- @run-as: admin
-- 0074: 取り消しの件数の数え方を、セーブポイントの中の変更でも取りこぼさないようにする（Codex レビュー 2026-09-12）。
--
-- 0072 / 0073 は「このトランザクションで退役にした（戻した）行」を xmin = pg_current_xact_id() で見分けていた。
-- セーブポイントの中で更新した行の xmin はサブトランザクションの ID になり、トップの ID と一致しないので、
-- 実際に退役にしていても「対象外」と数えていた。更新の日時（updated_at）が今（トランザクションの開始時刻）であることも
-- 「このトランザクションで変えた」として数える（取り消しの処理は updated_at = now() を書く）。
-- 部署は行が消えたかどうかで数えるので変わらない。

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
