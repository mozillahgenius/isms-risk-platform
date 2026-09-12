-- @run-as: admin
-- 0062: make schema_owner policies not throw when there is no tenant context (design doc 2026-09-11 §9.3)
--
-- Symptom: on a freshly migrated DB, scripts/new_tenant.py (app.provision_tenant) and
-- db/seeds/0009_relationships.sql fail with "tenant context is not set".
--
-- Cause: since 0050, management_definer_access /
-- tenant_security_definer / verification_receipt_definer_insert, added for schema_owner,
-- call `tenant_id = app.current_tenant()` directly. app.current_tenant()
-- RAISEs when there is no context. PostgreSQL evaluates the permissive policies for the same command
-- with OR, so even when provision_tenant tries to take a row lock via 0043's ctx_user_lock (provisioning_target()),
-- the neighboring management_definer_access is evaluated first and raises.
-- The same applies to the seed's DELETE (SET ROLE schema_owner).
--
-- Fix: switch to app.current_tenant_or_null() (NULL when there is no context), already created in 0059.
-- Comparison with NULL is false, so without a context it just means "this policy sees nothing",
-- without interfering with other policies (provisioning_target() etc.). The meaning with a context is unchanged.
-- It is wrapped in `(SELECT ...)` so it is evaluated once per query rather than per row
-- (current_tenant_or_null catches exceptions and thus opens a subtransaction; do not make it open one per row).
--
-- Targets are the 30 policies enumerated by measuring pg_policies on a fresh DB on 2026-09-12 (all those for schema_owner
-- that call current_tenant() directly). The end of the file checks that "none remain".
--
-- No SET ROLE schema_owner. The target tables are a mix of ones owned by schema_owner and ones owned by the migration
-- runner, and ALTER POLICY is allowed only for the owner. Run as @run-as: admin (superuser).

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
      'ALTER POLICY %I ON app.%I USING (tenant_id = (SELECT app.current_tenant_or_null())) WITH CHECK (tenant_id = (SELECT app.current_tenant_or_null()))',
      r.pol, r.tbl);
  END LOOP;
END $$;

-- INSERT-only, so it has only WITH CHECK.
ALTER POLICY verification_receipt_definer_insert ON app.verification_receipts
  WITH CHECK (tenant_id = (SELECT app.current_tenant_or_null()));

-- Nothing missed. Fail if even one schema_owner policy that calls current_tenant() directly remains.
DO $$
DECLARE
  leftover text;
BEGIN
  SELECT string_agg(tablename || '.' || policyname, ', ')
    INTO leftover
    FROM pg_catalog.pg_policies
   WHERE schemaname = 'app'
     AND 'schema_owner' = ANY (roles)
     AND (coalesce(qual, '') LIKE '%app.current_tenant()%' OR coalesce(with_check, '') LIKE '%app.current_tenant()%');
  IF leftover IS NOT NULL THEN
    RAISE EXCEPTION '0062: current_tenant() を直に呼ぶ schema_owner ポリシーが残っています: %', leftover;
  END IF;
END $$;

RESET ROLE;
