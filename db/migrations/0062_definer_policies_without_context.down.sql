-- @run-as: admin
-- Rollback of 0062: revert the schema_owner policies to calling app.current_tenant() directly.
-- Reverting makes new_tenant.py and the seeds fail again on a fresh DB (see 0062's up).
-- For the same reason as up, no SET ROLE schema_owner (table owners are mixed).

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('approvals', 'management_definer_access'),
      ('asset_frameworks', 'management_definer_access'),
      ('framework_backfill_provenance', 'management_definer_access'),
      ('framework_relation_events', 'management_definer_access'),
      ('framework_relation_origins', 'management_definer_access'),
      ('internal_management_acceptance_approvals', 'management_definer_access'),
      ('internal_management_audit_events', 'management_definer_access'),
      ('internal_management_operations', 'management_definer_access'),
      ('iso_framework_removal_requests', 'management_definer_access'),
      ('mail_outbox', 'tenant_security_definer'),
      ('management_deviation_controls', 'management_definer_access'),
      ('management_deviation_evidence', 'management_definer_access'),
      ('management_deviation_operation_receipts', 'management_definer_access'),
      ('management_deviation_risks', 'management_definer_access'),
      ('management_deviations', 'management_definer_access'),
      ('measure_change_history', 'management_definer_access'),
      ('measure_frameworks', 'management_definer_access'),
      ('memberships', 'management_definer_access'),
      ('policy_versions', 'management_definer_access'),
      ('questionnaire_template_questions', 'tenant_security_definer'),
      ('questionnaire_templates', 'tenant_security_definer'),
      ('risk_acceptances', 'management_definer_access'),
      ('risk_evaluation_snapshots', 'management_definer_access'),
      ('risk_scenario_frameworks', 'management_definer_access'),
      ('risk_scenarios', 'management_definer_access'),
      ('security_objectives', 'management_definer_access'),
      ('users', 'management_definer_access'),
      ('work_item_assignees', 'tenant_security_definer'),
      ('work_items', 'tenant_security_definer')
    ) AS t(tbl, pol)
  LOOP
    EXECUTE format(
      'ALTER POLICY %I ON app.%I USING (tenant_id = app.current_tenant()) WITH CHECK (tenant_id = app.current_tenant())',
      r.pol, r.tbl);
  END LOOP;
END $$;

ALTER POLICY verification_receipt_definer_insert ON app.verification_receipts
  WITH CHECK (tenant_id = app.current_tenant());

RESET ROLE;
