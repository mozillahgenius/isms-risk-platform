-- 0053: 教育・訓練の記録と eLearning 受講実績の引用・評価

SET ROLE schema_owner;

ALTER TABLE app.trainings
  ADD COLUMN description text NOT NULL DEFAULT '',
  ADD COLUMN tags text[] NOT NULL DEFAULT '{}',
  ADD COLUMN source_system text NOT NULL DEFAULT 'manual'
    CHECK (source_system IN ('manual', 'elearning')),
  ADD COLUMN external_training_id text;

CREATE UNIQUE INDEX trainings_external_source_unique
  ON app.trainings (tenant_id, source_system, external_training_id)
  WHERE external_training_id IS NOT NULL;

ALTER TABLE app.training_records
  ADD COLUMN evidence_ref text NOT NULL DEFAULT '',
  ADD COLUMN source_payload jsonb NOT NULL DEFAULT '{}',
  ADD COLUMN imported_at timestamptz,
  ADD COLUMN evaluation_status text NOT NULL DEFAULT '未評価'
    CHECK (evaluation_status IN ('未評価', '有効', '要確認', '対象外')),
  ADD COLUMN evaluated_at timestamptz,
  ADD COLUMN evaluated_by uuid;

ALTER TABLE app.training_records
  ADD CONSTRAINT training_records_evaluation_pair
    CHECK ((evaluation_status = '未評価' AND evaluated_at IS NULL AND evaluated_by IS NULL)
        OR (evaluation_status <> '未評価' AND evaluated_at IS NOT NULL AND evaluated_by IS NOT NULL)),
  ADD CONSTRAINT training_records_evaluated_by_fk
    FOREIGN KEY (tenant_id, evaluated_by) REFERENCES app.users(tenant_id, id);

COMMENT ON COLUMN app.trainings.tags IS
  '教育テーマの正規化タグ。eLearning の courses.tags を引用し、isms / risk-management 等で対象講座を識別する。';
COMMENT ON COLUMN app.training_records.evaluation_status IS
  '受講完了を力量の根拠として採用できるかの人による評価。受講完了だけで力量充足にはしない。';

RESET ROLE;
