-- Rollback of 0008
DROP TRIGGER IF EXISTS trg_validate_residual ON app.risk_treatments;
DROP TABLE IF EXISTS app.risk_treatments;
DROP FUNCTION IF EXISTS app.validate_residual();
DROP TRIGGER IF EXISTS trg_validate_impact_sec ON app.risk_assessments;
DROP TABLE IF EXISTS app.risk_assessments;
DROP FUNCTION IF EXISTS app.validate_impact_sec();
DROP TABLE IF EXISTS app.risk_scenarios;
DROP TABLE IF EXISTS app.risk_criteria;
