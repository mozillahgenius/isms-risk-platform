-- 0035: Add budget and human resources to the measure master (app.measures).
--
-- Addresses the acceptance criteria for screens ② and ③ of the "management platform extension spec". Before implementing, app.measures /
-- app.risk_treatments were actually read, confirming that no budget/resource fields exist,
-- before adding these (principle of reusing existing code: don't reimplement what already exists).
--
-- Scope of meaning (assumes screen ⑤'s ROI cost calculation simply sums this one row. No period, fiscal year,
-- currency, or actual-vs-budget distinction. If multi-period budget management becomes necessary, extend to a
-- dedicated table rather than these two columns):
--   budget_amount … expected budget allocated to the measure (JPY, one-off).
--   resource_fte  … human resources allocated to the measure (in FTE, e.g. 0.15).
--
-- Both columns are nullable additions only, to avoid affecting existing rows. No data migration needed.
-- In Postgres, numeric NaN compares true against itself and passes `>= 0`, so
-- NaN is rejected explicitly (Codex review finding: a plain >= 0 that lets NaN through is insufficient).
--
-- Numbering note: 0034 is already used by the unmerged branch feature/policy-version-workflow-local
-- (commit b5db3fb, not yet merged into main). To avoid a number collision,
-- this change is 0035.

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
