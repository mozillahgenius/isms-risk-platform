-- Rollback of 0024
SET ROLE schema_owner;
-- Restore the provenance targets. The CHECK can't be narrowed while connector_manifests rows remain, so delete them first.
DELETE FROM catalog.seed_provenance WHERE target = 'connector_manifests';
ALTER TABLE catalog.seed_provenance DROP CONSTRAINT IF EXISTS seed_provenance_target_check;
ALTER TABLE catalog.seed_provenance
  ADD CONSTRAINT seed_provenance_target_check
  CHECK (target IN ('dom', 'controls', 'risk_scenario_templates'));
DROP TABLE IF EXISTS app.raw_events;
DROP INDEX IF EXISTS app.groups_email_unique;
ALTER TABLE app.groups DROP COLUMN IF EXISTS email;
RESET ROLE;
