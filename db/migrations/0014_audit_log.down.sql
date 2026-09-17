-- 0014 の巻き戻し
-- up で auditlogd へ与えた app.current_tenant() の EXECUTE を戻す。
-- 関数は 0006 のものなので、ここで revoke しないと 0014 だけ巻き戻したときに残る。
REVOKE EXECUTE ON FUNCTION app.current_tenant() FROM auditlogd;

-- chain_payload は audit.audit_log の複合型を引数に取るので、表より先に落とす
-- （逆にすると "cannot drop table ... because other objects depend on it" になる）。
DROP FUNCTION IF EXISTS audit.append(uuid, timestamptz, uuid, text, text, text, uuid, jsonb, text, bytea);
DROP FUNCTION IF EXISTS audit.verify_chain();
DROP FUNCTION IF EXISTS audit.chain_payload(audit.audit_log);
DROP TABLE IF EXISTS audit.audit_log;
