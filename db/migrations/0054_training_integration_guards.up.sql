-- 0054: 教育連携の年度別証跡、再評価、管理権限を強制する

SET ROLE schema_owner;

DROP INDEX app.trainings_external_source_unique;
CREATE UNIQUE INDEX trainings_external_source_unique
  ON app.trainings (tenant_id, source_system, external_training_id, fiscal_year)
  WHERE external_training_id IS NOT NULL;

ALTER TABLE app.training_records
  ADD COLUMN source_sha256 text,
  ADD CONSTRAINT training_records_source_sha256_format
    CHECK (source_sha256 IS NULL OR source_sha256 ~ '^[0-9a-f]{64}$');

ALTER TABLE app.competency_fulfillments
  ADD COLUMN training_id uuid,
  ADD COLUMN training_user_id uuid,
  ADD CONSTRAINT competency_fulfillments_training_pair
    CHECK ((training_id IS NULL) = (training_user_id IS NULL)),
  ADD CONSTRAINT competency_fulfillments_training_member
    CHECK (training_user_id IS NULL OR training_user_id = member_id),
  ADD CONSTRAINT competency_fulfillments_training_record_fk
    FOREIGN KEY (tenant_id, training_id, training_user_id)
    REFERENCES app.training_records(tenant_id, training_id, user_id);

CREATE FUNCTION app.require_training_manager() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE
  t uuid := app.current_tenant();
  u uuid := app.current_session_user();
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM app.memberships m
      JOIN app.users usr ON usr.tenant_id=m.tenant_id AND usr.id=m.user_id
     WHERE m.tenant_id=t AND m.user_id=u
       AND m.role_key IN ('ciso','secretariat')
       AND m.revoked_at IS NULL AND usr.status='active'
  ) THEN
    RAISE EXCEPTION 'training manager role required' USING ERRCODE='insufficient_privilege';
  END IF;
END $$;
ALTER FUNCTION app.require_training_manager() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.require_training_manager() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.require_training_manager() TO app_rw;

CREATE FUNCTION app.guard_training_write() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
BEGIN
  PERFORM app.require_training_manager();
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
ALTER FUNCTION app.guard_training_write() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_training_write() FROM PUBLIC;

CREATE TRIGGER trg_training_manager_write
  BEFORE INSERT OR UPDATE OR DELETE ON app.trainings
  FOR EACH ROW EXECUTE FUNCTION app.guard_training_write();
CREATE TRIGGER trg_training_record_manager_write
  BEFORE INSERT OR UPDATE OR DELETE ON app.training_records
  FOR EACH ROW EXECUTE FUNCTION app.guard_training_write();

COMMENT ON COLUMN app.training_records.source_sha256 IS
  '同期元レスポンス1件の正規化JSONに対するSHA-256。値が変わった再同期では評価を未評価へ戻す。';
COMMENT ON COLUMN app.competency_fulfillments.training_id IS
  '力量評価へ引用した教育・訓練記録。現在も有効かを表示・集計時に再確認する。';

RESET ROLE;
