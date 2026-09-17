-- 0024 の巻き戻し
SET ROLE schema_owner;
-- 出所の対象を元へ戻す。connector_manifests の行が残っていると CHECK を狭められないので先に消す。
DELETE FROM catalog.seed_provenance WHERE target = 'connector_manifests';
ALTER TABLE catalog.seed_provenance DROP CONSTRAINT IF EXISTS seed_provenance_target_check;
ALTER TABLE catalog.seed_provenance
  ADD CONSTRAINT seed_provenance_target_check
  CHECK (target IN ('dom', 'controls', 'risk_scenario_templates'));
DROP TABLE IF EXISTS app.raw_events;
DROP INDEX IF EXISTS app.groups_email_unique;
ALTER TABLE app.groups DROP COLUMN IF EXISTS email;
RESET ROLE;
