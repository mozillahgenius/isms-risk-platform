SET ROLE schema_owner;

ALTER TABLE app.training_records
  DROP CONSTRAINT IF EXISTS training_records_evaluated_by_fk,
  DROP CONSTRAINT IF EXISTS training_records_evaluation_pair,
  DROP COLUMN IF EXISTS evaluated_by,
  DROP COLUMN IF EXISTS evaluated_at,
  DROP COLUMN IF EXISTS evaluation_status,
  DROP COLUMN IF EXISTS imported_at,
  DROP COLUMN IF EXISTS source_payload,
  DROP COLUMN IF EXISTS evidence_ref;

DROP INDEX IF EXISTS app.trainings_external_source_unique;

ALTER TABLE app.trainings
  DROP COLUMN IF EXISTS external_training_id,
  DROP COLUMN IF EXISTS source_system,
  DROP COLUMN IF EXISTS tags,
  DROP COLUMN IF EXISTS description;

RESET ROLE;
