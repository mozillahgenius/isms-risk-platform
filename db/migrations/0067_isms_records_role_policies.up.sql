-- @run-as: admin
-- 0067: 記録の表の書き込みを、DB でも役割で絞る（Codex レビュー 2026-09-12 3 巡目・ユーザー判断「DB でも強制する」）。
--
-- これまでは、サーバーアクションが app.require_records_role(kind) を呼んでから app_rw で書く設計だった（0063）。
-- 関数を呼ぶのは呼び出し側の約束でしかなく、呼び忘れや別の書き込み経路があると、テナント内の誰でも
-- （監査人・メンバーでも）書けてしまう。他社提供（設計書 §6）の前提として、表の側でも拒否する。
--
-- 対象は、記録の画面だけが書く新しい表（0063〜0066 で作ったもの）:
--   control_effectiveness（effectiveness）・context_issues / interested_parties（context）・legal_requirements（legal）
-- 既存の表（監査・指摘・是正処置・レビュー・目的・証跡・例外・委託先評価）は、チェックの実行や作業の割り振りなど
-- 別の書き込み経路があるので、ここでは絞らない（絞ると別の経路を壊す。役割は従来どおりサーバーアクションで確かめる）。
--
-- 形:
--   - 種類ごとの許可を app.records_role_allows(kind) の 1 か所に置き、require_records_role はそれを呼ぶだけにする
--     （表のポリシーと関数とで許可の表が食い違わないように）。以後の種類の追加は records_role_allows だけを差し替える。
--   - 各表に RESTRICTIVE のポリシーを INSERT / UPDATE / DELETE の 3 枚。読み取りは絞らない（役割に関係なく読める）。
--     RESTRICTIVE は既存の tenant_isolation（PERMISSIVE）と AND で効くので、テナント境界はそのまま。
--   - 条件は (SELECT app.records_role_allows('<kind>')) の形（行ごとに役割を引き直さない）。
--   - 名前と形・張る表は check_rls.sql が固定する。

SET ROLE schema_owner;

CREATE FUNCTION app.records_role_allows(p_kind text) RETURNS boolean
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
  -- 本人が分からない（セッションが無い）ときは許さない。
  IF app.current_session_user() IS NULL THEN
    RETURN false;
  END IF;
  v_role := app.current_management_role();
  -- NULL = ANY は NULL（偽ではない）なので、NULL は明示して偽にする。
  RETURN v_role IS NOT NULL AND v_role = ANY (v_allowed);
END $$;
ALTER FUNCTION app.records_role_allows(text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.records_role_allows(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.records_role_allows(text) TO app_rw;

COMMENT ON FUNCTION app.records_role_allows(text) IS
  '記録の種類ごとに、今の本人の役割で書いてよいか。許可の表の唯一の置き場所（require_records_role と各表の records_role_* ポリシーが使う）。';

-- 役割の確認関数は、許可の表を持たずに records_role_allows を呼ぶだけにする（振る舞いは 0066 と同じ）。
CREATE OR REPLACE FUNCTION app.require_records_role(p_kind text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF app.current_session_user() IS NULL THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  -- 知らない種類は records_role_allows が 'unknown record kind' で落とす。
  IF NOT app.records_role_allows(p_kind) THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN app.current_management_role();
END $$;

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('control_effectiveness', 'effectiveness'),
      ('context_issues',        'context'),
      ('interested_parties',    'context'),
      ('legal_requirements',    'legal')) AS v(tbl, kind)
  LOOP
    EXECUTE format('CREATE POLICY records_role_insert ON app.%I AS RESTRICTIVE FOR INSERT TO app_rw '
                   'WITH CHECK ((SELECT app.records_role_allows(%L)))', r.tbl, r.kind);
    EXECUTE format('CREATE POLICY records_role_update ON app.%I AS RESTRICTIVE FOR UPDATE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L))) WITH CHECK ((SELECT app.records_role_allows(%L)))',
                   r.tbl, r.kind, r.kind);
    EXECUTE format('CREATE POLICY records_role_delete ON app.%I AS RESTRICTIVE FOR DELETE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L)))', r.tbl, r.kind);
  END LOOP;
END $$;

RESET ROLE;
