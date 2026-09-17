-- 0016 の巻き戻し
DROP TRIGGER IF EXISTS trg_risk_criteria_immutable ON app.risk_criteria;
DROP FUNCTION IF EXISTS app.risk_criteria_immutable();
DROP TRIGGER IF EXISTS trg_validate_deviation_override ON app.deviations;
DROP FUNCTION IF EXISTS app.validate_deviation_override();
