-- schema_owner is subject to FORCE ROW LEVEL SECURITY on mail_outbox.  The
-- rollback gate must inspect the whole clone, so run this data-loss check as
-- the migration connection role before returning to the normal owner role.
RESET ROLE;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM app.mail_outbox WHERE purpose = 'agent_distribution'
  ) THEN
    RAISE EXCEPTION '0083 rollback refused: agent distribution mail records would be lost';
  END IF;
END
$$;
SET ROLE schema_owner;
