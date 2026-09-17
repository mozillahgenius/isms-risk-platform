-- @run-as: admin
-- 0070 の巻き戻し。変更の申請の表・判断の関数・遷移のトリガを外し、許可の表を 0069 の版へ戻す。
-- app.approvals に残った承認の記録は消さない（監査の記録を後から書き換えない。0063 と同じ）。
--
-- **データがあるときは巻き戻さない**（0055 と同じ。A.8.32 の記録を down で黙って消さない）。
-- guard は SET ROLE の前に置き、表が在るときだけ SHARE ロックを取って数える（0065 の down と同じ）。
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  -- 承認の記録を先にロックする。判断の関数は申請（FOR UPDATE）→ 承認の記録（INSERT）の順に触るので、
  -- こちらが申請 → 承認の記録の順だと相互待ちになる（Codex レビュー 2026-09-12）。取る順番をそろえる。
  LOCK TABLE app.approvals IN SHARE MODE;
  IF to_regclass('app.change_requests') IS NOT NULL THEN
    LOCK TABLE app.change_requests IN SHARE MODE;
    SELECT count(*) INTO n FROM app.change_requests;
    IF n > 0 THEN
      RAISE EXCEPTION '0070 rollback refused: change requests would be lost (% rows)', n;
    END IF;
  END IF;
  -- 承認の記録（change_request）が残っているときも戻さない。戻して作り直すと、古い承認が同じ ID の申請に結び付く。
  SELECT count(*) INTO n FROM app.approvals WHERE target_type = 'change_request';
  IF n > 0 THEN
    RAISE EXCEPTION '0070 rollback refused: change request approvals remain (% rows)', n;
  END IF;
END $$;

SET ROLE schema_owner;

DROP FUNCTION IF EXISTS app.decide_change_request(uuid, boolean, text);
-- 表を消すと、張ってあるポリシー・トリガ・索引も一緒に消える。
DROP TABLE IF EXISTS app.change_requests;
DROP FUNCTION IF EXISTS app.change_requests_guard();

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
