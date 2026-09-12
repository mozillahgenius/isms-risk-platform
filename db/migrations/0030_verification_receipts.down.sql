SET ROLE schema_owner;

DROP TRIGGER IF EXISTS trg_check_runs_verification_receipt ON app.check_runs;
DROP FUNCTION IF EXISTS app.enforce_verification_receipt();
ALTER TABLE app.check_runs DROP COLUMN IF EXISTS verification_receipt_id;
DROP FUNCTION IF EXISTS app.accept_verification_receipt(text[],text);
DROP TABLE IF EXISTS app.verification_receipts;

RESET ROLE;
