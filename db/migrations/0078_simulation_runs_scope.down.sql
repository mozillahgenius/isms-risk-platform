-- @run-as: admin
-- 0078 の戻し。ISMS 範囲で実行した記録が1件でもあれば、戻さずに止める。
-- 管理者のまま流すのは up と同じ理由(FORCE RLS で schema_owner からは記録が見えず、確認が空振りする)。
-- 列を落とすと、その記録が全体の実行と区別できなくなり、全体の履歴に ISMS だけで計算した
-- 合計が混ざるため(0044 の受入 C3)。その場合は、記録をどう扱うかを人が決めてから戻す。
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM app.simulation_runs WHERE scope <> 'ALL') THEN
    -- 文言は scripts/deploy_runtime.sh の DOWN_GUARD_MESSAGES と同じにする(配備の復旧の予行で「既知の保護」と
    -- 判定させるため)。番号を付け直すときは、ここと DOWN_GUARD_MESSAGES を同時に直す(DB 試験が一致を確かめる)。
    RAISE EXCEPTION '0078 rollback refused: ISMS-scoped simulation runs would lose their scope';
  END IF;
END $$;

ALTER TABLE app.simulation_runs DROP CONSTRAINT IF EXISTS simulation_runs_scope_check;
ALTER TABLE app.simulation_runs DROP COLUMN IF EXISTS scope;
