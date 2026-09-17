-- 0027 の巻き戻し。新規オブジェクトを依存順に戻す。

ALTER TABLE app.risk_treatments
  DROP CONSTRAINT IF EXISTS risk_treatments_measure_fk;
ALTER TABLE app.risk_treatments
  DROP COLUMN IF EXISTS measure_id;

DROP TABLE IF EXISTS app.risk_evaluation_snapshots;
DROP TABLE IF EXISTS app.risk_scenario_frameworks;
DROP TABLE IF EXISTS app.risk_scenario_assets;
DROP TABLE IF EXISTS app.measure_frameworks;
DROP TABLE IF EXISTS app.measures;
DROP TABLE IF EXISTS app.asset_frameworks;
DROP TABLE IF EXISTS app.assets;

ALTER TABLE app.risk_scenarios
  DROP COLUMN IF EXISTS phase,
  DROP COLUMN IF EXISTS area;

ALTER TABLE catalog.risk_scenario_templates
  DROP CONSTRAINT IF EXISTS risk_scenario_templates_business_key;
UPDATE catalog.risk_scenario_templates
   SET domain = area || '（Phase' || phase::text || '）';
ALTER TABLE catalog.risk_scenario_templates
  ADD CONSTRAINT risk_scenario_templates_domain_theme_measure_frame_summary_key
  UNIQUE (domain, theme, measure, frame, summary);
ALTER TABLE catalog.risk_scenario_templates
  DROP CONSTRAINT IF EXISTS risk_scenario_templates_phase_check,
  DROP COLUMN IF EXISTS phase,
  DROP COLUMN IF EXISTS area;

DROP TABLE IF EXISTS catalog.policy_frameworks;
DROP TABLE IF EXISTS catalog.risk_template_frameworks;
DROP TABLE IF EXISTS catalog.control_frameworks;
DELETE FROM catalog.frameworks WHERE key = 'RISK-MANAGEMENT';
