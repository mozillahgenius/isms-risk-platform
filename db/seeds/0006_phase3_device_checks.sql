-- Phase 3a D checks. Queries return violating rows; fixtures must make each
-- check fail in the isolated reverse-verification database.

BEGIN;
SELECT pg_advisory_xact_lock(8891234504);
SET ROLE schema_owner;

INSERT INTO catalog.checks
  (key, dom_version_id, title_ja, severity, cadence, connectors,
   query_sql, expect, coverage_required, evidence_mode, due_days, assign_to,
   negative_fixture)
SELECT x.key, d.id, x.title_ja, x.severity, x.cadence, x.connectors,
       x.query_sql, x.expect, x.coverage_required, x.evidence_mode, x.due_days,
       x.assign_to, x.negative_fixture
  FROM catalog.dom_versions d,
  LATERAL (VALUES
    ('CHK-ENDPOINT-001', 'ディスク暗号化が有効', 'critical', 'daily',
     ARRAY['agent']::text[],
     $q$WITH latest_snapshots AS (
       SELECT DISTINCT ON (device_id) * FROM app.device_snapshots
       ORDER BY device_id, collected_at DESC, id DESC
     )
     SELECT device_id FROM latest_snapshots WHERE disk_encrypted IS NOT TRUE$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 1, 'ciso',
     $f$WITH d AS (
       INSERT INTO app.devices (tenant_id, source, external_id, hostname, model, os_family)
       VALUES (app.current_tenant(), 'agent', 'fixture-endpoint-001', 'fixture', 'Mac mini', 'macos')
       RETURNING tenant_id, id
     )
     INSERT INTO app.device_snapshots
       (tenant_id, device_id, collected_at, disk_encrypted, raw_hash)
     SELECT tenant_id, id, now(), false, gen_random_bytes(32) FROM d$f$),

    ('CHK-ENDPOINT-002', '画面ロックが5分以内', 'high', 'daily',
     ARRAY['agent']::text[],
     $q$WITH latest_snapshots AS (
       SELECT DISTINCT ON (device_id) * FROM app.device_snapshots
       ORDER BY device_id, collected_at DESC, id DESC
     )
     SELECT device_id FROM latest_snapshots
         WHERE screen_lock_enabled IS NOT TRUE OR screen_lock_delay_sec > 300$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 1, 'ciso',
     $f$WITH d AS (
       INSERT INTO app.devices (tenant_id, source, external_id, hostname, model, os_family)
       VALUES (app.current_tenant(), 'agent', 'fixture-endpoint-002', 'fixture', 'Mac mini', 'macos')
       RETURNING tenant_id, id
     )
     INSERT INTO app.device_snapshots
       (tenant_id, device_id, collected_at, screen_lock_enabled, screen_lock_delay_sec, raw_hash)
     SELECT tenant_id, id, now(), true, 301, gen_random_bytes(32) FROM d$f$),

    ('CHK-ENDPOINT-003', 'EDR またはウイルス対策が稼働', 'critical', 'daily',
     ARRAY['agent']::text[],
     $q$WITH latest_snapshots AS (
       SELECT DISTINCT ON (device_id) * FROM app.device_snapshots
       ORDER BY device_id, collected_at DESC, id DESC
     )
     SELECT device_id
          FROM latest_snapshots
         WHERE NOT (
           coalesce(nullif(payload->>'edr_vendor',''), 'none') <> 'none'
           OR (
             jsonb_typeof(payload->'builtin_protection') = 'object'
             AND CASE
                   WHEN payload->'builtin_protection'->>'xprotect_process_count' ~ '^[0-9]+$'
                   THEN (payload->'builtin_protection'->>'xprotect_process_count')::int > 0
                   ELSE false
                 END
             AND nullif(btrim(payload->'builtin_protection'->>'xprotect_definition_version'), '') IS NOT NULL
             AND nullif(btrim(payload->'builtin_protection'->>'xprotect_remediator_version'), '') IS NOT NULL
             AND payload->'builtin_protection'->>'spctl_assessments_enabled' = 'true'
             AND payload->'builtin_protection'->>'csrutil_enabled' = 'true'
             AND jsonb_typeof(payload->'builtin_protection'->'system_extensions') = 'array'
           )
           OR (
             NOT (
               coalesce(payload ? 'edr_vendor', false)
               OR coalesce(payload ? 'builtin_protection', false)
             )
             AND edr_running IS TRUE
           )
         )$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 1, 'ciso',
     $f$WITH d AS (
       INSERT INTO app.devices (tenant_id, source, external_id, hostname, model, os_family)
       VALUES (app.current_tenant(), 'agent', 'fixture-endpoint-003', 'fixture', 'Mac mini', 'macos')
       RETURNING tenant_id, id
     )
     INSERT INTO app.device_snapshots
       (tenant_id, device_id, collected_at, edr_running, raw_hash, payload)
     SELECT tenant_id, id, now(), false, gen_random_bytes(32),
            '{"edr_vendor":"none","builtin_protection":{"xprotect_process_count":0,"xprotect_definition_version":"5355","xprotect_remediator_version":"157","spctl_assessments_enabled":true,"csrutil_enabled":true,"system_extensions":[]}}'::jsonb FROM d$f$),

    ('CHK-ENDPOINT-004', 'ファイアウォールが有効', 'high', 'daily',
     ARRAY['agent']::text[],
     $q$WITH latest_snapshots AS (
       SELECT DISTINCT ON (device_id) * FROM app.device_snapshots
       ORDER BY device_id, collected_at DESC, id DESC
     )
     SELECT device_id FROM latest_snapshots WHERE firewall_enabled IS NOT TRUE$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 1, 'ciso',
     $f$WITH d AS (
       INSERT INTO app.devices (tenant_id, source, external_id, hostname, model, os_family)
       VALUES (app.current_tenant(), 'agent', 'fixture-endpoint-004', 'fixture', 'Mac mini', 'macos')
       RETURNING tenant_id, id
     )
     INSERT INTO app.device_snapshots
       (tenant_id, device_id, collected_at, firewall_enabled, raw_hash)
     SELECT tenant_id, id, now(), false, gen_random_bytes(32) FROM d$f$),

    ('CHK-ENDPOINT-005', 'サポート対象のOSを利用', 'high', 'weekly',
     ARRAY['agent']::text[],
     $q$WITH latest_snapshots AS (
       SELECT DISTINCT ON (device_id) * FROM app.device_snapshots
       ORDER BY device_id, collected_at DESC, id DESC
     )
     SELECT device_id, os_version FROM latest_snapshots
         WHERE os_version ~ '^12\.'$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 7, 'ciso',
     $f$WITH d AS (
       INSERT INTO app.devices (tenant_id, source, external_id, hostname, model, os_family)
       VALUES (app.current_tenant(), 'agent', 'fixture-endpoint-005', 'fixture', 'Mac mini', 'macos')
       RETURNING tenant_id, id
     )
     INSERT INTO app.device_snapshots
       (tenant_id, device_id, collected_at, os_version, raw_hash)
     SELECT tenant_id, id, now(), '12.6.0', gen_random_bytes(32) FROM d$f$),

    ('CHK-ENDPOINT-006', 'セキュリティパッチが最新', 'critical', 'daily',
     ARRAY['agent']::text[],
     $q$WITH latest_snapshots AS (
       SELECT DISTINCT ON (device_id) * FROM app.device_snapshots
       ORDER BY device_id, collected_at DESC, id DESC
     )
     SELECT device_id FROM latest_snapshots WHERE patch_current IS NOT TRUE$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 1, 'ciso',
     $f$WITH d AS (
       INSERT INTO app.devices (tenant_id, source, external_id, hostname, model, os_family)
       VALUES (app.current_tenant(), 'agent', 'fixture-endpoint-006', 'fixture', 'Mac mini', 'macos')
       RETURNING tenant_id, id
     )
     INSERT INTO app.device_snapshots
       (tenant_id, device_id, collected_at, patch_current, raw_hash)
     SELECT tenant_id, id, now(), false, gen_random_bytes(32) FROM d$f$),

    ('CHK-ENDPOINT-007', '自動更新の定期チェックが有効', 'high', 'daily',
     ARRAY['agent']::text[],
     $q$WITH latest_snapshots AS (
       SELECT DISTINCT ON (device_id) * FROM app.device_snapshots
       ORDER BY device_id, collected_at DESC, id DESC
     )
     SELECT device_id FROM latest_snapshots WHERE auto_update_enabled IS NOT TRUE$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 1, 'ciso',
     $f$WITH d AS (
       INSERT INTO app.devices (tenant_id, source, external_id, hostname, model, os_family)
       VALUES (app.current_tenant(), 'agent', 'fixture-endpoint-007', 'fixture', 'Mac mini', 'macos')
       RETURNING tenant_id, id
     )
     INSERT INTO app.device_snapshots
       (tenant_id, device_id, collected_at, auto_update_enabled, raw_hash)
     SELECT tenant_id, id, now(), false, gen_random_bytes(32) FROM d$f$),

    ('CHK-ENDPOINT-008', '管理者アカウント数が2以下', 'high', 'weekly',
     ARRAY['agent']::text[],
     $q$WITH latest_snapshots AS (
       SELECT DISTINCT ON (device_id) * FROM app.device_snapshots
       ORDER BY device_id, collected_at DESC, id DESC
     )
     SELECT device_id, admin_account_count FROM latest_snapshots
         WHERE admin_account_count > 2$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 7, 'ciso',
     $f$WITH d AS (
       INSERT INTO app.devices (tenant_id, source, external_id, hostname, model, os_family)
       VALUES (app.current_tenant(), 'agent', 'fixture-endpoint-008', 'fixture', 'Mac mini', 'macos')
       RETURNING tenant_id, id
     )
     INSERT INTO app.device_snapshots
       (tenant_id, device_id, collected_at, admin_account_count, raw_hash)
     SELECT tenant_id, id, now(), 3, gen_random_bytes(32) FROM d$f$),

    ('CHK-ENDPOINT-009', '未承認アプリが存在しない', 'high', 'weekly',
     ARRAY['agent']::text[],
     $q$WITH latest_snapshots AS (
       SELECT DISTINCT ON (device_id) * FROM app.device_snapshots
       ORDER BY device_id, collected_at DESC, id DESC
     )
     SELECT device_id, unapproved_apps, payload->'application_inventory_mismatches' AS application_inventory_mismatches
         FROM latest_snapshots
         WHERE cardinality(unapproved_apps) > 0
            OR jsonb_array_length(coalesce(payload->'application_inventory_mismatches','[]'::jsonb)) > 0$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 7, 'ciso',
     $f$WITH d AS (
       INSERT INTO app.devices (tenant_id, source, external_id, hostname, model, os_family)
       VALUES (app.current_tenant(), 'agent', 'fixture-endpoint-009', 'fixture', 'Mac mini', 'macos')
       RETURNING tenant_id, id
     )
     INSERT INTO app.device_snapshots
       (tenant_id, device_id, collected_at, unapproved_apps, raw_hash, payload)
     SELECT tenant_id, id, now(), ARRAY[]::text[], gen_random_bytes(32),
            '{"application_inventory_mismatches":["profiler_only:Safari"]}'::jsonb FROM d$f$),

    ('CHK-ENDPOINT-010', '従業員の端末が7日以内に報告', 'high', 'daily',
     ARRAY['agent']::text[],
     $q$SELECT i.id, i.primary_email
          FROM app.identities i
          LEFT JOIN app.devices d
            ON d.tenant_id = i.tenant_id AND d.assigned_identity_id = i.id
         WHERE i.subject_type IN ('employee','contractor') AND i.status = 'active'
           AND (d.id IS NULL OR d.last_seen_at IS NULL
                OR d.last_seen_at < now() - interval '7 days')$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 1, 'secretariat',
     $f$INSERT INTO app.identities
       (tenant_id, subject_type, display_name, primary_email, status)
     VALUES (app.current_tenant(), 'employee', 'fixture employee', 'fixture.employee@example.invalid', 'active')$f$)
  ) AS x(key,title_ja,severity,cadence,connectors,query_sql,expect,coverage_required,evidence_mode,due_days,assign_to,negative_fixture)
 WHERE d.is_current
ON CONFLICT (key) DO UPDATE SET
  dom_version_id=EXCLUDED.dom_version_id, title_ja=EXCLUDED.title_ja,
  severity=EXCLUDED.severity, cadence=EXCLUDED.cadence, connectors=EXCLUDED.connectors,
  query_sql=EXCLUDED.query_sql, expect=EXCLUDED.expect,
  coverage_required=EXCLUDED.coverage_required, evidence_mode=EXCLUDED.evidence_mode,
  due_days=EXCLUDED.due_days, assign_to=EXCLUDED.assign_to,
  negative_fixture=EXCLUDED.negative_fixture;

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM catalog.checks WHERE key LIKE 'CHK-ENDPOINT-%';
  IF n <> 10 THEN
    RAISE EXCEPTION 'endpoint checks are not 10 (currently %)', n;
  END IF;
END $$;

RESET ROLE;
COMMIT;
