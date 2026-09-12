-- @run-as: admin
-- M2/M3 evidence is append-only and has no representation in 0051.  Refuse
-- rollback before dropping any receipt, deviation, history, or expiry data.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM app.management_deviations)
     OR EXISTS (SELECT 1 FROM app.management_deviation_risks)
     OR EXISTS (SELECT 1 FROM app.management_deviation_controls)
     OR EXISTS (SELECT 1 FROM app.management_deviation_evidence)
     OR EXISTS (SELECT 1 FROM app.management_deviation_operation_receipts)
     OR EXISTS (SELECT 1 FROM app.measure_change_history)
     OR EXISTS (SELECT 1 FROM app.risk_acceptances WHERE expires_at IS NOT NULL)
     OR EXISTS (SELECT 1 FROM app.internal_management_operations
                 WHERE action='accept_risk' AND origin_kind='human')
     OR EXISTS (SELECT 1 FROM app.internal_management_audit_events
                 WHERE action='accept_risk' AND origin_kind='human') THEN
    RAISE EXCEPTION '0052 rollback blocked by non-representable management evidence';
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION app.accept_risk_snapshot_human_evidenced(text,text,uuid,uuid,text,uuid,text,text,timestamptz,uuid,text) FROM app_rw;
DROP FUNCTION IF EXISTS app.accept_risk_snapshot_human_evidenced(text,text,uuid,uuid,text,uuid,text,text,timestamptz,uuid,text);
REVOKE EXECUTE ON FUNCTION app.accept_risk_snapshot_with_expiry(uuid,uuid,text,uuid,text,text,timestamptz) FROM app_rw;
DROP FUNCTION IF EXISTS app.accept_risk_snapshot_with_expiry(uuid,uuid,text,uuid,text,text,timestamptz);
REVOKE EXECUTE ON FUNCTION app.request_management_deviation(text,text,text,text,text,uuid,timestamptz,timestamptz,uuid[],uuid[],uuid[]) FROM app_rw;
REVOKE EXECUTE ON FUNCTION app.approve_management_deviation(uuid,text,text),app.close_management_deviation(uuid,text,text,text),app.expire_management_deviations() FROM app_rw;
DROP FUNCTION IF EXISTS app.expire_management_deviations();
DROP FUNCTION IF EXISTS app.close_management_deviation(uuid,text,text,text);
DROP FUNCTION IF EXISTS app.approve_management_deviation(uuid,text,text);
DROP FUNCTION IF EXISTS app.request_management_deviation(text,text,text,text,text,uuid,timestamptz,timestamptz,uuid[],uuid[],uuid[]);
DROP TRIGGER IF EXISTS measure_change_history_immutable ON app.measure_change_history;
DROP TRIGGER IF EXISTS measures_record_change ON app.measures;
DROP FUNCTION IF EXISTS app.record_measure_change();
DROP POLICY IF EXISTS management_definer_access ON app.measure_change_history;
DROP POLICY IF EXISTS tenant_read ON app.measure_change_history;
DROP POLICY IF EXISTS tenant_isolation ON app.measure_change_history;
DROP TABLE IF EXISTS app.measure_change_history;
DROP POLICY IF EXISTS management_definer_access ON app.management_deviation_evidence;
DROP POLICY IF EXISTS tenant_read ON app.management_deviation_evidence;
DROP POLICY IF EXISTS tenant_isolation ON app.management_deviation_evidence;
DROP TABLE IF EXISTS app.management_deviation_evidence;
DROP TRIGGER IF EXISTS management_deviation_operation_receipts_immutable ON app.management_deviation_operation_receipts;
DROP POLICY IF EXISTS management_definer_access ON app.management_deviation_operation_receipts;
DROP POLICY IF EXISTS tenant_read ON app.management_deviation_operation_receipts;
DROP POLICY IF EXISTS tenant_isolation ON app.management_deviation_operation_receipts;
DROP TABLE IF EXISTS app.management_deviation_operation_receipts;
DROP POLICY IF EXISTS management_definer_access ON app.management_deviation_controls;
DROP POLICY IF EXISTS tenant_read ON app.management_deviation_controls;
DROP POLICY IF EXISTS tenant_isolation ON app.management_deviation_controls;
DROP TABLE IF EXISTS app.management_deviation_controls;
DROP POLICY IF EXISTS management_definer_access ON app.management_deviation_risks;
DROP POLICY IF EXISTS tenant_read ON app.management_deviation_risks;
DROP POLICY IF EXISTS tenant_isolation ON app.management_deviation_risks;
DROP TABLE IF EXISTS app.management_deviation_risks;
DROP POLICY IF EXISTS management_definer_access ON app.management_deviations;
DROP POLICY IF EXISTS tenant_read ON app.management_deviations;
DROP POLICY IF EXISTS tenant_isolation ON app.management_deviations;
DROP TABLE IF EXISTS app.management_deviations;
DROP VIEW IF EXISTS app.risk_acceptance_status;
DROP TRIGGER IF EXISTS risk_acceptances_future_expiry ON app.risk_acceptances;
DROP FUNCTION IF EXISTS app.require_future_risk_acceptance_expiry();
ALTER TABLE app.risk_acceptances DROP COLUMN IF EXISTS expires_at;
