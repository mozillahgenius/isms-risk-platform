-- @run-as: admin

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM app.trainings
     WHERE source_system <> 'manual' OR external_training_id IS NOT NULL
        OR tags <> '{}'::text[] OR description <> ''
  ) OR EXISTS (
    SELECT 1 FROM app.training_records
     WHERE evidence_ref <> '' OR source_payload <> '{}'::jsonb OR source_sha256 IS NOT NULL
        OR imported_at IS NOT NULL OR evaluation_status <> '未評価'
  ) OR EXISTS (
    SELECT 1 FROM app.competency_fulfillments WHERE training_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION '0054 rollback refused: training integration data would be lost';
  END IF;
END $$;

SET ROLE schema_owner;

DROP TRIGGER IF EXISTS trg_training_record_manager_write ON app.training_records;
DROP TRIGGER IF EXISTS trg_training_manager_write ON app.trainings;
DROP FUNCTION IF EXISTS app.guard_training_write();
DROP FUNCTION IF EXISTS app.require_training_manager();

ALTER TABLE app.competency_fulfillments
  DROP CONSTRAINT competency_fulfillments_training_record_fk,
  DROP CONSTRAINT competency_fulfillments_training_member,
  DROP CONSTRAINT competency_fulfillments_training_pair,
  DROP COLUMN training_user_id,
  DROP COLUMN training_id;

ALTER TABLE app.training_records
  DROP CONSTRAINT training_records_source_sha256_format,
  DROP COLUMN source_sha256;

DROP INDEX app.trainings_external_source_unique;
CREATE UNIQUE INDEX trainings_external_source_unique
  ON app.trainings (tenant_id, source_system, external_training_id)
  WHERE external_training_id IS NOT NULL;

RESET ROLE;
