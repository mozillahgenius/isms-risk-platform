DROP VIEW IF EXISTS app.isms_risk_read_model;
REVOKE EXECUTE ON FUNCTION app.risk_evaluation_snapshot_sha256(app.risk_evaluation_snapshots) FROM app_ro;
DROP POLICY IF EXISTS tenant_read ON app.finding_risk_scenarios;
DROP POLICY IF EXISTS tenant_isolation ON app.finding_risk_scenarios;
DROP TABLE IF EXISTS app.finding_risk_scenarios;
