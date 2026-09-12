-- 0028: give operational risks a stable, human-usable key.
ALTER TABLE app.risk_scenarios
  ADD COLUMN risk_key text;

UPDATE app.risk_scenarios
   SET risk_key = 'RISK-' || upper(replace(left(id::text, 13), '-', ''))
 WHERE risk_key IS NULL;

ALTER TABLE app.risk_scenarios
  ALTER COLUMN risk_key SET NOT NULL;

ALTER TABLE app.risk_scenarios
  ADD CONSTRAINT risk_scenarios_risk_key_unique UNIQUE (tenant_id, risk_key);
