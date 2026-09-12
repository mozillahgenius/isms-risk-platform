-- 0035 rollback.
-- Caution: running down loses any budget_amount / resource_fte values already entered
-- (the columns themselves are dropped). If this change ever needs to be undone in
-- production, it is usually safer to revert only the app code to the previous revision and
-- not run this down (Codex review finding). To disable while keeping the values, just
-- hide the fields on the app side.

ALTER TABLE app.measures
  DROP COLUMN IF EXISTS budget_amount,
  DROP COLUMN IF EXISTS resource_fte;
