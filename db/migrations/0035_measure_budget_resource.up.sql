-- 0035: 施策マスタ（app.measures）に予算・人的リソースを追加。
--
-- 「IB管理基盤 拡張仕様書」画面②③の受入条件対応。実装前に app.measures /
-- app.risk_treatments を実読し、budget/resource 系フィールドが存在しないことを
-- 確認した上での新設（既存コード再利用の原則：既にあるものを重複実装しない）。
--
-- 意味の範囲（画面⑤のROIコスト計算がこの1行を単純合算する前提。期間・年度・
-- 通貨・実績と予算の別は持たない。多期間の予算管理が必要になったら、この2列
-- ではなく専用テーブルへ拡張する）：
--   budget_amount … その施策に充てる予算の想定額（円、単発）。
--   resource_fte  … その施策に充てる人的リソース（FTE換算、例 0.15）。
--
-- 既存行への影響を避けるため両列とも NULL 許容の追加のみ。データ移行は不要。
-- numeric の NaN は Postgres では自己比較で真になり `>= 0` を通過するため、
-- NaN を明示的に拒否する（Codexレビュー指摘: NaN が通過する単純な >= 0 は不十分）。
--
-- 採番メモ: 0034 は未マージブランチ feature/policy-version-workflow-local が
-- 既に使用済み（commit b5db3fb、まだ main 未マージ）。番号の衝突を避けるため
-- この変更は 0035 とする。

ALTER TABLE app.measures
  ADD COLUMN budget_amount numeric(12,2)
             CHECK (budget_amount IS NULL
                    OR (budget_amount >= 0 AND budget_amount <> 'NaN'::numeric)),
  ADD COLUMN resource_fte  numeric(4,2)
             CHECK (resource_fte IS NULL
                    OR (resource_fte >= 0 AND resource_fte <> 'NaN'::numeric));

COMMENT ON COLUMN app.measures.budget_amount IS
  '施策に充てる予算の想定額（円、単発）。任意。created-by:0035_measure_budget_resource';
COMMENT ON COLUMN app.measures.resource_fte IS
  '施策に充てる人的リソース（FTE換算、例 0.15）。任意。created-by:0035_measure_budget_resource';
