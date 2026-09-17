-- @run-as: admin
-- 0068 の巻き戻し。事業継続の計画・試験の表を外し、許可の表を 0067 の版へ戻す。
--
-- **データがあるときは巻き戻さない**（0055 と同じ。A.5.29 / 5.30 の記録を down で黙って消さない）。
-- guard は SET ROLE の前に置き、表ごとに、在るときだけ SHARE ロックを取って数える（0065 の down と同じ）。
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  IF to_regclass('app.continuity_tests') IS NOT NULL THEN
    LOCK TABLE app.continuity_tests IN SHARE MODE;
    SELECT count(*) INTO n FROM app.continuity_tests;
    IF n > 0 THEN
      RAISE EXCEPTION '0068 rollback refused: continuity tests would be lost (% rows)', n;
    END IF;
  END IF;
  IF to_regclass('app.continuity_plans') IS NOT NULL THEN
    LOCK TABLE app.continuity_plans IN SHARE MODE;
    SELECT count(*) INTO n FROM app.continuity_plans;
    IF n > 0 THEN
      RAISE EXCEPTION '0068 rollback refused: continuity plans would be lost (% rows)', n;
    END IF;
  END IF;
END $$;

SET ROLE schema_owner;

-- 表を消すと、張ってある役割ポリシーも一緒に消える。
DROP TABLE IF EXISTS app.continuity_tests;
DROP TABLE IF EXISTS app.continuity_plans;

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
