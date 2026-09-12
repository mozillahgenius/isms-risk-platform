ALTER TABLE app.risk_scenarios
  DROP CONSTRAINT IF EXISTS risk_scenarios_risk_key_unique;
ALTER TABLE app.risk_scenarios
  DROP COLUMN IF EXISTS risk_key;
