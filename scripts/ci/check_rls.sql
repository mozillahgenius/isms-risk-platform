-- Quality gate from design doc 11.5: "RLS coverage" + role attributes + effective privileges.
-- Fails via RAISE EXCEPTION on even a single violation (use with psql -v ON_ERROR_STOP=1).
--
-- ALTER DEFAULT PRIVILEGES is not retroactive to existing objects, so rather than relying on it
-- we inspect "the privileges that exist right now" directly with aclexplode.

\set ON_ERROR_STOP on

DO $$
DECLARE
  v_bad text;
  n int;
  k text;
  v_expect_qual constant text := '(tenant_id = app.current_tenant())';
  -- Definer-only tables (tables for which app_rw / app_ro get no table privileges)
  definer_only constant text[] := ARRAY['sessions','tenant_context_keys','verification_receipts',
    'internal_management_service_principals','internal_management_acceptance_approvals'];
  management_append_only constant text[] := ARRAY['risk_acceptances','framework_relation_events','internal_management_operations','internal_management_audit_events'];
  management_frameworks constant text[] := ARRAY['asset_frameworks','risk_scenario_frameworks','measure_frameworks'];
  management_provenance constant text[] := ARRAY['framework_relation_origins','framework_backfill_provenance','iso_framework_removal_requests',
    'internal_management_service_principals','internal_management_acceptance_approvals','approvals'];
BEGIN
  ---------------------------------------------------------------- 1
  -- app tables with tenant_id must have both ENABLE and FORCE RLS
  SELECT string_agg(c.relname, ', ') INTO v_bad
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
   WHERE n.nspname = 'app' AND c.relkind = 'r'
     AND NOT (c.relrowsecurity AND c.relforcerowsecurity);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'RLS 未適用（ENABLE+FORCE が揃っていない）: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 2
  -- app.tenants has no tenant_id column, so it slips through the net above. Check it separately.
  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname='app' AND c.relname='tenants'
                    AND c.relrowsecurity AND c.relforcerowsecurity) THEN
    RAISE EXCEPTION 'app.tenants に ENABLE+FORCE ROW LEVEL SECURITY が無い';
  END IF;

  ---------------------------------------------------------------- 3
  -- Both policies must exist. Check not just the names but also cmd, target roles, qual,
  -- and with_check (don't pass a wrong policy that merely shares the name).
  SELECT string_agg(format('%s(%s)', t.relname, reason), ', ') INTO v_bad
  FROM (
    SELECT c.relname,
           CASE
             WHEN p.policyname IS NULL THEN 'tenant_isolation なし'
             WHEN p.cmd <> 'ALL' THEN 'cmd=' || p.cmd
             WHEN p.roles <> ARRAY['app_rw']::name[] THEN 'roles=' || p.roles::text
             WHEN p.qual <> v_expect_qual THEN 'qual=' || coalesce(p.qual,'null')
             WHEN p.with_check IS DISTINCT FROM v_expect_qual
               THEN 'with_check=' || coalesce(p.with_check,'null')
             WHEN NOT p.permissive THEN 'restrictive'
           END AS reason
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname='tenant_id' AND NOT a.attisdropped
      LEFT JOIN (SELECT schemaname, tablename, policyname, cmd, roles, qual, with_check,
                        (permissive = 'PERMISSIVE') AS permissive
                   FROM pg_policies WHERE policyname = 'tenant_isolation') p
             ON p.schemaname='app' AND p.tablename = c.relname
     WHERE n.nspname='app' AND c.relkind='r'
       AND NOT (c.relname = ANY(definer_only))
  ) t
  WHERE t.reason IS NOT NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'tenant_isolation ポリシーの内容不一致: %', v_bad;
  END IF;

  SELECT string_agg(format('%s(%s)', t.relname, reason), ', ') INTO v_bad
  FROM (
    SELECT c.relname,
           CASE
             WHEN p.policyname IS NULL THEN 'tenant_read なし'
             WHEN p.cmd <> 'SELECT' THEN 'cmd=' || p.cmd
             WHEN p.roles <> ARRAY['app_ro']::name[] THEN 'roles=' || p.roles::text
             WHEN p.qual <> v_expect_qual THEN 'qual=' || coalesce(p.qual,'null')
           END AS reason
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname='tenant_id' AND NOT a.attisdropped
      LEFT JOIN (SELECT schemaname, tablename, policyname, cmd, roles, qual
                   FROM pg_policies WHERE policyname = 'tenant_read') p
             ON p.schemaname='app' AND p.tablename = c.relname
     WHERE n.nspname='app' AND c.relkind='r'
       AND NOT (c.relname = ANY(definer_only))
  ) t
  WHERE t.reason IS NOT NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'tenant_read ポリシーの内容不一致: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 3b
  -- No unexpected policies have been added.
  -- Checking only that "the correct policies exist" would still pass if a permissive
  -- USING (true) policy were added alongside (policies are OR-combined, so it becomes a hole).
  SELECT string_agg(format('%s.%s', tablename, policyname), ', ') INTO v_bad
    FROM pg_policies
   WHERE schemaname = 'app'
     AND policyname NOT IN ('tenant_isolation','tenant_read',
                            'ctx_session_lookup','ctx_membership_lookup',
                            'ctx_user_lookup','ctx_user_lock','ctx_tenant_lookup','ctx_deviation_lookup',
                            -- For tenant creation, added in 0021 (definer only; only the one tenant being created)
                            'prov_tenant_insert','prov_user_insert','prov_membership_insert',
                            'prov_policy_insert','prov_policy_version_insert',
                            -- The agent intake path from 0026. Used only by schema_owner's no-login function.
                            'agent_device_definer_read','agent_device_definer_insert',
                            'agent_device_definer_update','agent_snapshot_definer_read',
                            'agent_snapshot_definer_insert',
                            'agent_token_access',
                            'verification_receipt_definer_insert','verification_receipt_definer_read',
                            'hr_projection_identity_read','hr_projection_identity_insert',
                            'hr_projection_identity_update','hr_projection_account_read',
                            'hr_projection_account_update','hr_projection_device_update',
                            'management_definer_access','management_service_principal_read',
                            'management_service_principal_provision',
                            -- For the definer and send worker in 0057-0061. They were missing from the allowlist, so
                            -- the agent acceptance test on a fresh DB failed here (same at 970c42a; measured 2026-09-12).
                            'tenant_security_definer','tenant_security_definer_read','tenant_worker_read',
                            -- 0067's records role policies (RESTRICTIVE; shape and target tables are pinned below).
                            'records_role_insert','records_role_update','records_role_delete');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '想定外のポリシーがある: %', v_bad;
  END IF;

  -- Shape of the 0057-0062 definer / send-worker policies. Merely adding names to the allowlist would
  -- still pass if one were rewritten to USING (true) under the same name (Codex review 2026-09-12 finding).
  -- Only the two ways of writing "restrict by tenant context" are accepted (0062's (SELECT ...) form and the earlier direct-call form).
  -- Rows where the CASE returns NULL (NULL condition) are also rejected, so coalesce to false.
  SELECT string_agg(format('%s.%s(roles=%s cmd=%s qual=%s check=%s)', tablename, policyname, roles::text, cmd,
                           coalesce(qual, '(null)'), coalesce(with_check, '(null)')), ', ') INTO v_bad
    FROM pg_policies
   WHERE schemaname = 'app'
     AND policyname IN ('tenant_security_definer', 'tenant_security_definer_read', 'tenant_worker_read')
     AND NOT coalesce(CASE policyname
       WHEN 'tenant_security_definer' THEN
         roles = ARRAY['schema_owner']::name[] AND cmd = 'ALL'
         AND qual IN ('(tenant_id = app.current_tenant_or_null())',
                      '(tenant_id = ( SELECT app.current_tenant_or_null() AS current_tenant_or_null))')
         AND with_check = qual
       WHEN 'tenant_security_definer_read' THEN
         roles = ARRAY['schema_owner']::name[] AND cmd = 'SELECT' AND with_check IS NULL
         AND qual IN ('(tenant_id = app.current_tenant_or_null())',
                      '(tenant_id = ( SELECT app.current_tenant_or_null() AS current_tenant_or_null))')
       WHEN 'tenant_worker_read' THEN
         roles = ARRAY['mail_worker']::name[] AND cmd = 'SELECT' AND with_check IS NULL
         AND tablename = 'mail_outbox' AND qual = '(tenant_id = app.current_tenant())'
     END, false);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '定義者・送信ワーカー向けポリシーの形が想定外: %', v_bad;
  END IF;

  -- Pin not only the shape but also which tables they are attached to (both directions).
  -- Fail if one goes missing from a target table, or if one with the same name and shape appears on another table (Codex review 2026-09-12, round 2 finding).
  -- When adding a table, adding it here is the record of the decision to "open a definer path to that table".
  SELECT string_agg(coalesce(e.pol || '.' || e.tbl || '(欠落)', a.pol || '.' || a.tbl || '(想定外)'), ', ') INTO v_bad
    FROM (VALUES
      ('tenant_security_definer', 'application_catalog'),
      -- 0070: because the approve/reject function for change requests (decide_change_request) reads and writes requests.
      ('tenant_security_definer', 'change_requests'),
      ('tenant_security_definer', 'department_systems'),
      ('tenant_security_definer', 'external_questionnaires'),
      ('tenant_security_definer', 'mail_outbox'),
      ('tenant_security_definer', 'questionnaire_template_questions'),
      ('tenant_security_definer', 'questionnaire_templates'),
      -- 0075: because the trigger function (record_row_transition) writes the transition records.
      ('tenant_security_definer', 'row_transitions'),
      ('tenant_security_definer', 'work_item_assignees'),
      ('tenant_security_definer', 'work_items'),
      ('tenant_security_definer_read', 'assets'),
      -- 0063: because the management review approval function (approve_management_review) reads the minutes.
      ('tenant_security_definer_read', 'management_reviews'),
      ('tenant_worker_read', 'mail_outbox')
    ) AS e(pol, tbl)
    FULL JOIN (
      SELECT policyname::text AS pol, tablename::text AS tbl FROM pg_policies
       WHERE schemaname = 'app'
         AND policyname IN ('tenant_security_definer', 'tenant_security_definer_read', 'tenant_worker_read')
    ) AS a ON a.pol = e.pol AND a.tbl = e.tbl
   WHERE e.pol IS NULL OR a.pol IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '定義者・送信ワーカー向けポリシーの対象表が想定と違う: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 3c2
  -- 0067's records role policies. Pin not only the names but also the tables they are attached to (both directions) and the shape.
  -- Shape: app_rw, RESTRICTIVE, command as the name says, condition is only (SELECT app.records_role_allows('<that table's kind>')).
  -- If rewritten to PERMISSIVE, OR-combination removes the restriction; if the condition is made true, anyone can write. Fail both.
  -- When adding a table, adding it here is the record of the decision to "restrict that table by role".
  -- Also check the permission function itself. When the caller is unknown (no session), it must not return "allow" for any kind.
  -- Without a session current_session_user() fails with insufficient_privilege, so false or that exception is acceptable
  -- (2026-09-12 Codex review: calling it without catching the exception made this check itself fail on a plain connection).
  -- If the body were rewritten to RETURN true, anyone could write even with correctly shaped policies. Check every kind in the permission table
  -- (fail even if only the branch for a kind with no attached table is rewritten). Per-role allow/deny is verified with real writes by tests/isms_registers.sh.
  v_bad := NULL;
  FOREACH k IN ARRAY ARRAY['audit','corrective','effectiveness','management_review','objective','evidence',
                           'exception','context','legal','continuity','vulnerability','change','import'] LOOP
    BEGIN
      IF app.records_role_allows(k) IS DISTINCT FROM false THEN
        v_bad := concat_ws(', ', v_bad, k);
      END IF;
    EXCEPTION WHEN insufficient_privilege THEN
      -- Failing because the caller is unknown means "not allowed", so it is acceptable. An unknown kind (unknown record kind) is not caught here; the whole check fails.
      NULL;
    END;
  END LOOP;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '記録の許可関数が、本人不明でも許している: %', v_bad;
  END IF;
  -- Don't use a same-named temp table created earlier in the same session (always recreate it so the expected values can't be swapped).
  DROP TABLE IF EXISTS pg_temp.records_role_expected;
  CREATE TEMP TABLE pg_temp.records_role_expected ON COMMIT DROP AS
    SELECT v.tbl, p.pol, p.cmd,
           format('( SELECT app.records_role_allows(%L::text) AS records_role_allows)', v.kind) AS cond
      FROM (VALUES ('control_effectiveness', 'effectiveness'), ('context_issues', 'context'),
                   ('interested_parties', 'context'), ('legal_requirements', 'legal'),
                   -- 0068: business continuity plans and tests
                   ('continuity_plans', 'continuity'), ('continuity_tests', 'continuity'),
                   -- 0069: vulnerabilities
                   ('vulnerabilities', 'vulnerability'),
                   -- 0070: change requests (DELETE is not granted, but the policy is attached anyway for a consistent shape)
                   ('change_requests', 'change'),
                   -- 0071: import records (no UPDATE / DELETE privileges, but the policy is attached anyway for a consistent shape)
                   ('import_batches', 'import'), ('import_batch_items', 'import'), ('import_undos', 'import')) AS v(tbl, kind)
     CROSS JOIN (VALUES ('records_role_insert', 'INSERT'), ('records_role_update', 'UPDATE'),
                        ('records_role_delete', 'DELETE')) AS p(pol, cmd);
  SELECT string_agg(coalesce(e.tbl || '.' || e.pol || '(欠落)', a.tbl || '.' || a.pol || '(想定外)'), ', ') INTO v_bad
    FROM pg_temp.records_role_expected e
    FULL JOIN (
      SELECT tablename::text AS tbl, policyname::text AS pol FROM pg_policies
       WHERE schemaname = 'app' AND policyname IN ('records_role_insert', 'records_role_update', 'records_role_delete')
    ) AS a ON a.tbl = e.tbl AND a.pol = e.pol
   WHERE e.pol IS NULL OR a.pol IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '記録の役割ポリシーの対象表が想定と違う: %', v_bad;
  END IF;
  SELECT string_agg(format('%s.%s(permissive=%s roles=%s cmd=%s qual=%s check=%s)', p.tablename, p.policyname,
                           p.permissive, p.roles::text, p.cmd, coalesce(p.qual, '(null)'), coalesce(p.with_check, '(null)')), ', ')
    INTO v_bad
    FROM pg_policies p
    JOIN pg_temp.records_role_expected e ON e.tbl = p.tablename AND e.pol = p.policyname
   WHERE p.schemaname = 'app'
     AND NOT coalesce(
       p.permissive = 'RESTRICTIVE' AND p.roles = ARRAY['app_rw']::name[] AND p.cmd = e.cmd
       AND CASE e.cmd
             WHEN 'INSERT' THEN p.qual IS NULL AND p.with_check = e.cond
             WHEN 'UPDATE' THEN p.qual = e.cond AND p.with_check = e.cond
             WHEN 'DELETE' THEN p.qual = e.cond AND p.with_check IS NULL
           END, false);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '記録の役割ポリシーの形が想定外: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 3c3
  -- Privilege boundary of 0070 change requests. The safeguards against forged approvals must not have been removed (Codex review 2026-09-12).
  --   app_rw has no DELETE (requests and approval records can't be deleted; a request can only be withdrawn)
  --   the decision function is owned by schema_owner, SECURITY DEFINER, with no EXECUTE for PUBLIC
  --   the triggers protecting the transition and decision columns are enabled
  IF has_table_privilege('app_rw', 'app.change_requests', 'DELETE') THEN
    RAISE EXCEPTION 'app_rw が change_requests を DELETE できる（申請は取りやめるだけのはず）';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_roles o ON o.oid = p.proowner
                  WHERE p.oid = 'app.decide_change_request(uuid,boolean,text)'::regprocedure
                    AND p.prosecdef AND o.rolname = 'schema_owner') THEN
    RAISE EXCEPTION 'decide_change_request が schema_owner 所有の SECURITY DEFINER でない';
  END IF;
  IF has_function_privilege('public', 'app.decide_change_request(uuid,boolean,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'decide_change_request を PUBLIC が実行できる';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'app.change_requests'::regclass
                  AND tgname = 'change_requests_guard' AND tgenabled = 'O' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'change_requests_guard トリガが無いか無効';
  END IF;
  -- Guard triggers of 0070-0072. Pin not only names but also enabled state, called function, and timing/event (tgtype)
  -- (changing BEFORE INSERT to BEFORE UPDATE keeps the name but stops filling in the actor and timestamp. Codex review 2026-09-12).
  -- tgtype bits: ROW=1 BEFORE=2 INSERT=4 DELETE=8 UPDATE=16.
  SELECT string_agg(e.tbl || '.' || e.tg, ', ') INTO v_bad
    FROM (VALUES ('import_batches',     'import_batches_stamp',           'app.import_log_stamp()',       7),
                 ('import_undos',       'import_undos_stamp',             'app.import_log_stamp()',       7),
                 ('import_batch_items', 'import_batch_items_guard',       'app.import_items_guard()',     7),
                 ('import_batches',     'import_batches_complete',        'app.import_batch_complete()',  5),
                 ('assets',             'assets_keep_created_at',         'app.keep_created_at()',       19),
                 ('risk_scenarios',     'risk_scenarios_keep_created_at', 'app.keep_created_at()',       19),
                 ('departments',        'departments_keep_created_at',    'app.keep_created_at()',       19),
                 -- 0076: policies and versions (so the import detail's "created in this transaction" judgment can't be falsified)
                 ('policies',           'policies_keep_created_at',        'app.keep_created_at()',      19),
                 ('policy_versions',    'policy_versions_keep_created_at', 'app.keep_created_at()',      19),
                 -- 0075: transition records (AFTER UPDATE row trigger. If removed, the detail and undo counts lose their basis and fall to the rejecting side)
                 ('assets',             'assets_status_transition',          'app.record_row_transition()', 17),
                 ('risk_scenarios',     'risk_scenarios_status_transition',  'app.record_row_transition()', 17),
                 ('memberships',        'memberships_department_transition', 'app.record_row_transition()', 17),
                 -- 0077: created-row records (AFTER INSERT row trigger. The basis for the detail's "created in this transaction")
                 ('assets',             'assets_created_transition',          'app.record_row_transition()', 5),
                 ('risk_scenarios',     'risk_scenarios_created_transition',  'app.record_row_transition()', 5),
                 ('departments',        'departments_created_transition',     'app.record_row_transition()', 5),
                 ('policies',           'policies_created_transition',        'app.record_row_transition()', 5),
                 ('policy_versions',    'policy_versions_created_transition', 'app.record_row_transition()', 5),
                 ('change_requests',    'change_requests_guard',          'app.change_requests_guard()', 23)) AS e(tbl, tg, fn, typ)
   WHERE NOT EXISTS (SELECT 1 FROM pg_trigger t
                      WHERE t.tgrelid = to_regclass('app.' || e.tbl) AND t.tgname = e.tg
                        AND t.tgenabled = 'O' AND NOT t.tgisinternal
                        AND t.tgfoid = e.fn::regprocedure AND t.tgtype = e.typ);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '取り込みの記録のトリガが無いか無効: %', v_bad;
  END IF;
  -- 0075: transition records are written only by the trigger function (owned by schema_owner, SECURITY DEFINER). app_rw / app_ro can only read
  -- (if they could write, they could forge "original department" or "retired" records).
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_roles o ON o.oid = p.proowner
                  WHERE p.oid = 'app.record_row_transition()'::regprocedure
                    AND p.prosecdef AND o.rolname = 'schema_owner') THEN
    RAISE EXCEPTION 'record_row_transition が schema_owner 所有の SECURITY DEFINER でない';
  END IF;
  IF has_table_privilege('app_rw', 'app.row_transitions', 'INSERT')
     OR has_table_privilege('app_ro', 'app.row_transitions', 'INSERT') THEN
    RAISE EXCEPTION 'app_rw / app_ro が row_transitions に INSERT できる（トリガだけが書くはず）';
  END IF;

  ---------------------------------------------------------------- 3d
  -- Phase 3a definer policies. Rather than just adding names to the allowlist,
  -- pin and check target roles, command, and USING / WITH CHECK.
  SELECT count(*) INTO n FROM pg_policies
   WHERE schemaname = 'app'
     AND policyname = ANY (ARRAY[
       'agent_device_definer_read','agent_device_definer_insert',
       'agent_device_definer_update','agent_snapshot_definer_read',
       'agent_snapshot_definer_insert','agent_token_access']);
  IF n <> 6 THEN
    RAISE EXCEPTION 'Phase 3a agent policy が 6 本揃っていない（% 本）', n;
  END IF;
  SELECT string_agg(format('%s.%s', tablename, policyname), ', ') INTO v_bad
    FROM pg_policies
   WHERE schemaname = 'app'
     AND policyname LIKE 'agent\_%'
     AND (
       roles <> ARRAY['schema_owner']::name[] OR
       CASE policyname
         WHEN 'agent_device_definer_read' THEN
           cmd <> 'SELECT' OR qual IS DISTINCT FROM 'true' OR with_check IS NOT NULL
         WHEN 'agent_device_definer_insert' THEN
           cmd <> 'INSERT' OR qual IS NOT NULL
             OR with_check IS DISTINCT FROM '(tenant_id = app.agent_tenant_target())'
         WHEN 'agent_device_definer_update' THEN
           cmd <> 'UPDATE' OR qual IS DISTINCT FROM 'true'
             OR with_check IS DISTINCT FROM '(tenant_id = app.agent_tenant_target())'
         WHEN 'agent_snapshot_definer_read' THEN
           cmd <> 'SELECT' OR qual IS DISTINCT FROM 'true' OR with_check IS NOT NULL
         WHEN 'agent_snapshot_definer_insert' THEN
           cmd <> 'INSERT' OR qual IS NOT NULL
             OR with_check IS DISTINCT FROM '(tenant_id = app.agent_tenant_target())'
         WHEN 'agent_token_access' THEN
           cmd <> 'ALL' OR qual IS DISTINCT FROM 'true' OR with_check IS DISTINCT FROM 'true'
         ELSE false
       END
     );
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Phase 3a agent policy の形が想定外: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 3c
  -- Shape of the tenant-creation policy. If this loosens, we regress to "a definer can create rows for other tenants too".
  -- Three things are checked: target role is only schema_owner / INSERT only / WITH CHECK is
  -- bound to provisioning_target().
  SELECT string_agg(format('%s.%s(cmd=%s roles=%s check=%s)',
                           tablename, policyname, cmd, roles::text, coalesce(with_check,'(null)')),
                    ', ') INTO v_bad
    FROM pg_policies
   WHERE schemaname = 'app'
     AND policyname LIKE 'prov\_%'
     AND (roles <> ARRAY['schema_owner']::name[]
       OR cmd <> 'INSERT'
       OR with_check IS NULL
       OR with_check NOT LIKE '%provisioning_target()%'
       OR qual IS NOT NULL);  -- must not have spread to the read side
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'テナント作成用ポリシーの形が想定外: %', v_bad;
  END IF;

  -- Pin the target table too (it must not have spread to new tables on its own)
  SELECT string_agg(format('%s.%s', tablename, policyname), ', ') INTO v_bad
    FROM pg_policies
   WHERE schemaname = 'app' AND policyname LIKE 'prov\_%'
     AND tablename NOT IN ('tenants','users','memberships','policies','policy_versions');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'テナント作成用ポリシーが想定外の表にある: %', v_bad;
  END IF;

  -- The two definer policies must have fixed target tables and target roles
  SELECT string_agg(format('%s.%s(%s)', tablename, policyname, roles::text), ', ') INTO v_bad
    FROM pg_policies
   WHERE schemaname = 'app'
     AND policyname IN ('ctx_session_lookup','ctx_membership_lookup',
                        'ctx_user_lookup','ctx_tenant_lookup','ctx_deviation_lookup')
     AND (roles <> ARRAY['schema_owner']::name[]
       OR tablename NOT IN ('sessions','memberships','users','tenants','deviations'));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '定義者向けポリシーの対象が想定外: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 4
  -- Role attributes. Having BYPASSRLS / SUPERUSER breaks the RLS guarantee.
  SELECT string_agg(rolname, ', ') INTO v_bad FROM pg_roles
   WHERE rolname IN ('schema_owner','app_rw','app_ro','auth_svc','auditlogd','audit_verifier')
     AND (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '過剰なロール属性: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 5
  -- Transitive closure of role membership. app_rw / app_ro must not be able to reach schema_owner
  -- (if they could, SET ROLE would make them the owner and let them swap policies).
  SELECT string_agg(format('%s -> %s', m.member::regrole, m.roleid::regrole), ', ')
    INTO v_bad
    FROM pg_auth_members m
   -- Include auth_svc too. Even with NOINHERIT, a member of schema_owner
   -- can become the owner via SET ROLE.
   WHERE m.member::regrole::text
         IN ('app_rw','app_ro','auth_svc','auditlogd','audit_verifier');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'アプリロールが他ロールのメンバーになっている: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 6
  -- app_rw / app_ro must not own tables in app / catalog / audit
  SELECT string_agg(format('%s.%s', n.nspname, c.relname), ', ') INTO v_bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname IN ('app','catalog','audit')
     AND c.relowner::regrole::text
         IN ('app_rw','app_ro','auth_svc','auditlogd','audit_verifier');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'アプリロールがテーブル所有者になっている: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 7
  -- Effective privileges. Nothing equivalent to GRANT ALL (TRUNCATE / REFERENCES / TRIGGER) is granted
  SELECT string_agg(format('%s.%s:%s:%s', n.nspname, c.relname,
                           g.grantee::regrole, g.privilege_type), ', ') INTO v_bad
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(c.relacl) g
   WHERE n.nspname IN ('app','catalog','audit')
     -- Also check privileges via PUBLIC (grantee=0 is PUBLIC; filtering only by role name misses it)
     AND (g.grantee = 0 OR g.grantee::regrole::text IN ('app_rw','app_ro'))
     AND g.privilege_type IN ('TRUNCATE','REFERENCES','TRIGGER');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '過剰な権限（TRUNCATE/REFERENCES/TRIGGER）: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 8
  -- catalog is read-only for tenant roles
  SELECT string_agg(format('%s:%s:%s', c.relname, g.grantee::regrole, g.privilege_type), ', ')
    INTO v_bad
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(c.relacl) g
   WHERE n.nspname = 'catalog' AND c.relkind = 'r'
     -- Also check privileges via PUBLIC (grantee=0 is PUBLIC; filtering only by role name misses it)
     AND (g.grantee = 0 OR g.grantee::regrole::text IN ('app_rw','app_ro'))
     AND g.privilege_type <> 'SELECT';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'catalog に SELECT 以外の権限が付いている: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 9
  -- No privileges leak to definer-only tables
  SELECT string_agg(format('%s:%s:%s', c.relname, g.grantee::regrole, g.privilege_type), ', ')
    INTO v_bad
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(c.relacl) g
   WHERE n.nspname = 'app' AND c.relname = ANY(definer_only)
     AND g.grantee::regrole::text IN ('app_rw','app_ro','auditlogd','audit_verifier');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '定義者専用テーブルの権限漏れ: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 9b
  -- audit.audit_log. It is outside the app schema net, so check it separately.
  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname='audit' AND c.relname='audit_log'
                    AND c.relrowsecurity AND c.relforcerowsecurity) THEN
    RAISE EXCEPTION 'audit.audit_log に ENABLE+FORCE ROW LEVEL SECURITY が無い';
  END IF;

  -- Appends go only through audit.append(). If auditlogd retained direct privileges
  -- it could bypass the chain and write forged rows.
  SELECT string_agg(format('%s:%s', g.grantee::regrole, g.privilege_type), ', ') INTO v_bad
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) g
   WHERE n.nspname='audit' AND c.relname='audit_log'
     AND (g.grantee = 0 OR g.grantee::regrole::text IN ('auditlogd','app_rw','app_ro'))
     AND g.privilege_type <> 'SELECT';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'audit_log に SELECT 以外の権限が付いている（append を迂回できる）: %', v_bad;
  END IF;

  -- SELECT for app_rw / app_ro / auditlogd must be tenant-scoped
  SELECT string_agg(format('%s(%s)', policyname, roles::text), ', ') INTO v_bad
    FROM pg_policies
   WHERE schemaname='audit' AND tablename='audit_log'
     AND policyname NOT IN ('audit_read','audit_verify','audit_definer_insert','audit_definer_read');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'audit_log に想定外のポリシーがある: %', v_bad;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='audit' AND tablename='audit_log'
                    AND policyname='audit_read' AND cmd='SELECT'
                    AND qual = '(tenant_id = app.current_tenant())') THEN
    RAISE EXCEPTION 'audit_log の audit_read がテナント限定になっていない';
  END IF;
  -- No UPDATE / DELETE policies even for the owner (definer) = past rows cannot be rewritten
  IF EXISTS (SELECT 1 FROM pg_policies
              WHERE schemaname='audit' AND tablename='audit_log'
                AND cmd IN ('UPDATE','DELETE','ALL')) THEN
    RAISE EXCEPTION 'audit_log に UPDATE/DELETE を許すポリシーがある';
  END IF;

  ---------------------------------------------------------------- 10
  -- Tenant-facing views must not bypass RLS (security_invoker required)
  SELECT string_agg(c.relname, ', ') INTO v_bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'app' AND c.relkind = 'v'
     AND NOT coalesce((SELECT option_value::boolean
                         FROM pg_options_to_table(c.reloptions)
                        WHERE option_name = 'security_invoker'), false);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'security_invoker=true でない view（RLS を迂回する）: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 11
  -- SECURITY DEFINER functions must have a fixed search_path
  SELECT string_agg(p.proname, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('app','audit','catalog') AND p.prosecdef
     AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
                      WHERE cfg LIKE 'search_path=%');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'SECURITY DEFINER 関数に search_path 固定が無い: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 12
  -- Signing functions must not be callable from app roles (if they were, signatures for any tenant could be made)
  IF has_function_privilege('app_rw', 'app.tenant_context_signature(uuid)', 'EXECUTE')
     OR has_function_privilege('app_ro', 'app.tenant_context_signature(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'app.tenant_context_signature がアプリロールから実行できる';
  END IF;

  ---------------------------------------------------------------- 13
  -- Only auth_svc issues sessions. If app_rw could call it, it could create a session for any
  -- tenant and establish context with that token, completely defeating isolation.
  IF has_function_privilege('app_rw', 'app.create_session(uuid,uuid,text,interval)', 'EXECUTE')
     OR has_function_privilege('app_ro', 'app.create_session(uuid,uuid,text,interval)', 'EXECUTE') THEN
    RAISE EXCEPTION 'app.create_session が app_rw / app_ro から実行できる';
  END IF;
  IF NOT has_function_privilege('auth_svc', 'app.create_session(uuid,uuid,text,interval)', 'EXECUTE') THEN
    RAISE EXCEPTION 'auth_svc が app.create_session を実行できない';
  END IF;
  -- auth_svc's only job is issuing sessions. It does not touch business data.
  IF EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname IN ('app','catalog','audit') AND c.relkind = 'r'
       AND has_table_privilege('auth_svc', c.oid, 'SELECT,INSERT,UPDATE,DELETE')) THEN
    RAISE EXCEPTION 'auth_svc がテーブル権限を持っている（発行専用のはず）';
  END IF;

  ---------------------------------------------------------------- 14
  -- Append-only tables must not have UPDATE / DELETE
  SELECT string_agg(format('%s:%s', c.relname, g.privilege_type), ', ') INTO v_bad
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) g
   WHERE n.nspname = 'app' AND c.relname IN ('device_snapshots','graph_events','raw_events','integration_resource_runs',
                                             -- 0071: import records (audit records, so append-only)
                                             'import_batches','import_batch_items','import_undos',
                                             -- 0075: transition records (only the trigger appends)
                                             'row_transitions')
     AND (g.grantee = 0 OR g.grantee::regrole::text IN ('app_rw','app_ro'))
     AND g.privilege_type IN ('UPDATE','DELETE');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '追記のみの表に UPDATE/DELETE が付いている: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 15
  -- M1: app_rw cannot directly rewrite framework relation / acceptance / internal receipt.
  -- Only the canonical fixed RPCs write them, as schema_owner.
  SELECT string_agg(format('%s:%s', c.relname, g.privilege_type), ', ') INTO v_bad
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) g
   WHERE n.nspname='app' AND c.relname = ANY(management_frameworks || management_append_only || management_provenance)
     AND (g.grantee = 0 OR g.grantee::regrole::text='app_rw')
     AND g.privilege_type IN ('INSERT','UPDATE','DELETE');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'M1 の直接 DML 権限が残っている: %', v_bad;
  END IF;
  IF has_function_privilege('app_rw', 'app.accept_risk(uuid,integer,smallint,smallint,text)', 'EXECUTE') THEN
    RAISE EXCEPTION '旧 app.accept_risk が app_rw から実行できる';
  END IF;
  IF has_function_privilege('app_rw', 'app.accept_risk_snapshot(uuid,uuid,text,uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION '汎用 app.accept_risk_snapshot が app_rw から実行できる';
  END IF;
  IF has_function_privilege('app_rw', 'app.accept_risk_snapshot_human(uuid,uuid,text,uuid,text,text)', 'EXECUTE')
     OR has_function_privilege('app_rw', 'app.accept_risk_snapshot_with_expiry(uuid,uuid,text,uuid,text,text,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION '監査証拠を残さない human acceptance RPC が app_rw から実行できる';
  END IF;
  IF has_function_privilege('app_rw', 'app.set_management_frameworks(text,uuid,text[])', 'EXECUTE') THEN
    RAISE EXCEPTION '旧 set_management_frameworks が app_rw から実行できる';
  END IF;
  IF has_function_privilege('app_rw', 'app.set_management_frameworks_v2(text,uuid,text[],text)', 'EXECUTE') THEN
    RAISE EXCEPTION '汎用 set_management_frameworks_v2 が app_rw から実行できる';
  END IF;
  IF NOT has_function_privilege('app_rw', 'app.set_management_frameworks_human(text,uuid,text[])', 'EXECUTE')
     OR NOT has_function_privilege('app_rw', 'app.accept_risk_snapshot_human_evidenced(text,text,uuid,uuid,text,uuid,text,text,timestamptz,uuid,text)', 'EXECUTE')
     OR NOT has_function_privilege('app_rw', 'app.approve_internal_risk_acceptance(text,uuid,uuid,text,uuid,text,uuid,text,text,timestamptz)', 'EXECUTE')
     OR NOT has_function_privilege('app_rw', 'app.internal_tag_iso(text,text,uuid,text,uuid)', 'EXECUTE')
     OR NOT has_function_privilege('app_rw', 'app.internal_accept_risk(text,text,uuid,text,uuid,uuid,text,uuid,uuid,text,uuid,text,text,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'M1 固定 RPC が app_rw から実行できない';
  END IF;
  IF has_function_privilege('app_rw', 'app.set_tenant_context_for_proxy(text,citext)', 'EXECUTE')
     OR has_function_privilege('app_ro', 'app.set_tenant_context_for_proxy(text,citext)', 'EXECUTE')
     OR NOT has_function_privilege('management_web', 'app.set_tenant_context_for_proxy(text,citext)', 'EXECUTE')
     OR has_function_privilege('app_rw', 'app.management_proxy_healthcheck()', 'EXECUTE')
     OR NOT has_function_privilege('management_web', 'app.management_proxy_healthcheck()', 'EXECUTE') THEN
    RAISE EXCEPTION 'proxy本人性 RPC の専用role境界が不正';
  END IF;
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='app' AND p.prosecdef
     AND p.proname IN ('set_management_frameworks_v2','set_management_frameworks_human',
                       'execute_iso_framework_removal_v2','accept_risk_snapshot_human',
                       'accept_risk_snapshot_human_evidenced','set_tenant_context_for_proxy',
                       'management_proxy_healthcheck',
                       'request_iso_framework_removal','approve_iso_framework_removal',
                       'accept_risk_snapshot','approve_internal_risk_acceptance',
                       'register_internal_management_service_principal',
                       'assert_active_management_framework','internal_tag_iso','internal_accept_risk')
     AND p.proowner::regrole::text <> 'schema_owner';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'management SECURITY DEFINER の所有者が schema_owner ではない: %', v_bad;
  END IF;
  IF has_function_privilege('app_rw', 'app.register_internal_management_service_principal(uuid,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'app_rw が internal service principal を登録できる';
  END IF;
  SELECT count(*) INTO n FROM (
    SELECT tenant_id,'asset'::text entity_type,asset_id entity_id,framework_key FROM app.asset_frameworks
    UNION ALL SELECT tenant_id,'risk_scenario',risk_scenario_id,framework_key FROM app.risk_scenario_frameworks
    UNION ALL SELECT tenant_id,'measure',measure_id,framework_key FROM app.measure_frameworks
  ) r LEFT JOIN app.framework_relation_origins o
    ON o.tenant_id=r.tenant_id AND o.entity_type=r.entity_type AND o.entity_id=r.entity_id AND o.framework_key=r.framework_key
   WHERE o.generation_id IS NULL;
  IF n <> 0 OR EXISTS (
    SELECT 1 FROM app.framework_relation_origins o WHERE NOT EXISTS (
      SELECT 1 FROM app.asset_frameworks af WHERE o.entity_type='asset' AND af.tenant_id=o.tenant_id AND af.asset_id=o.entity_id AND af.framework_key=o.framework_key
      UNION ALL SELECT 1 FROM app.risk_scenario_frameworks rf WHERE o.entity_type='risk_scenario' AND rf.tenant_id=o.tenant_id AND rf.risk_scenario_id=o.entity_id AND rf.framework_key=o.framework_key
      UNION ALL SELECT 1 FROM app.measure_frameworks mf WHERE o.entity_type='measure' AND mf.tenant_id=o.tenant_id AND mf.measure_id=o.entity_id AND mf.framework_key=o.framework_key
    )
  ) THEN RAISE EXCEPTION 'framework relation と origin が 1:1 ではない'; END IF;

  RAISE NOTICE 'check_rls: OK';
END $$;
