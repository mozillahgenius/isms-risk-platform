-- 設計書 11.5 の品質ゲート「RLS 網羅」＋ロール属性＋実効権限の検査。
-- 1 件でも違反があれば RAISE EXCEPTION で落ちる（psql -v ON_ERROR_STOP=1 で使う）。
--
-- ALTER DEFAULT PRIVILEGES は既存オブジェクトに遡及しないので、これに依存せず
-- aclexplode で「今そこにある権限」を直接見る。

\set ON_ERROR_STOP on

DO $$
DECLARE
  v_bad text;
  n int;
  k text;
  v_expect_qual constant text := '(tenant_id = app.current_tenant())';
  -- 定義者専用（app_rw / app_ro にテーブル権限を与えない表）
  definer_only constant text[] := ARRAY['sessions','tenant_context_keys','verification_receipts',
    'device_login_requests','device_login_request_nonces',
    'internal_management_service_principals','internal_management_acceptance_approvals'];
  management_append_only constant text[] := ARRAY['risk_acceptances','framework_relation_events','internal_management_operations','internal_management_audit_events'];
  management_frameworks constant text[] := ARRAY['asset_frameworks','risk_scenario_frameworks','measure_frameworks'];
  management_provenance constant text[] := ARRAY['framework_relation_origins','framework_backfill_provenance','iso_framework_removal_requests',
    'internal_management_service_principals','internal_management_acceptance_approvals','approvals'];
BEGIN
  ---------------------------------------------------------------- 1
  -- tenant_id を持つ app の表に ENABLE + FORCE RLS が揃っていること
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
  -- app.tenants は tenant_id 列を持たないので上の網から漏れる。個別に見る。
  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname='app' AND c.relname='tenants'
                    AND c.relrowsecurity AND c.relforcerowsecurity) THEN
    RAISE EXCEPTION 'app.tenants に ENABLE+FORCE ROW LEVEL SECURITY が無い';
  END IF;

  ---------------------------------------------------------------- 3
  -- ポリシーが 2 本揃っていること。名前だけでなく cmd・対象ロール・qual・
  -- with_check まで期待どおりか見る（同名なだけの誤ったポリシーを通さない）。
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
  -- 想定外のポリシーが増えていないこと。
  -- 「正しいポリシーが在る」だけを見ると、横に USING (true) の permissive な
  -- ポリシーを足されても通ってしまう（ポリシーは OR で合成されるので穴になる）。
  SELECT string_agg(format('%s.%s', tablename, policyname), ', ') INTO v_bad
    FROM pg_policies
   WHERE schemaname = 'app'
     AND policyname NOT IN ('tenant_isolation','tenant_read',
                            'ctx_session_lookup','ctx_membership_lookup',
                            'ctx_user_lookup','ctx_user_lock','ctx_tenant_lookup','ctx_deviation_lookup',
                            -- 0021 で足したテナント作成用（定義者のみ・作成中の 1 テナントだけ）
                            'prov_tenant_insert','prov_user_insert','prov_membership_insert',
                            'prov_policy_insert','prov_policy_version_insert',
                            -- 0026 の agent 受入経路。schema_owner の no-login 関数だけが使う。
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
                            -- 0057〜0061 の定義者・送信ワーカー向け。許可リストへの追記が漏れていて、
                            -- 新規 DB の agent 受入試験がここで落ちていた（970c42a でも同じ。2026-09-12 実測）。
                            'tenant_security_definer','tenant_security_definer_read','tenant_worker_read',
                            -- 0067 の記録の役割ポリシー（RESTRICTIVE。形と対象表は下で固定する）。
                            'records_role_insert','records_role_update','records_role_delete');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '想定外のポリシーがある: %', v_bad;
  END IF;

  -- 0057〜0062 の定義者・送信ワーカー向けポリシーの形。名前を許可リストに足すだけだと、
  -- 同じ名前のまま USING (true) へ書き換えても通ってしまう（Codex レビュー 2026-09-12 指摘）。
  -- 条件は「テナント文脈で絞る」2 つの書き方だけを認める（0062 の (SELECT ...) 形と、それ以前の直呼び形）。
  -- CASE が NULL を返す（条件が NULL の）行も落とすため coalesce で偽に倒す。
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

  -- 形だけでなく、どの表に張られているかも固定する（両方向）。
  -- 対象表から欠けても、別の表に同名・同形のものが増えても落とす（Codex レビュー 2026-09-12 2 巡目指摘）。
  -- 表を足すときは、ここへ足すことが「その表に定義者の口を開ける」判断の記録になる。
  SELECT string_agg(coalesce(e.pol || '.' || e.tbl || '(欠落)', a.pol || '.' || a.tbl || '(想定外)'), ', ') INTO v_bad
    FROM (VALUES
      ('tenant_security_definer', 'application_catalog'),
      -- 0070: 変更の申請の承認・却下の関数（decide_change_request）が申請を読み書きするため。
      ('tenant_security_definer', 'change_requests'),
      ('tenant_security_definer', 'department_systems'),
      ('tenant_security_definer', 'external_questionnaires'),
      ('tenant_security_definer', 'mail_outbox'),
      ('tenant_security_definer', 'questionnaire_template_questions'),
      ('tenant_security_definer', 'questionnaire_templates'),
      -- 0075: 変化の記録を、トリガの関数（record_row_transition）が書くため。
      ('tenant_security_definer', 'row_transitions'),
      ('tenant_security_definer', 'work_item_assignees'),
      ('tenant_security_definer', 'work_items'),
      ('tenant_security_definer_read', 'assets'),
      -- 0063: マネジメントレビューの承認関数（approve_management_review）が議事を読むため。
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
  -- 0067 の記録の役割ポリシー。名前だけでなく、張る表（両方向）と形を固定する。
  -- 形: app_rw・RESTRICTIVE・コマンドは名前どおり・条件は (SELECT app.records_role_allows('<その表の種類>')) だけ。
  -- PERMISSIVE へ書き換えられると OR で合成されて絞りが消え、条件を true にされると誰でも書ける。どちらも落とす。
  -- 表を足すときは、ここへ足すことが「その表を役割で絞る」判断の記録になる。
  -- 許可の関数そのものも確かめる。本人が分からない（セッションが無い）ときに、どの種類も「許す」を返してはならない。
  -- セッションが無いと current_session_user() が insufficient_privilege で落ちるので、偽か、その例外なら可
  -- （2026-09-12 Codex レビュー: 例外を捕まえずに呼ぶと、素の接続ではこの検査そのものが落ちていた）。
  -- 本体を RETURN true に書き換えられると、ポリシーの形が正しくても誰でも書ける。許可の表にある種類をすべて見る
  -- （表を張っていない種類の分岐だけを書き換えられても落とす）。役割ごとの許否は tests/isms_registers.sh が実際の書き込みで確かめる。
  v_bad := NULL;
  FOREACH k IN ARRAY ARRAY['audit','corrective','effectiveness','management_review','objective','evidence',
                           'exception','context','legal','continuity','vulnerability','change','import'] LOOP
    BEGIN
      IF app.records_role_allows(k) IS DISTINCT FROM false THEN
        v_bad := concat_ws(', ', v_bad, k);
      END IF;
    EXCEPTION WHEN insufficient_privilege THEN
      -- 本人不明で落ちるのは「許していない」ので可。知らない種類（unknown record kind）はここで捕まえず、検査ごと落とす。
      NULL;
    END;
  END LOOP;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '記録の許可関数が、本人不明でも許している: %', v_bad;
  END IF;
  -- 同じセッションに同名の一時表が先に作られていても使わない（期待値を差し替えられないよう、必ず作り直す）。
  DROP TABLE IF EXISTS pg_temp.records_role_expected;
  CREATE TEMP TABLE pg_temp.records_role_expected ON COMMIT DROP AS
    SELECT v.tbl, p.pol, p.cmd,
           format('( SELECT app.records_role_allows(%L::text) AS records_role_allows)', v.kind) AS cond
      FROM (VALUES ('control_effectiveness', 'effectiveness'), ('context_issues', 'context'),
                   ('interested_parties', 'context'), ('legal_requirements', 'legal'),
                   -- 0068: 事業継続の計画・試験
                   ('continuity_plans', 'continuity'), ('continuity_tests', 'continuity'),
                   -- 0069: 脆弱性
                   ('vulnerabilities', 'vulnerability'),
                   -- 0070: 変更の申請（DELETE は権限を渡していないが、形はそろえて張る）
                   ('change_requests', 'change'),
                   -- 0071: 取り込みの記録（UPDATE / DELETE は権限が無いが、形はそろえて張る）
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
  -- 0070 の変更の申請の権限境界。承認の偽造を防ぐ仕組みが外されていないこと（Codex レビュー 2026-09-12）。
  --   app_rw に DELETE が無い（申請と承認の記録を消させない。申請は取りやめるだけ）
  --   判断の関数は schema_owner 所有・SECURITY DEFINER・PUBLIC に実行権限なし
  --   遷移と判断の欄を守るトリガが有効
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
  -- 0070〜0072 の守りのトリガ。名前だけでなく、有効・呼ぶ関数・時点と事象（tgtype）まで固定する
  -- （BEFORE INSERT を BEFORE UPDATE に変えると、名前は同じでも本人・日時を埋めなくなる。Codex レビュー 2026-09-12）。
  -- tgtype のビット: ROW=1 BEFORE=2 INSERT=4 DELETE=8 UPDATE=16。
  SELECT string_agg(e.tbl || '.' || e.tg, ', ') INTO v_bad
    FROM (VALUES ('import_batches',     'import_batches_stamp',           'app.import_log_stamp()',       7),
                 ('import_undos',       'import_undos_stamp',             'app.import_log_stamp()',       7),
                 ('import_batch_items', 'import_batch_items_guard',       'app.import_items_guard()',     7),
                 ('import_batches',     'import_batches_complete',        'app.import_batch_complete()',  5),
                 ('assets',             'assets_keep_created_at',         'app.keep_created_at()',       19),
                 ('risk_scenarios',     'risk_scenarios_keep_created_at', 'app.keep_created_at()',       19),
                 ('departments',        'departments_keep_created_at',    'app.keep_created_at()',       19),
                 -- 0076: 規程と版（取り込みの明細の「このトランザクションで作った」の判定を偽らせない）
                 ('policies',           'policies_keep_created_at',        'app.keep_created_at()',      19),
                 ('policy_versions',    'policy_versions_keep_created_at', 'app.keep_created_at()',      19),
                 -- 0075: 変化の記録（AFTER UPDATE の行トリガ。外されると明細と取り消しの件数が根拠を失い、拒否側に倒れる）
                 ('assets',             'assets_status_transition',          'app.record_row_transition()', 17),
                 ('risk_scenarios',     'risk_scenarios_status_transition',  'app.record_row_transition()', 17),
                 ('memberships',        'memberships_department_transition', 'app.record_row_transition()', 17),
                 -- 0077: 作った行の記録（AFTER INSERT の行トリガ。明細の「このトランザクションで作った」の根拠）
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
  -- 0075: 変化の記録は、トリガの関数（schema_owner 所有・SECURITY DEFINER）だけが書く。app_rw / app_ro は読むだけ
  -- （書けると偽の「元の部署」「退役にした」を作れる）。
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
  -- Phase 3a の定義者ポリシー。許可リストに名前を足すだけではなく、
  -- 対象ロール・コマンド・USING / WITH CHECK を固定して検査する。
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
  -- テナント作成用ポリシーの形。ここが緩むと「定義者なら他テナントの行も作れる」に戻る。
  -- 見るのは 3 つ: 対象ロールが schema_owner だけ / INSERT だけ / WITH CHECK が
  -- provisioning_target() に縛られていること。
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
       OR qual IS NOT NULL);  -- 読み取り側へ波及していないこと
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'テナント作成用ポリシーの形が想定外: %', v_bad;
  END IF;

  -- 対象表も決め打ちにする（新しい表へ勝手に広がっていないこと）
  SELECT string_agg(format('%s.%s', tablename, policyname), ', ') INTO v_bad
    FROM pg_policies
   WHERE schemaname = 'app' AND policyname LIKE 'prov\_%'
     AND tablename NOT IN ('tenants','users','memberships','policies','policy_versions');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'テナント作成用ポリシーが想定外の表にある: %', v_bad;
  END IF;

  -- 定義者向けの 2 本は、対象表と対象ロールが決め打ちであること
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
  -- ロール属性。BYPASSRLS / SUPERUSER を持っていたら RLS の保証が崩れる。
  SELECT string_agg(rolname, ', ') INTO v_bad FROM pg_roles
   WHERE rolname IN ('schema_owner','app_rw','app_ro','auth_svc','auditlogd','audit_verifier')
     AND (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '過剰なロール属性: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 5
  -- ロール継承の推移閉包。app_rw / app_ro が schema_owner へ到達できてはならない
  -- （到達できると SET ROLE で所有者になり、ポリシーを付け替えられる）。
  SELECT string_agg(format('%s -> %s', m.member::regrole, m.roleid::regrole), ', ')
    INTO v_bad
    FROM pg_auth_members m
   -- auth_svc も含める。NOINHERIT でも schema_owner のメンバーなら
   -- SET ROLE で所有者になれてしまう。
   WHERE m.member::regrole::text
         IN ('app_rw','app_ro','auth_svc','auditlogd','audit_verifier');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'アプリロールが他ロールのメンバーになっている: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 6
  -- app_rw / app_ro が app / catalog / audit の表を所有していないこと
  SELECT string_agg(format('%s.%s', n.nspname, c.relname), ', ') INTO v_bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname IN ('app','catalog','audit')
     AND c.relowner::regrole::text
         IN ('app_rw','app_ro','auth_svc','auditlogd','audit_verifier');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'アプリロールがテーブル所有者になっている: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 7
  -- 実効権限。GRANT ALL 相当（TRUNCATE / REFERENCES / TRIGGER）が付いていないこと
  SELECT string_agg(format('%s.%s:%s:%s', n.nspname, c.relname,
                           g.grantee::regrole, g.privilege_type), ', ') INTO v_bad
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(c.relacl) g
   WHERE n.nspname IN ('app','catalog','audit')
     -- PUBLIC 経由の権限も見る（grantee=0 が PUBLIC。ロール名だけで絞ると見落とす）
     AND (g.grantee = 0 OR g.grantee::regrole::text IN ('app_rw','app_ro'))
     AND g.privilege_type IN ('TRUNCATE','REFERENCES','TRIGGER');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '過剰な権限（TRUNCATE/REFERENCES/TRIGGER）: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 8
  -- catalog はテナントロールから読み取り専用
  SELECT string_agg(format('%s:%s:%s', c.relname, g.grantee::regrole, g.privilege_type), ', ')
    INTO v_bad
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(c.relacl) g
   WHERE n.nspname = 'catalog' AND c.relkind = 'r'
     -- PUBLIC 経由の権限も見る（grantee=0 が PUBLIC。ロール名だけで絞ると見落とす）
     AND (g.grantee = 0 OR g.grantee::regrole::text IN ('app_rw','app_ro'))
     AND g.privilege_type <> 'SELECT';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'catalog に SELECT 以外の権限が付いている: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 9
  -- 定義者専用テーブルへ権限が漏れていないこと
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
  -- audit.audit_log。app スキーマの網に入らないので個別に検査する。
  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname='audit' AND c.relname='audit_log'
                    AND c.relrowsecurity AND c.relforcerowsecurity) THEN
    RAISE EXCEPTION 'audit.audit_log に ENABLE+FORCE ROW LEVEL SECURITY が無い';
  END IF;

  -- 追記は audit.append() 経由のみ。auditlogd に直接の権限が残っていたら
  -- チェーンを迂回して偽の行を書ける。
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

  -- app_rw / app_ro / auditlogd の SELECT はテナント限定でなければならない
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
  -- 所有者（定義者）にも UPDATE / DELETE のポリシーを作らない＝過去行を書き換えられない
  IF EXISTS (SELECT 1 FROM pg_policies
              WHERE schemaname='audit' AND tablename='audit_log'
                AND cmd IN ('UPDATE','DELETE','ALL')) THEN
    RAISE EXCEPTION 'audit_log に UPDATE/DELETE を許すポリシーがある';
  END IF;

  ---------------------------------------------------------------- 10
  -- テナント向け view が RLS を迂回しないこと（security_invoker 必須）
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
  -- SECURITY DEFINER 関数は search_path が固定されていること
  SELECT string_agg(p.proname, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('app','audit','catalog') AND p.prosecdef
     AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
                      WHERE cfg LIKE 'search_path=%');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'SECURITY DEFINER 関数に search_path 固定が無い: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 12
  -- 署名関数はアプリロールから呼べてはならない（呼べると任意テナントの署名を作れる）
  IF has_function_privilege('app_rw', 'app.tenant_context_signature(uuid)', 'EXECUTE')
     OR has_function_privilege('app_ro', 'app.tenant_context_signature(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'app.tenant_context_signature がアプリロールから実行できる';
  END IF;

  ---------------------------------------------------------------- 13
  -- セッション発行は auth_svc だけ。app_rw が呼べると、任意テナント向けの
  -- セッションを作ってそのトークンで文脈を確立でき、分離が丸ごと無効になる。
  IF has_function_privilege('app_rw', 'app.create_session(uuid,uuid,text,interval)', 'EXECUTE')
     OR has_function_privilege('app_ro', 'app.create_session(uuid,uuid,text,interval)', 'EXECUTE') THEN
    RAISE EXCEPTION 'app.create_session が app_rw / app_ro から実行できる';
  END IF;
  IF NOT has_function_privilege('auth_svc', 'app.create_session(uuid,uuid,text,interval)', 'EXECUTE') THEN
    RAISE EXCEPTION 'auth_svc が app.create_session を実行できない';
  END IF;
  -- auth_svc はセッション発行だけの役。業務データへは触れない。
  IF EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname IN ('app','catalog','audit') AND c.relkind = 'r'
       AND has_table_privilege('auth_svc', c.oid, 'SELECT,INSERT,UPDATE,DELETE')) THEN
    RAISE EXCEPTION 'auth_svc がテーブル権限を持っている（発行専用のはず）';
  END IF;

  ---------------------------------------------------------------- 14
  -- 追記のみの表に UPDATE / DELETE が付いていないこと
  SELECT string_agg(format('%s:%s', c.relname, g.privilege_type), ', ') INTO v_bad
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) g
   WHERE n.nspname = 'app' AND c.relname IN ('device_snapshots','graph_events','raw_events','integration_resource_runs',
                                             -- 0071: 取り込みの記録（監査の記録なので追記だけ）
                                             'import_batches','import_batch_items','import_undos',
                                             -- 0075: 変化の記録（トリガだけが追記する）
                                             'row_transitions')
     AND (g.grantee = 0 OR g.grantee::regrole::text IN ('app_rw','app_ro'))
     AND g.privilege_type IN ('UPDATE','DELETE');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '追記のみの表に UPDATE/DELETE が付いている: %', v_bad;
  END IF;

  ---------------------------------------------------------------- 15
  -- M1: app_rw は framework relation / acceptance / internal receipt を直接
  -- 書き換えられない。正規の固定 RPC だけが schema_owner として書く。
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
