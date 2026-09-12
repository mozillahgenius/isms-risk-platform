-- @run-as: admin
-- Rollback of 0063. Removes the control effectiveness evaluation table, the role check function, the management review approval function and
-- the definer read policies, and the corrective action invariants. Approval records left in app.approvals are not deleted
-- (audit records are never rewritten afterwards).
--
-- **Do not roll back when effectiveness evaluation records exist** (same as 0055; 9.1 records must not silently vanish on down).
-- The guard goes before SET ROLE and takes a SHARE lock before counting (see 0055's down for why).
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  -- If the table is absent (dropped by hand, partially rolled back), there is nothing to count. Proceed to the subsequent DROP ... IF EXISTS.
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
