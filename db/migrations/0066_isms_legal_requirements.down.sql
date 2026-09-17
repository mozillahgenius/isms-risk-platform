-- @run-as: admin
-- 0066 の巻き戻し。法令・契約上の要求事項の表を外し、役割の種類を 0065 の版へ戻す。
--
-- **データがあるときは巻き戻さない**（0055 と同じ。A.5.31 の記録を down で黙って消さない）。
-- guard は SET ROLE の前に置き、表が在るときだけ SHARE ロックを取って数える（0065 の down と同じ）。
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  IF to_regclass('app.legal_requirements') IS NOT NULL THEN
    LOCK TABLE app.legal_requirements IN SHARE MODE;
    SELECT count(*) INTO n FROM app.legal_requirements;
    IF n > 0 THEN
      RAISE EXCEPTION '0066 rollback refused: legal requirements would be lost (% rows)', n;
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
    WHEN 'context'           THEN ARRAY['owner','admin']
  END;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'unknown record kind: %', p_kind;
  END IF;
  IF v_role IS NULL OR NOT (v_role = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_role;
END $$;

DROP TABLE IF EXISTS app.legal_requirements;

RESET ROLE;
