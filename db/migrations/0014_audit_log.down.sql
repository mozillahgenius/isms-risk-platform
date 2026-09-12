-- Rollback of 0014
-- Revoke the EXECUTE on app.current_tenant() granted to auditlogd in up.
-- The function belongs to 0006, so without revoking here it would remain when only 0014 is rolled back.
REVOKE EXECUTE ON FUNCTION app.current_tenant() FROM auditlogd;

-- chain_payload takes audit.audit_log's composite type as an argument, so drop it before the table
-- (the reverse order yields "cannot drop table ... because other objects depend on it").
DROP FUNCTION IF EXISTS audit.append(uuid, timestamptz, uuid, text, text, text, uuid, jsonb, text, bytea);
DROP FUNCTION IF EXISTS audit.verify_chain();
DROP FUNCTION IF EXISTS audit.chain_payload(audit.audit_log);
DROP TABLE IF EXISTS audit.audit_log;
