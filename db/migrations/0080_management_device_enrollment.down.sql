SET ROLE schema_owner;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM app.device_login_requests) THEN
    RAISE EXCEPTION '0080 rollback refused: management device login requests would be lost'
      USING DETAIL = 'Managementの端末登録要求が残っているため巻き戻せません',
            ERRCODE = 'dependent_objects_still_exist';
  END IF;
END $$;

DROP FUNCTION IF EXISTS app.redeem_device_login_enrollment(bytea,bytea,text,timestamptz);
DROP FUNCTION IF EXISTS app.device_login_enrollment_key(bytea);
DROP FUNCTION IF EXISTS app.decide_device_login_enrollment(uuid,bytea,boolean);
DROP FUNCTION IF EXISTS app.lookup_device_login_enrollment(bytea);
DROP FUNCTION IF EXISTS app.start_device_login_enrollment(bytea,bytea,bytea,text,text,text,text,boolean,text,text);
DROP FUNCTION IF EXISTS app.issue_device_enrollment_token_for_management(text,interval);
DROP TABLE IF EXISTS app.device_login_request_nonces;
DROP TABLE IF EXISTS app.device_login_requests;
ALTER TABLE app.device_enrollment_tokens
  DROP CONSTRAINT IF EXISTS device_enrollment_tokens_issued_by_fk,
  DROP COLUMN IF EXISTS issued_by,
  DROP COLUMN IF EXISTS method;
