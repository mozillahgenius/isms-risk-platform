-- Rollback of 0022.
-- provision_tenant is not restored to the 0021 definition (that would regress to the old form that
-- names public.gen_random_uuid() explicitly). The function itself is dropped by 0021's down.
SET ROLE schema_owner;

DROP TRIGGER IF EXISTS trg_check_runs_digest ON app.check_runs;
DROP FUNCTION IF EXISTS app.enforce_check_digest();
DROP FUNCTION IF EXISTS catalog.check_digest(text);

RESET ROLE;
