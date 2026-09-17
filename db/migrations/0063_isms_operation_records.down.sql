-- @run-as: admin
-- 0063 の巻き戻し。統制の有効性評価の表、役割の確認関数、マネジメントレビューの承認関数と
-- 定義者向けの読み取りポリシー、是正処置の不変条件を外す。app.approvals に残った承認の記録は消さない
-- （監査の記録を後から書き換えない）。
--
-- **有効性評価の記録があるときは巻き戻さない**（0055 と同じ。9.1 の記録を down で黙って消さない）。
-- guard は SET ROLE の前に置き、数える前に SHARE ロックを取る（理由は 0055 の down を参照）。
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  -- 表が無い（手で消した・途中まで戻った）ときは数えるものが無い。後続の DROP ... IF EXISTS へ進める。
  IF to_regclass('app.control_effectiveness') IS NOT NULL THEN
    LOCK TABLE app.control_effectiveness IN SHARE MODE;
    SELECT count(*) INTO n FROM app.control_effectiveness;
    IF n > 0 THEN
      RAISE EXCEPTION '0063 rollback refused: control effectiveness records would be lost (% rows)', n;
    END IF;
  END IF;
END $$;

ALTER TABLE app.corrective_actions DROP CONSTRAINT IF EXISTS corrective_actions_reviewer_not_owner;
ALTER TABLE app.corrective_actions DROP CONSTRAINT IF EXISTS corrective_actions_effectiveness_after_completion;
ALTER TABLE app.corrective_actions DROP CONSTRAINT IF EXISTS corrective_actions_effectiveness_complete;

SET ROLE schema_owner;
DROP FUNCTION IF EXISTS app.approve_management_review(uuid, text);
DROP POLICY IF EXISTS tenant_security_definer_read ON app.management_reviews;
DROP FUNCTION IF EXISTS app.require_records_role(text);
DROP TABLE IF EXISTS app.control_effectiveness;
RESET ROLE;
