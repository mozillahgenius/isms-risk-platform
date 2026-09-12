-- @run-as: admin
DROP FUNCTION IF EXISTS app.accept_risk_snapshot(uuid,uuid,text,uuid,text,text);
DROP FUNCTION IF EXISTS app.risk_evaluation_snapshot_sha256(app.risk_evaluation_snapshots);
ALTER TABLE app.internal_management_audit_events DROP COLUMN IF EXISTS inherent_snapshot_sha256, DROP COLUMN IF EXISTS inherent_snapshot_id, DROP COLUMN IF EXISTS evaluation_snapshot_sha256, DROP COLUMN IF EXISTS evaluation_snapshot_id;
ALTER TABLE app.risk_acceptances DROP CONSTRAINT IF EXISTS risk_acceptances_evaluation_snapshot_fk, DROP CONSTRAINT IF EXISTS risk_acceptances_inherent_snapshot_fk;
ALTER TABLE app.risk_acceptances DROP COLUMN IF EXISTS inherent_snapshot_sha256, DROP COLUMN IF EXISTS inherent_snapshot_id, DROP COLUMN IF EXISTS evaluation_snapshot_sha256, DROP COLUMN IF EXISTS evaluation_snapshot_id;
