-- @run-as: admin

-- Only drop the function. **Approval records (rows in app.approvals) are not deleted.**
-- The fact of approval could be stored in app.approvals even before 0056 existed,
-- and what this migration created is the path, not the record.
-- Deleting evidence to revert a path would be wrong.

SET ROLE schema_owner;

DROP FUNCTION IF EXISTS app.approve_iso_scope(text);

RESET ROLE;
