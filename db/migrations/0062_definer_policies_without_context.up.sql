-- @run-as: admin
-- 0062: schema_owner 向けポリシーを、テナント文脈が無くても例外を投げない形にする（設計書 2026-09-11 §9.3）
--
-- 症状: 新規に migrate した DB で scripts/new_tenant.py（app.provision_tenant）と
-- db/seeds/0009_relationships.sql が「tenant context is not set」で落ちる。
--
-- 原因: 0050 以降、schema_owner 向けに付けた management_definer_access /
-- tenant_security_definer / verification_receipt_definer_insert が
-- `tenant_id = app.current_tenant()` を直接呼んでいる。app.current_tenant() は
-- 文脈が無いと RAISE する。PostgreSQL は同じコマンドに当たる permissive ポリシーを
-- OR で評価するので、provision_tenant が 0043 の ctx_user_lock（provisioning_target()）
-- で行ロックを取ろうとしても、隣の management_definer_access が先に評価されて例外になる。
-- seed の DELETE（SET ROLE schema_owner）も同じ。
--
-- 対処: 0059 で既に作ってある app.current_tenant_or_null()（文脈が無ければ NULL）へ差し替える。
-- NULL との比較は偽なので、文脈が無いときは「このポリシーでは何も見えない」になるだけで、
-- 他のポリシー（provisioning_target() 等）の判定を邪魔しない。文脈があるときの意味は変わらない。
-- `(SELECT ...)` で包むのは、行ごとではなく 1 クエリにつき 1 回だけ評価させるため
-- （current_tenant_or_null は例外を捕まえるのでサブトランザクションを張る。行ごとに張らせない）。
--
-- 対象は 2026-09-12 に新規 DB で pg_policies を実測して列挙した 30 枚（schema_owner 向けで
-- current_tenant() を直接呼んでいるもの全部）。末尾で「もう残っていない」ことを検査する。
--
-- SET ROLE schema_owner はしない。対象の表は所有者が schema_owner のものと migration 実行者の
-- ものが混ざっており、ALTER POLICY は所有者にしか許されない。@run-as: admin（superuser）のまま流す。

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

-- INSERT 専用なので WITH CHECK だけを持つ。
ALTER POLICY verification_receipt_definer_insert ON app.verification_receipts
  WITH CHECK (tenant_id = (SELECT app.current_tenant_or_null()));

-- 取りこぼしが無いこと。schema_owner 向けで current_tenant() を直に呼ぶポリシーが 1 枚でも残っていれば落とす。
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
