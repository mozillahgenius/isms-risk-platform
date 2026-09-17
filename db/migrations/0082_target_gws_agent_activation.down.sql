SET ROLE schema_owner;

DROP FUNCTION IF EXISTS app.activate_device_login_enrollment_for_target(bytea);
DROP FUNCTION IF EXISTS app.start_device_login_enrollment(bytea,bytea,bytea,text,text,text,text,boolean,text,text,bytea);
DROP INDEX IF EXISTS app.device_login_requests_distribution_token;
ALTER TABLE app.device_login_requests DROP COLUMN IF EXISTS distribution_token_hash;

RESET ROLE;
