-- @run-as: admin
-- 0065 の巻き戻し。組織の課題・利害関係者の表を外し、役割の種類を 0064 の版へ戻す。
--
-- **データがあるときは巻き戻さない**（0055 と同じ。4.1 / 4.2 の決定を down で黙って消さない）。
-- guard は SET ROLE の前に置き、数える前に SHARE ロックを取る（理由は 0055 の down を参照）。
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  -- 表ごとに、在るときだけロックして数える（片方だけ無い・途中まで戻った状態でも DROP ... IF EXISTS へ進める）。
  IF to_regclass('app.context_issues') IS NOT NULL THEN
    LOCK TABLE app.context_issues IN SHARE MODE;
    SELECT count(*) INTO n FROM app.context_issues;
    IF n > 0 THEN
      RAISE EXCEPTION '0065 rollback refused: context issues would be lost (% rows)', n;
    END IF;
  END IF;
  IF to_regclass('app.interested_parties') IS NOT NULL THEN
    LOCK TABLE app.interested_parties IN SHARE MODE;
    SELECT count(*) INTO n FROM app.interested_parties;
    IF n > 0 THEN
      RAISE EXCEPTION '0065 rollback refused: interested parties would be lost (% rows)', n;
    END IF;
  END IF;
END $$;

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
  IF v_role IS NULL OR NOT (v_role = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_role;
END $$;

DROP TABLE IF EXISTS app.interested_parties;
DROP TABLE IF EXISTS app.context_issues;

RESET ROLE;
