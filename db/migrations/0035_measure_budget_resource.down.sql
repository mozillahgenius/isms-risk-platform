-- 0035 巻き戻し。
-- 注意: down を実行すると、既に入力された budget_amount / resource_fte の値は
-- 失われる（列そのものを削除するため）。本番でこの変更を取り消す必要が生じた
-- 場合、通常はアプリのコードだけを前のリビジョンへ戻し、この down は流さない
-- 方が安全（Codexレビュー指摘）。値を保持したまま無効化したい場合は、アプリ側
-- でフィールドを非表示にするだけにとどめる。

ALTER TABLE app.measures
  DROP COLUMN IF EXISTS budget_amount,
  DROP COLUMN IF EXISTS resource_fte;
