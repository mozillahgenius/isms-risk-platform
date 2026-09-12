-- 0036 down: remove the incident assignment and related-risk columns
--
-- Caution: running this after production operation has started loses registered assignment history,
-- related-risk links and summaries. Prefer rolling back on the app code side (hiding it on screen);
-- this down is intended for rollback in development/verification environments.

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
