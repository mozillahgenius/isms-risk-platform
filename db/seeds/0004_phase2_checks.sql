-- Standard checks for Phase 2 (a minimal executable set for A/B/C/F/G).
-- Every check has query_sql (returns violating rows) and negative_fixture (breaks it with one statement).
-- Reverse verification is run by scripts/checker.py on a throwaway DB.

BEGIN;
SELECT pg_advisory_xact_lock(8891234503);
SET ROLE schema_owner;

INSERT INTO catalog.checks
  (key, dom_version_id, title_ja, severity, cadence, connectors,
   query_sql, expect, coverage_required, evidence_mode, due_days, assign_to, negative_fixture)
SELECT x.key, d.id, x.title_ja, x.severity, x.cadence, x.connectors,
       x.query_sql, x.expect, x.coverage_required, x.evidence_mode, x.due_days, x.assign_to,
       x.negative_fixture
  FROM catalog.dom_versions d,
  LATERAL (VALUES
    ('CHK-SHARE-002', '検索で発見可能な公開資源が存在しない', 'critical', 'daily',
     ARRAY['google_workspace']::text[],
     $q$SELECT resource_id, path FROM app.effective_grants WHERE subject_kind = 'public'$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 1, 'secretariat',
     $f$WITH r AS (
       INSERT INTO app.resources (tenant_id,connector,external_id,kind,name,classification,classification_source)
       VALUES (app.current_tenant(),'google_workspace','fixture-public','file','fixture','confidential','manual')
       RETURNING id
     )
     INSERT INTO app.effective_grants (tenant_id,resource_id,subject_kind,role,path)
     SELECT app.current_tenant(), id, 'public', 'reader', 'direct' FROM r$f$),

    ('CHK-SHARE-004', '退職者が資源の権限を保持していない', 'high', 'daily',
     ARRAY['google_workspace']::text[],
     $q$SELECT r.name, a.email, g.path
          FROM app.effective_grants g
          JOIN app.accounts a ON a.tenant_id=g.tenant_id AND a.id=g.subject_account_id
          JOIN app.identities i ON i.tenant_id=a.tenant_id AND i.id=a.identity_id
          JOIN app.resources r ON r.tenant_id=g.tenant_id AND r.id=g.resource_id
         WHERE i.subject_type IN ('employee','contractor') AND i.status='left'$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 1, 'secretariat',
     $f$WITH i AS (
       INSERT INTO app.identities (tenant_id,subject_type,display_name,primary_email,status)
       VALUES (app.current_tenant(),'employee','退職者 fixture','left@example.invalid','left') RETURNING id
     ), a AS (
       INSERT INTO app.accounts (tenant_id,connector,external_id,email,identity_id,mfa_enrolled,suspended)
       SELECT app.current_tenant(),'google_workspace','fixture-left','left@example.invalid',id,true,false FROM i RETURNING id
     ), r AS (
       INSERT INTO app.resources (tenant_id,connector,external_id,kind,name)
       VALUES (app.current_tenant(),'google_workspace','fixture-left-file','file','fixture') RETURNING id
     )
     INSERT INTO app.effective_grants (tenant_id,resource_id,subject_kind,subject_account_id,role,path)
     SELECT app.current_tenant(),r.id,'account',a.id,'reader','via_fixture' FROM r,a$f$),

    ('CHK-IAM-001', '全アカウントで多要素認証が有効', 'critical', 'daily',
     ARRAY['google_workspace']::text[],
     $q$SELECT external_id, email FROM app.accounts WHERE mfa_enrolled IS NOT TRUE$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 1, 'secretariat',
     $f$INSERT INTO app.accounts (tenant_id,connector,external_id,email,is_admin,mfa_enrolled,suspended)
       VALUES (app.current_tenant(),'google_workspace','fixture-no-mfa','no-mfa@example.invalid',false,false,false)$f$),

    ('CHK-TPR-001', '高リスクスコープを持つ OAuth アプリが承認済み', 'critical', 'daily',
     ARRAY['google_workspace']::text[],
     $q$SELECT oa.external_id, oa.name, oa.risk_scopes
          FROM app.oauth_apps oa
         WHERE cardinality(oa.risk_scopes) > 0
           AND NOT EXISTS (
             SELECT 1 FROM app.vendors v
              WHERE v.tenant_id=oa.tenant_id AND v.id=oa.vendor_id AND v.contract_on IS NOT NULL)$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 7, 'secretariat',
     $f$INSERT INTO app.oauth_apps (tenant_id,connector,external_id,name,scopes,risk_scopes)
       VALUES (app.current_tenant(),'google_workspace','fixture-risk-oauth','未承認 fixture',
               ARRAY['https://www.googleapis.com/auth/drive.readonly'],
               ARRAY['https://www.googleapis.com/auth/drive.readonly'])$f$),

    ('CHK-OPS-006', '期限切れの逸脱が放置されていない', 'high', 'daily',
     ARRAY[]::text[],
     $q$SELECT kind, target_key, expires_at FROM app.deviations
         WHERE status='expired' AND expires_at < now() - interval '30 days'$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 14, 'ciso',
     $f$INSERT INTO app.deviations
       (tenant_id,kind,target_key,override,reason,status,requested_by,requested_at,expires_at,weight)
       SELECT app.current_tenant(),'risk_band','fixture-expired','{"band_accept":[1,2]}'::jsonb,'fixture','expired',
              u.id,now(),now()-interval '31 days',1.0
         FROM app.users u WHERE u.tenant_id=app.current_tenant() LIMIT 1$f$),

    ('CHK-EVD-005', 'コネクタが48時間以内に成功している', 'high', 'daily',
     ARRAY['google_workspace']::text[],
     $q$SELECT ir.resource_name, ir.status, ir.coverage_ratio
          FROM (SELECT DISTINCT ON (resource_name) resource_name, status,
                       coverage_ratio, finished_at
                  FROM app.integration_runs
                 ORDER BY resource_name, finished_at DESC) ir
         WHERE ir.finished_at < now() - interval '48 hours'
            OR ir.status <> 'success'$q$,
     '{"max_violations":0}'::jsonb, 0.95, 'attach_rows', 1, 'secretariat',
     $f$WITH i AS (
       INSERT INTO app.integrations (tenant_id,connector,manifest_version,kind,secret_ref)
       VALUES (app.current_tenant(),'google_workspace',3,'reader','fixture')
       ON CONFLICT (tenant_id,connector) DO UPDATE SET status='active' RETURNING id
     )
     INSERT INTO app.integration_runs
       (tenant_id,integration_id,resource_name,mode,started_at,finished_at,coverage_ratio,status)
     SELECT app.current_tenant(),id,'fixture','full',now()-interval '49 hours',now()-interval '49 hours',0.5,'partial'
       FROM i$f$)
  ) AS x(key,title_ja,severity,cadence,connectors,query_sql,expect,coverage_required,evidence_mode,due_days,assign_to,negative_fixture)
 WHERE d.is_current
ON CONFLICT (key) DO UPDATE SET
  dom_version_id=EXCLUDED.dom_version_id, title_ja=EXCLUDED.title_ja,
  severity=EXCLUDED.severity, cadence=EXCLUDED.cadence, connectors=EXCLUDED.connectors,
  query_sql=EXCLUDED.query_sql, expect=EXCLUDED.expect, coverage_required=EXCLUDED.coverage_required,
  evidence_mode=EXCLUDED.evidence_mode, due_days=EXCLUDED.due_days, assign_to=EXCLUDED.assign_to,
  negative_fixture=EXCLUDED.negative_fixture;

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM catalog.checks WHERE key LIKE 'CHK-CORE-%' OR key IN
    ('CHK-SHARE-002','CHK-SHARE-004','CHK-IAM-001','CHK-TPR-001','CHK-OPS-006','CHK-EVD-005');
  IF n <> 10 THEN
    RAISE EXCEPTION 'core + Phase 2 チェックが10本になりません（現在 %本）', n;
  END IF;
END $$;

RESET ROLE;
COMMIT;
