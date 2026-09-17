-- @run-as: admin
-- 0069 の巻き戻し。脆弱性の表を外し、許可の表を 0068 の版へ戻す。
--
-- **データがあるときは巻き戻さない**（0055 と同じ。A.8.8 の記録を down で黙って消さない）。
-- guard は SET ROLE の前に置き、表が在るときだけ SHARE ロックを取って数える（0065 の down と同じ）。
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  IF to_regclass('app.vulnerabilities') IS NOT NULL THEN
    LOCK TABLE app.vulnerabilities IN SHARE MODE;
    SELECT count(*) INTO n FROM app.vulnerabilities;
    IF n > 0 THEN
      RAISE EXCEPTION '0069 rollback refused: vulnerabilities would be lost (% rows)', n;
    END IF;
  END IF;
END $$;

SET ROLE schema_owner;

-- 表を消すと、張ってある役割ポリシーと索引も一緒に消える。
DROP TABLE IF EXISTS app.vulnerabilities;

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
