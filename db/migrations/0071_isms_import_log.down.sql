-- @run-as: admin
-- 0071 の巻き戻し。取り込みの記録の表・トリガを外し、許可の表を 0070 の版へ戻す。
-- 取り込みで作った資産・リスクそのものは消さない（台帳の行で、取り込みの記録ではない）。
--
-- **記録があるときは巻き戻さない**（0055 と同じ。取り込みの監査の記録を down で黙って消さない）。
-- guard は SET ROLE の前に置き、表ごとに、在るときだけ SHARE ロックを取って数える（0065 の down と同じ）。
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE
  n integer;
  t text;
BEGIN
  -- 親（import_batches）から順にロックする。取り込み側は親を INSERT してから明細を INSERT するので、
  -- 子から取ると相互待ちになる（Codex レビュー 2026-09-12）。取る順番をそろえる。
  FOREACH t IN ARRAY ARRAY['import_batches','import_batch_items','import_undos'] LOOP
    IF to_regclass('app.' || t) IS NOT NULL THEN
      EXECUTE format('LOCK TABLE app.%I IN SHARE MODE', t);
      EXECUTE format('SELECT count(*) FROM app.%I', t) INTO n;
      IF n > 0 THEN
        RAISE EXCEPTION '0071 rollback refused: import records would be lost (% rows in %)', n, t;
      END IF;
    END IF;
  END LOOP;
END $$;

SET ROLE schema_owner;

-- 表を消すと、張ってあるポリシー・トリガ・索引も一緒に消える。
DROP TABLE IF EXISTS app.import_undos;
DROP TABLE IF EXISTS app.import_batch_items;
DROP TABLE IF EXISTS app.import_batches;
DROP FUNCTION IF EXISTS app.import_items_guard();
DROP FUNCTION IF EXISTS app.import_log_stamp();

CREATE OR REPLACE FUNCTION app.records_role_allows(p_kind text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text;
  v_allowed text[];
BEGIN
  v_allowed := CASE p_kind
    WHEN 'audit'             THEN ARRAY['owner','admin','auditor']
    WHEN 'corrective'        THEN ARRAY['owner','admin','manager']
    WHEN 'effectiveness'     THEN ARRAY['owner','admin']
    WHEN 'management_review' THEN ARRAY['owner','admin']
    WHEN 'objective'         THEN ARRAY['owner','admin']
    WHEN 'evidence'          THEN ARRAY['owner','admin','manager']
    WHEN 'exception'         THEN ARRAY['owner']
    WHEN 'context'           THEN ARRAY['owner','admin']
    WHEN 'legal'             THEN ARRAY['owner','admin','manager']
    WHEN 'continuity'        THEN ARRAY['owner','admin','manager']
    WHEN 'vulnerability'     THEN ARRAY['owner','admin','manager']
    WHEN 'change'            THEN ARRAY['owner','admin','manager','member']
  END;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'unknown record kind: %', p_kind;
  END IF;
  IF app.current_session_user() IS NULL THEN
    RETURN false;
  END IF;
  v_role := app.current_management_role();
  RETURN v_role IS NOT NULL AND v_role = ANY (v_allowed);
END $$;

RESET ROLE;
