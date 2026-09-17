-- 0036 down: インシデントのアサイン・関連リスク列を取り除く
--
-- 注意: 本番で運用が始まった後にこれを実行すると、登録済みのアサイン履歴・
-- 関連リスク紐付け・要約が失われる。ロールバックはアプリコード側(画面非表示)
-- で行うことを優先し、このdownは開発/検証環境での巻き戻し用途を想定する。

ALTER TABLE app.incidents
  DROP CONSTRAINT IF EXISTS incidents_related_risk_fk,
  DROP CONSTRAINT IF EXISTS incidents_related_measure_fk,
  DROP CONSTRAINT IF EXISTS incidents_assignee_fk;

ALTER TABLE app.incidents
  DROP COLUMN IF EXISTS summary,
  DROP COLUMN IF EXISTS related_risk_id,
  DROP COLUMN IF EXISTS related_measure_id,
  DROP COLUMN IF EXISTS assignee_user_id,
  DROP COLUMN IF EXISTS resolved_at;
