-- @run-as: admin
-- 0064: ISMS の運用記録の第 2 段（設計書 2026-09-11 §5.3 の 2 番目: 情報セキュリティ目的・委託先評価・証跡・例外）。
--
-- 表はすべて既存（0010 / 0011 / 0055）。足すのは、書いてよい役割の種類だけ:
--   objective  情報セキュリティ目的（6.2）の登録と達成の評価 : owner / admin
--   evidence   手作業の証跡の登録                          : owner / admin / manager
--              （統制の運用の記録なので、業務データを書かない監査人には書かせない）
--   exception  指摘の例外の承認（是正せずリスクとして受け入れる）: owner のみ（経営層の判断）
-- 委託先評価は既存の app.require_work_permission('vendor_assessment', …) を使う（作業の割り振りと揃える）。
-- 0063 は書き換えず、関数だけ差し替える（down で 0063 の版へ戻す）。

SET ROLE schema_owner;

CREATE OR REPLACE FUNCTION app.require_records_role(p_kind text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text := app.current_management_role();
  v_allowed text[];
BEGIN
  IF app.current_session_user() IS NULL THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  v_allowed := CASE p_kind
    WHEN 'audit'             THEN ARRAY['owner','admin','auditor']
    WHEN 'corrective'        THEN ARRAY['owner','admin','manager']
    WHEN 'effectiveness'     THEN ARRAY['owner','admin']
    WHEN 'management_review' THEN ARRAY['owner','admin']
    WHEN 'objective'         THEN ARRAY['owner','admin']
    WHEN 'evidence'          THEN ARRAY['owner','admin','manager']
    WHEN 'exception'         THEN ARRAY['owner']
  END;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'unknown record kind: %', p_kind;
  END IF;
  -- 役割が NULL のときも拒否する（0063 と同じ。NULL = ANY は NULL で IF が素通りするため）。
  IF v_role IS NULL OR NOT (v_role = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_role;
END $$;

RESET ROLE;
