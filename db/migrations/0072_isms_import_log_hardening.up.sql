-- @run-as: admin
-- 0072: 取り込みの記録（0071）を固める（Codex レビュー 2026-09-12）。
--   1. 資産・リスクの created_at を更新で変えさせない。0071 の明細の守りは「created_at が今（このトランザクション）」で
--      「このトランザクションで作った行」を見分けるので、app_rw が既存行の created_at を今に書き換えると、前からある行を
--      取り込みの明細に付けて、取り消しで退役させられた。
--   2. 明細と取り込みの記録の整合: 種類と対象の一致（資産の取り込みにリスクを付けない）・行番号は行数以内・
--      明細の数は作った件数と同じ（コミットの時に確かめる）。
--   3. 取り消しの件数は DB が数える（書かれた値を信じない）。このトランザクションで退役にした行を「退役」、残りを「対象外」。

SET ROLE schema_owner;

CREATE FUNCTION app.keep_created_at() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  -- 作った日時は作った時のもの。更新では変えない（黙って元に戻す）。
  NEW.created_at := OLD.created_at;
  RETURN NEW;
END $$;

-- 明細の守り（0071 の版に、種類の一致・行番号の範囲・件数の上限を足した）。
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
  IF (v_kind = 'assets' AND NEW.target_type <> 'asset') OR (v_kind = 'risks' AND NEW.target_type <> 'risk') THEN
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
  ELSE
    SELECT (r.created_at = now()) INTO v_ok FROM app.risk_scenarios r WHERE r.tenant_id = NEW.tenant_id AND r.id = NEW.target_id;
  END IF;
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'import items must point to rows created in this transaction'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;

-- コミットの時に、明細の数が作った件数と同じか確かめる（途中で明細を足し忘れた取り込みを残さない）。
CREATE FUNCTION app.import_batch_complete() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  n integer;
BEGIN
  SELECT count(*) INTO n FROM app.import_batch_items WHERE tenant_id = NEW.tenant_id AND batch_id = NEW.id;
  IF n <> NEW.created_count THEN
    RAISE EXCEPTION 'import batch items (%) do not match the created count (%)', n, NEW.created_count
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER import_batches_complete AFTER INSERT ON app.import_batches
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION app.import_batch_complete();

-- 誰がいつ（0071 の版）に、取り消しの件数を DB が数える処理を足した。
-- 退役: この取り込みの明細の行のうち、このトランザクションで退役にした行（xmin が今のトランザクション）。対象外: 残り。
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
    SELECT count(*) FILTER (WHERE s.retired_here), count(*) INTO v_retired, v_total
      FROM (
        SELECT CASE i.target_type
                 WHEN 'asset' THEN EXISTS (
                   SELECT 1 FROM app.assets a
                    WHERE a.tenant_id = i.tenant_id AND a.id = i.target_id
                      AND a.status = 'retired' AND a.xmin = pg_current_xact_id()::xid)
                 ELSE EXISTS (
                   SELECT 1 FROM app.risk_scenarios r
                    WHERE r.tenant_id = i.tenant_id AND r.id = i.target_id
                      AND r.status = 'retired' AND r.xmin = pg_current_xact_id()::xid)
               END AS retired_here
          FROM app.import_batch_items i
         WHERE i.tenant_id = NEW.tenant_id AND i.batch_id = NEW.batch_id
      ) s;
    NEW.retired_count := v_retired;
    NEW.skipped_count := v_total - v_retired;
  END IF;
  RETURN NEW;
END $$;

RESET ROLE;

-- 資産・リスクの表は schema_owner の持ち物とは限らないので、トリガは superuser のまま付ける（0063 の是正処置の制約と同じ）。
CREATE TRIGGER assets_keep_created_at BEFORE UPDATE ON app.assets
  FOR EACH ROW EXECUTE FUNCTION app.keep_created_at();
CREATE TRIGGER risk_scenarios_keep_created_at BEFORE UPDATE ON app.risk_scenarios
  FOR EACH ROW EXECUTE FUNCTION app.keep_created_at();
