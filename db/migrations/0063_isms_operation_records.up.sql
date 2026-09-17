-- @run-as: admin
-- 0063: ISMS の運用記録を画面から入力するための受け皿（設計書 2026-09-11 §4・§5 の第 1 段）。
--
-- 対象は年間サイクルで毎年要る記録のうち、§5.3 で先にやると決めた 4 つ:
--   内部監査（9.2）・指摘と是正処置（10.2）・マネジメントレビュー（9.3）・統制の有効性評価（9.1）。
-- 前の 3 つは表が既に在り、画面から書く手段が無かった。有効性評価は表そのものが無いので、ここで作る。
--
-- 方針:
--   - 書き込みは Web のサーバーアクションが app_rw で直接行う（既存のリスク台帳と同じ）。
--     書き込みを SECURITY DEFINER の関数に寄せないのは、対象の表すべてに schema_owner 向けの
--     ポリシーが要り、0062 で直した「文脈が無いと例外」の罠を広げるため。
--   - 役割の確認は app.require_records_role(kind) の 1 か所で行う（画面の出し分けだけに頼らない）。
--   - 承認を伴うのはマネジメントレビューの議事だけ。経営層（ciso）が承認し、承認した時点の議事の
--     ハッシュを app.approvals へ結ぶ。同じ議事の二重承認は拒否する（0034 / 0056 と同じ形）。
--   - 中身のデータは入れない（実績の捏造になる）。

SET ROLE schema_owner;

-- ---------------------------------------------------------------------------
-- 統制の有効性評価（9.1）。「実施した」と「効いている」は別。後者を、何をもって有効とみなしたか
-- （判定基準）と、いつ誰が評価したかと一緒に残す。基準の無い評価は評価ではないので空を許さない。
CREATE TABLE app.control_effectiveness (
  id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  measure_id         uuid NOT NULL,
  criteria           text NOT NULL,
  evaluated_on       date NOT NULL,
  evaluator_user_id  uuid NOT NULL,
  result             text NOT NULL CHECK (result IN ('effective','partially_effective','not_effective')),
  evidence_note      text NOT NULL DEFAULT '',
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, measure_id)        REFERENCES app.measures(tenant_id, id),
  FOREIGN KEY (tenant_id, evaluator_user_id) REFERENCES app.users(tenant_id, id),
  -- btrim は既定で空白しか削らないので、タブや改行だけの基準がすり抜ける。空白以外の文字が 1 つは要る。
  CHECK (criteria ~ '[^[:space:]]')
);
CREATE INDEX control_effectiveness_measure ON app.control_effectiveness (tenant_id, measure_id, evaluated_on DESC);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['control_effectiveness'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO app_rw',t);
  END LOOP;
END $$;

COMMENT ON TABLE app.control_effectiveness IS
  '統制の有効性評価（9.1）。criteria（何をもって有効とみなすか）は必須。評価日が今日までのものだけを実施済みとして数える。';

-- ---------------------------------------------------------------------------
-- 記録の種類ごとに、書いてよい役割を 1 か所で決める。
--   audit              内部監査・監査の指摘   : owner / admin / auditor（監査人は業務データは書けないが監査記録は書く）
--   corrective         是正処置               : owner / admin / manager
--   effectiveness      有効性の評価・確認     : owner / admin
--   management_review  マネジメントレビュー   : owner / admin
CREATE FUNCTION app.require_records_role(p_kind text) RETURNS text
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
  END;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'unknown record kind: %', p_kind;
  END IF;
  -- 役割が NULL のとき `NOT (NULL = ANY (...))` は NULL になり、IF が分岐せず素通りする。NULL は明示して拒否する。
  IF v_role IS NULL OR NOT (v_role = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_role;
END $$;
ALTER FUNCTION app.require_records_role(text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.require_records_role(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.require_records_role(text) TO app_rw;

-- ---------------------------------------------------------------------------
-- マネジメントレビューの議事の承認（9.3）。承認関数が schema_owner として議事を読めるよう、
-- 読み取りだけの定義者ポリシーを 1 枚足す。名前と形は check_rls.sql が固定している
-- tenant_security_definer_read（文脈が無いときは NULL で比べる＝何も見えない。0062 と同じ書き方）。
CREATE POLICY tenant_security_definer_read ON app.management_reviews FOR SELECT TO schema_owner
  USING (tenant_id = (SELECT app.current_tenant_or_null()));

CREATE FUNCTION app.approve_management_review(p_review_id uuid, p_comment text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant  uuid := app.current_tenant();
  v_user    uuid := app.current_session_user();
  v_minutes text;
  v_held    date;
  v_hash    bytea;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM app.memberships m
      JOIN app.users u ON u.tenant_id = m.tenant_id AND u.id = m.user_id
     WHERE m.tenant_id = v_tenant AND m.user_id = v_user AND m.role_key = 'ciso'
       AND m.revoked_at IS NULL AND u.status = 'active'
  ) THEN
    RAISE EXCEPTION 'executive role required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT minutes_md, held_on INTO v_minutes, v_held
    FROM app.management_reviews WHERE tenant_id = v_tenant AND id = p_review_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'management review not found';
  END IF;
  -- 開いていないレビュー（開催日が無い・先の日付）の議事は承認しない。予定を実施として扱わない。
  IF v_held IS NULL OR v_held > (now() AT TIME ZONE 'Asia/Tokyo')::date THEN
    RAISE EXCEPTION 'management review has not been held';
  END IF;
  IF v_minutes IS NULL OR v_minutes !~ '[^[:space:]]' THEN
    RAISE EXCEPTION 'management review minutes are empty';
  END IF;

  -- 開催日と議事を合わせてハッシュにする（後から議事を直しても「何を承認したか」が残る）。
  v_hash := public.digest(pg_catalog.convert_to(v_held::text || E'\n' || v_minutes, 'UTF8'), 'sha256');
  IF EXISTS (
    SELECT 1 FROM app.approvals
     WHERE tenant_id = v_tenant AND target_type = 'management_review'
       AND target_id = p_review_id AND target_version_hash = v_hash
  ) THEN
    RAISE EXCEPTION 'these management review minutes are already approved';
  END IF;

  INSERT INTO app.approvals
    (tenant_id, target_type, target_id, target_version_hash, approver_user_id, comment, created_by)
  VALUES (v_tenant, 'management_review', p_review_id, v_hash, v_user, p_comment, v_user);
END $$;
ALTER FUNCTION app.approve_management_review(uuid, text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.approve_management_review(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.approve_management_review(uuid, text) TO app_rw;

COMMENT ON FUNCTION app.approve_management_review(uuid, text) IS
  'マネジメントレビュー（9.3）の議事の承認。ciso のみ。開催日が今日までで議事が空でないこと。開催日＋議事のハッシュを app.approvals へ結び、同じ議事の二重承認は拒否する。';

RESET ROLE;

-- ---------------------------------------------------------------------------
-- 是正処置（10.2）の不変条件。表の所有者が schema_owner とは限らないので superuser のまま足す。
-- 既存の行も検証する（NOT VALID にしない）。NOT VALID だと違反した既存行が残り、その行の無関係な更新まで
-- 再検査で失敗するうえ、後の VALIDATE も通らない（Codex レビュー 2026-09-12 2 巡目）。
-- 違反した行があれば適用そのものが落ちる。黙って直さず、人が行を確かめてから直す（監査の記録を機械で書き換えない）。
ALTER TABLE app.corrective_actions
  ADD CONSTRAINT corrective_actions_effectiveness_complete CHECK (
    (effectiveness_reviewed_by IS NULL AND effectiveness_reviewed_at IS NULL AND effectiveness_result IS NULL)
    OR (effectiveness_reviewed_by IS NOT NULL AND effectiveness_reviewed_at IS NOT NULL AND effectiveness_result IS NOT NULL)
  );
-- 処置が終わる前に「効いた」とは言えない。完了していることに加え、確認の日時が完了より後であること
-- （完了の日時だけ先に入れて、それより前の日付で確認したことにはできない）。
ALTER TABLE app.corrective_actions
  ADD CONSTRAINT corrective_actions_effectiveness_after_completion CHECK (
    effectiveness_reviewed_at IS NULL
    OR (completed_at IS NOT NULL AND effectiveness_reviewed_at >= completed_at)
  );
-- 職務分離: 処置を担当した人が、自分の処置の有効性を確認しない。
ALTER TABLE app.corrective_actions
  ADD CONSTRAINT corrective_actions_reviewer_not_owner CHECK (
    effectiveness_reviewed_by IS NULL OR owner_user_id IS NULL OR effectiveness_reviewed_by <> owner_user_id
  );
