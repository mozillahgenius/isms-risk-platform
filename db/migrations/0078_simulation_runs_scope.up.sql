-- @run-as: admin
-- 0078 app: AI分析(画面⑧)の施策除外シミュレーションの実行記録に「どの範囲で実行したか」を残す。
--
-- 管理者(superuser)のまま流す理由: app.simulation_runs は FORCE ROW LEVEL SECURITY(0044)なので、
-- 既定の SET ROLE schema_owner では既存の行が見えず、下の UPDATE が0件になって SET NOT NULL が
-- 既存の行で失敗する(Codex レビュー 2026-09-13 で再現)。0046・0047 と同じく、全テナントの既存の
-- 行に触る移行は管理者で流す。表の所有者は変わらない(ALTER TABLE は所有者を変えない)。
--
-- 総指揮の決定(2026-09-13 15:20): AI分析をリスクマネジメント全体だけでなく ISMS 側
-- (ISO27001:2022 タグの付いた施策・リスク・資産だけ)でも使えるようにする。
-- ISMS 側での実行は、ISMS タグ付きのリスクシナリオだけで合計する。
--
-- 実行記録の範囲は、後から施策のタグで推定しない。タグは後から外せる(ISO 除外の申請)ため、
-- 推定すると過去の実行がどちらの範囲だったか再現できなくなる(0044 の受入 C3)。
-- 既存の行は、範囲で絞らない全体の実行('ALL')として扱う。以後の INSERT は範囲を必ず書く
-- (既定値を置かない。範囲の無い ISMS の実行記録を作らないため)。
--
-- 番号は反映ブランチへ取り込んだ順で決めた(取り込み時点で空いていた最小の 0078。2026-09-13)。
-- 本番に当てた後は書き換えない。
ALTER TABLE app.simulation_runs ADD COLUMN scope text;
UPDATE app.simulation_runs SET scope = 'ALL' WHERE scope IS NULL;
ALTER TABLE app.simulation_runs ALTER COLUMN scope SET NOT NULL;
ALTER TABLE app.simulation_runs
  ADD CONSTRAINT simulation_runs_scope_check CHECK (scope IN ('ALL', 'ISO27001:2022'));

COMMENT ON COLUMN app.simulation_runs.scope IS
  '実行した範囲。ALL=範囲で絞らない全体、ISO27001:2022=ISMS タグ付きの施策・リスクシナリオだけで算出。実行時点の範囲を残し、後からタグで推定しない';
