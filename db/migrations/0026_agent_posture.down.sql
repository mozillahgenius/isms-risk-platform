SET ROLE schema_owner;

DROP POLICY IF EXISTS agent_snapshot_definer_insert ON app.device_snapshots;
DROP POLICY IF EXISTS agent_snapshot_definer_read ON app.device_snapshots;
DROP POLICY IF EXISTS agent_device_definer_update ON app.devices;
DROP POLICY IF EXISTS agent_device_definer_insert ON app.devices;
DROP POLICY IF EXISTS agent_device_definer_read ON app.devices;
DROP POLICY IF EXISTS agent_token_access ON app.device_enrollment_tokens;
DROP POLICY IF EXISTS tenant_read ON app.device_enrollment_tokens;
DROP POLICY IF EXISTS tenant_isolation ON app.device_enrollment_tokens;

DROP FUNCTION IF EXISTS app.ingest_device_snapshot(uuid,timestamptz,text,int,bytea,jsonb,bytea,bytea,bytea);
DROP FUNCTION IF EXISTS app.get_device_verification_key(uuid);
DROP FUNCTION IF EXISTS app.set_agent_ingest_key(bytea);
DROP FUNCTION IF EXISTS app.issue_device_enrollment_token(uuid,text,interval);
DROP FUNCTION IF EXISTS app.enroll_device(text,text,text,text,text,boolean,bytea);
DROP FUNCTION IF EXISTS app.agent_tenant_target();

DROP TABLE IF EXISTS app.device_enrollment_tokens;
DROP TABLE IF EXISTS app.agent_ingest_keys;
DROP TABLE IF EXISTS catalog.agent_definitions;
DROP INDEX IF EXISTS device_snapshots_idempotency;
ALTER TABLE app.device_snapshots DROP COLUMN IF EXISTS payload;
ALTER TABLE app.device_snapshots DROP COLUMN IF EXISTS signature;
ALTER TABLE app.devices DROP COLUMN IF EXISTS public_key;

RESET ROLE;
