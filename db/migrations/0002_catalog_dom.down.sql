-- 0002 の巻き戻し
DROP TABLE IF EXISTS catalog.policies_default;
DROP TABLE IF EXISTS catalog.calendar_events_default;
DROP TRIGGER IF EXISTS trg_validate_risk_bands ON catalog.risk_criteria_default;
DROP TABLE IF EXISTS catalog.risk_criteria_default;
DROP FUNCTION IF EXISTS catalog.validate_risk_bands();
DROP TABLE IF EXISTS catalog.asset_classes_default;
DROP TABLE IF EXISTS catalog.roles_default;
DROP TABLE IF EXISTS catalog.dom_versions;
