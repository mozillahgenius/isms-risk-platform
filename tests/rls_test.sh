#!/usr/bin/env bash
# Acceptance test for tenant isolation and tenant context (design doc Phase 1 acceptance 6-9, 14).
#
# Don't run as superuser. Superuser bypasses RLS, so
# verify with real app_rw / app_ro connections (anything else is not a verification).
#
# Usage: tests/rls_test.sh   (honors DATABASE_URL / ISMS_DB)
set -uo pipefail

DB="${ISMS_DB:-isms_dev}"
ADMIN="postgres:///$DB"
RW="postgres:///$DB?user=app_rw"
RO="postgres:///$DB?user=app_ro"
AUTH="postgres:///$DB?user=auth_svc&connect_timeout=5"
PROXY="$ADMIN"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
ng()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TOKEN_A='TOKEN-A-0123456789012345678901234567890123'
TOKEN_B='TOKEN-B-0123456789012345678901234567890123'
TOKEN_C='TOKEN-C-0123456789012345678901234567890123'
TOKEN_D='TOKEN-D-0123456789012345678901234567890123'
TA='11111111-1111-1111-1111-111111111111'
TB='22222222-2222-2222-2222-222222222222'

# Succeeds as expected?
expect_ok() {
  local label="$1" url="$2" sql="$3" out
  out=$(psql -At -v ON_ERROR_STOP=1 "$url" <<<"$sql" 2>&1)
  if [ $? -eq 0 ]; then ok "$label"; else ng "$label -- $out"; fi
}

# Fails as expected? (also checks a partial message match)
expect_err() {
  local label="$1" url="$2" sql="$3" want="${4:-}" out
  out=$(psql -At -v ON_ERROR_STOP=1 "$url" <<<"$sql" 2>&1)
  if [ $? -eq 0 ]; then
    ng "$label -- 失敗するはずが成功した"
  elif [ -n "$want" ] && ! grep -q "$want" <<<"$out"; then
    ng "$label -- 別の理由で失敗: $(head -2 <<<"$out" | tr '\n' ' ')"
  else
    ok "$label"
  fi
}

fixture() {
  # If we continue after setup failed, the subsequent "0 cross-tenant rows" would
  # become "0 rows because there is no data at all", a test that verifies nothing.
  if ! psql -q -v ON_ERROR_STOP=1 "$ADMIN" >/dev/null <<SQL
-- catalog (DOM) is canonical from the seed, so don't delete it. Replace only the app-side test data.
DELETE FROM app.vendors WHERE tenant_id IN ('$TA','$TB');
DELETE FROM app.sessions WHERE tenant_id IN ('$TA','$TB');
DELETE FROM app.internal_management_service_principals WHERE tenant_id IN ('$TA','$TB');
DELETE FROM app.memberships WHERE tenant_id IN ('$TA','$TB');
DELETE FROM app.users WHERE tenant_id IN ('$TA','$TB');
DELETE FROM app.tenants WHERE id IN ('$TA','$TB');
INSERT INTO catalog.dom_versions (id, version, released_at, changelog, is_current)
  VALUES ('00000000-0000-0000-0000-000000002026','2026.1', now(), 'seed', true)
  ON CONFLICT (version) DO NOTHING;
INSERT INTO catalog.roles_default (key,name_ja,description,sort_order) VALUES
  ('ciso','経営責任者','受容判断と承認',1),
  ('secretariat','事務局','日々の運用',2),
  ('employee','一般従業員','閲覧のみ',3),
  ('auditor','監査人','内部監査',4)
  ON CONFLICT (key) DO NOTHING;
INSERT INTO catalog.frameworks (key,name_ja,version,source_note) VALUES
  ('RISK-MANAGEMENT','リソースマネジメント','2026.1','M1 fixture'),
  ('ISO27001:2022','ISO/IEC 27001','2022','M1 fixture')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO catalog.asset_classes_default
  (key,name_ja,rank,external_share_policy)
VALUES ('internal','社内限定',2,'forbidden')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO app.tenants (id,name,domain,dom_version_id)
SELECT '$TA','A社','a.example', id FROM catalog.dom_versions WHERE is_current;
INSERT INTO app.tenants (id,name,domain,dom_version_id)
SELECT '$TB','B社','b.example', id FROM catalog.dom_versions WHERE is_current;
INSERT INTO app.users (id,tenant_id,email,display_name,status) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001','$TA','a@a.example','A','active'),
  ('aaaaaaaa-0000-0000-0000-000000000002','$TA','c@a.example','C','active'),
  ('aaaaaaaa-0000-0000-0000-000000000003','$TA','employee@a.example','Employee','active'),
  ('aaaaaaaa-0000-0000-0000-000000000004','$TA','inactive@a.example','Inactive','suspended'),
  ('bbbbbbbb-0000-0000-0000-000000000001','$TB','b@b.example','B','active');
INSERT INTO app.memberships (tenant_id,user_id,role_key) VALUES
  ('$TA','aaaaaaaa-0000-0000-0000-000000000001','ciso'),
  ('$TA','aaaaaaaa-0000-0000-0000-000000000002','ciso'),
  ('$TA','aaaaaaaa-0000-0000-0000-000000000003','employee'),
  ('$TB','bbbbbbbb-0000-0000-0000-000000000001','ciso');
SELECT app.create_session('$TA','aaaaaaaa-0000-0000-0000-000000000001','$TOKEN_A');
SELECT app.create_session('$TA','aaaaaaaa-0000-0000-0000-000000000002','$TOKEN_C');
SELECT app.create_session('$TA','aaaaaaaa-0000-0000-0000-000000000003','$TOKEN_D');
SELECT app.create_session('$TB','bbbbbbbb-0000-0000-0000-000000000001','$TOKEN_B');
INSERT INTO app.vendors (tenant_id,name) VALUES ('$TA','A社の委託先'),('$TB','B社の委託先');
SQL
  then
    printf '  \033[31mFAIL\033[0m セットアップに失敗しました\n'
    exit 1
  fi
  if ! psql -w -q -v ON_ERROR_STOP=1 "$AUTH" -c "SELECT app.register_internal_management_service_principal('$TA','aaaaaaaa-0000-0000-0000-000000000002','M1 test service')" </dev/null >/dev/null; then
    printf '  \033[31mFAIL\033[0m service principal setup failed\n'
    exit 1
  fi
}

echo "== テナント分離・テナント文脈の受入試験 =="
fixture

echo "-- 受入 #7 テナント文脈"
expect_ok "正規経路: トークンで文脈を確立し自テナントだけが見える" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
DO \$\$ BEGIN
  IF (SELECT count(*) FROM app.vendors) <> 1 THEN RAISE EXCEPTION 'expected 1 row'; END IF;
  IF (SELECT name FROM app.vendors) <> 'A社の委託先' THEN RAISE EXCEPTION 'wrong row'; END IF;
END \$\$;
COMMIT;"

expect_err "文脈未設定の接続は拒否される" "$RW" "
SELECT count(*) FROM app.vendors;" "tenant context is not set"

expect_err "set_tenant_context を経由せず直接 SET しても到達できない" "$RW" "
BEGIN;
SET LOCAL app.tenant_id = '$TB';
SELECT count(*) FROM app.vendors;
COMMIT;" "not signed"

expect_err "他テナントの ID へ差し替えると署名が合わず落ちる" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
SET LOCAL app.tenant_id = '$TB';
SELECT count(*) FROM app.vendors;
COMMIT;" "signature mismatch"

expect_err "存在しないトークンでは文脈を作れない" "$RW" "
SELECT app.set_tenant_context('NOSUCHTOKEN-000000000000000000000000000');" "invalid session"

expect_err "短すぎるトークンは拒否される（最低エントロピー）" "$RW" "
SELECT app.set_tenant_context('short');" "invalid session"

expect_ok "proxy context は専用roleで同一テナントの正規化メール本人へ署名する" "$PROXY" "
BEGIN;
SET LOCAL SESSION AUTHORIZATION management_web;
SELECT app.set_tenant_context_for_proxy('$TOKEN_C','A@A.EXAMPLE'::citext);
DO \$\$ BEGIN
  IF app.current_tenant() <> '$TA'::uuid
     OR app.current_session_user() <> 'aaaaaaaa-0000-0000-0000-000000000001'::uuid THEN
    RAISE EXCEPTION 'proxy context identity mismatch';
  END IF;
  IF app.management_proxy_healthcheck()->>'actor_id'
       <> 'aaaaaaaa-0000-0000-0000-000000000001' THEN
    RAISE EXCEPTION 'proxy health identity mismatch';
  END IF;
END \$\$;
COMMIT;"

expect_err "app_rw はproxy本人性を生成できない" "$RW" "
SELECT app.set_tenant_context_for_proxy('$TOKEN_A','a@a.example'::citext);" "permission denied"

expect_err "proxy context は別テナントのメールを拒否する" "$PROXY" "
BEGIN;
SET LOCAL SESSION AUTHORIZATION management_web;
SELECT app.set_tenant_context_for_proxy('$TOKEN_A','b@b.example'::citext);
COMMIT;" "invalid session or identity"

expect_err "proxy context は未知メールを拒否する" "$PROXY" "
BEGIN;
SET LOCAL SESSION AUTHORIZATION management_web;
SELECT app.set_tenant_context_for_proxy('$TOKEN_A','unknown@a.example'::citext);
COMMIT;" "invalid session or identity"

expect_err "proxy context は停止済み従業員を拒否する" "$PROXY" "
BEGIN;
SET LOCAL SESSION AUTHORIZATION management_web;
SELECT app.set_tenant_context_for_proxy('$TOKEN_A','inactive@a.example'::citext);
COMMIT;" "invalid session or identity"

echo "-- 受入 #9 テナント越境（app_rw の実接続で全操作）"
expect_err "A の文脈で B の行を SELECT できない（0 件になる）" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
DO \$\$ BEGIN
  IF EXISTS (SELECT 1 FROM app.vendors WHERE tenant_id = '$TB') THEN
    RAISE EXCEPTION 'cross-tenant row is visible';
  END IF;
  RAISE EXCEPTION 'expected-no-cross-tenant';
END \$\$;
COMMIT;" "expected-no-cross-tenant"

expect_err "A の文脈で B の tenant_id を INSERT できない" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
INSERT INTO app.vendors (tenant_id, name) VALUES ('$TB','侵入');
COMMIT;" "row-level security"

expect_ok "A の文脈で B の行を UPDATE/DELETE しても 0 行（不可視なので触れない）" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
DO \$\$
DECLARE n int;
BEGIN
  UPDATE app.vendors SET name='書換' WHERE tenant_id='$TB';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 0 THEN RAISE EXCEPTION 'cross-tenant UPDATE affected % rows', n; END IF;
  DELETE FROM app.vendors WHERE tenant_id='$TB';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 0 THEN RAISE EXCEPTION 'cross-tenant DELETE affected % rows', n; END IF;
END \$\$;
COMMIT;"

echo "-- 受入 #6 監査ログと app_ro"
expect_err "app_ro は書けない" "$RO" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
INSERT INTO app.vendors (tenant_id, name) VALUES ('$TA','読み取り専用のはず');
COMMIT;" "permission denied"

expect_err "app_rw は audit_log を UPDATE できない" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
UPDATE audit.audit_log SET action='改ざん';
COMMIT;" "permission denied"

expect_err "app_rw は audit_log を DELETE できない" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
DELETE FROM audit.audit_log;
COMMIT;" "permission denied"

expect_err "T-09: app_rw は audit_log へ直接 INSERT できない" "$RW" "
INSERT INTO audit.audit_log (
  chain_seq, tenant_id, occurred_at, appended_at, actor_id, actor_type,
  action, hash, signature
) VALUES (99, '$TA', now(), now(),
          'aaaaaaaa-0000-0000-0000-000000000001', 'user', 'direct.insert',
          '\\x00'::bytea, '\\x00'::bytea);" "permission denied"

expect_err "M1: app_rw は framework relation を直接 INSERT できない" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
INSERT INTO app.asset_frameworks (tenant_id,asset_id,framework_key)
VALUES ('$TA','00000000-0000-0000-0000-000000000201','RISK-MANAGEMENT');
COMMIT;" "permission denied"

expect_err "M1: app_rw は risk_acceptances へ直接 INSERT できない" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
INSERT INTO app.risk_acceptances DEFAULT VALUES;
COMMIT;" "permission denied"

expect_err "M1: app_rw は internal management receipt を UPDATE できない" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
UPDATE app.internal_management_operations SET receipt='{}'::jsonb;
COMMIT;" "permission denied"

expect_err "M1: app_rw は internal management receipt を直接 INSERT できない" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
INSERT INTO app.internal_management_operations
  (tenant_id,operation_id,action,request_sha256,receipt,actor_id,requester_actor_id,origin_kind)
VALUES
  (app.current_tenant(),'aaaaaaaaaaaa','tag_iso',repeat('a',64),'{}'::jsonb,
   'aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','service');
COMMIT;" "permission denied"

expect_err "M1: app_rw は approval evidence を直接作れない" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
INSERT INTO app.internal_management_acceptance_approvals DEFAULT VALUES;
COMMIT;" "permission denied"

expect_err "M1: app_rw は汎用 approval を直接作れない" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
INSERT INTO app.approvals DEFAULT VALUES;
COMMIT;" "permission denied"

expect_err "M1: 通常の human session は requester を指名しても internal RPC を呼べない" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
SELECT app.internal_tag_iso('eeeeeeeeeeee',repeat('e',64),
  'aaaaaaaa-0000-0000-0000-000000000001','ciso',
  'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa');
COMMIT;" "MANAGEMENT_SERVICE_FORBIDDEN"

expect_err "M1: employee は人手 framework 更新を実行できない" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_D');
INSERT INTO app.assets (tenant_id,id,asset_key,name,asset_type,classification)
VALUES (app.current_tenant(),'aaaaaaaa-1212-4121-8121-aaaaaaaaaaaa',
        'employee-framework','employee framework','system','internal');
SELECT app.set_management_frameworks_human('asset','aaaaaaaa-1212-4121-8121-aaaaaaaaaaaa',ARRAY['RISK-MANAGEMENT']);
COMMIT;" "management framework role required"

expect_err "M1: employee は policy version を承認できない" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_D');
SELECT app.approve_policy_version('aaaaaaaa-8888-4888-8888-aaaaaaaaaaaa','employee approval');
COMMIT;" "executive role required"

expect_err "M1: service RPC は cross-tenant requester を拒否する" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_C');
SELECT app.internal_tag_iso('ffffffffffff',repeat('f',64),
  'bbbbbbbb-0000-0000-0000-000000000001','ciso',
  'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa');
COMMIT;" "MANAGEMENT_REQUESTER_FORBIDDEN"

expect_err "M1: service RPC は revoked requester を拒否する" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_C');
UPDATE app.memberships SET revoked_at=now()
 WHERE tenant_id=app.current_tenant()
   AND user_id='aaaaaaaa-0000-0000-0000-000000000001' AND role_key='ciso';
SELECT app.internal_tag_iso('abababababab',repeat('a',64),
  'aaaaaaaa-0000-0000-0000-000000000001','ciso',
  'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa');
COMMIT;" "MANAGEMENT_REQUESTER_FORBIDDEN"

expect_err "M1: tag role は ciso/secretariat 以外を拒否する" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_C');
SELECT app.internal_tag_iso('acacacacacac',repeat('a',64),
  'aaaaaaaa-0000-0000-0000-000000000001','auditor',
  'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa');
COMMIT;" "MANAGEMENT_REQUESTER_FORBIDDEN"

expect_err "M1: ISO除外requestは一般従業員を拒否する" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_D');
SELECT app.request_iso_framework_removal('risk_scenario','aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
  'aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa',decode(repeat('00',32),'hex'),
  decode(repeat('00',32),'hex'),'reason','alternate',now()+interval '1 day');
COMMIT;" "ISO removal requester role required"

expect_err "M1: ISO除外approveは一般従業員を拒否する" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_D');
SELECT app.approve_iso_framework_removal('aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa');
COMMIT;" "executive role required"

expect_err "M1: ISO除外executeは一般従業員を拒否する" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_D');
SELECT app.execute_iso_framework_removal_v2('aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa');
COMMIT;" "ISO removal executor role required"

expect_ok "M1: 固定 RPC は tag と immutable receipt を原子的に記録する" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_C');
INSERT INTO app.risk_scenarios
  (tenant_id,id,risk_key,domain,area,phase,theme,measure,frame,summary,status)
VALUES
  (app.current_tenant(),'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','M1-RISK','M1','M1',1,
   'M1','M1','管理可能性','M1 controlled path','active');
SELECT app.internal_tag_iso(
  'bbbbbbbbbbbb',repeat('b',64),'aaaaaaaa-0000-0000-0000-000000000001',
  'ciso','aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa');
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;"

expect_ok "M1: snapshot受容と別人承認ISO除外の正規経路が成功する" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_C');
INSERT INTO app.measures
  (tenant_id,id,measure_key,name,summary,strategy,status)
VALUES
  (app.current_tenant(),'aaaaaaaa-3333-4333-8333-aaaaaaaaaaaa',
   'M1-MEASURE','M1 measure','M1 measure','mitigate','retired');
INSERT INTO app.risk_scenarios
  (tenant_id,id,risk_key,domain,area,phase,theme,measure,frame,summary,status)
VALUES
  (app.current_tenant(),'aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa',
   'M1-ACCEPT','M1','M1',1,'M1','M1','管理可能性','M1 acceptance path','active');
SELECT app.internal_tag_iso(
  'cccccccccccc',repeat('c',64),'aaaaaaaa-0000-0000-0000-000000000001',
  'ciso','aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa');
INSERT INTO app.policies (tenant_id,id,title)
VALUES (app.current_tenant(),'aaaaaaaa-7777-4777-8777-aaaaaaaaaaaa','M1 policy');
INSERT INTO app.policy_versions (tenant_id,id,policy_id,version,body_md,effective_from)
VALUES (app.current_tenant(),'aaaaaaaa-8888-4888-8888-aaaaaaaaaaaa',
        'aaaaaaaa-7777-4777-8777-aaaaaaaaaaaa',1,'M1 policy',
        (now() AT TIME ZONE 'Asia/Tokyo')::date);
SELECT app.approve_policy_version('aaaaaaaa-8888-4888-8888-aaaaaaaaaaaa','M1 policy approval');
INSERT INTO app.risk_evaluation_snapshots
  (tenant_id,id,risk_scenario_id,stage,assessed_on,probability,impact,rationale,created_at)
VALUES
  (app.current_tenant(),'aaaaaaaa-5555-4555-8555-555555555554',
   'aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa','inherent',(now() AT TIME ZONE 'Asia/Tokyo')::date,4,4,'older inherent tie','2026-01-01 00:00:00+00'),
  (app.current_tenant(),'aaaaaaaa-5555-4555-8555-aaaaaaaaaaaa',
   'aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa','inherent',(now() AT TIME ZONE 'Asia/Tokyo')::date,4,4,'latest inherent tie','2026-01-01 00:00:00+00'),
  (app.current_tenant(),'ffffffff-5555-4555-8555-ffffffffffff',
   'aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa','inherent',(now() AT TIME ZONE 'Asia/Tokyo')::date+1,5,5,'future inherent','2026-01-02 00:00:00+00');
INSERT INTO app.risk_evaluation_snapshots
  (tenant_id,id,risk_scenario_id,measure_id,stage,assessed_on,probability,impact,rationale,created_at)
VALUES
  (app.current_tenant(),'aaaaaaaa-6666-4666-8666-666666666665',
   'aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa','aaaaaaaa-3333-4333-8333-aaaaaaaaaaaa',
   'after_measure',(now() AT TIME ZONE 'Asia/Tokyo')::date,2,2,'older residual tie','2026-01-01 00:00:00+00'),
  (app.current_tenant(),'aaaaaaaa-6666-4666-8666-aaaaaaaaaaaa',
   'aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa','aaaaaaaa-3333-4333-8333-aaaaaaaaaaaa',
   'after_measure',(now() AT TIME ZONE 'Asia/Tokyo')::date,2,2,'latest residual tie','2026-01-01 00:00:00+00'),
  (app.current_tenant(),'ffffffff-6666-4666-8666-ffffffffffff',
   'aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa','aaaaaaaa-3333-4333-8333-aaaaaaaaaaaa',
   'after_measure',(now() AT TIME ZONE 'Asia/Tokyo')::date+1,1,1,'future residual','2026-01-02 00:00:00+00');
SELECT app.set_tenant_context('$TOKEN_A');
CREATE TEMP TABLE m1_approval AS
SELECT app.approve_internal_risk_acceptance(
  'dddddddddddd','aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa',residual.id,
  app.risk_evaluation_snapshot_sha256(residual),inherent.id,
  app.risk_evaluation_snapshot_sha256(inherent),
  'aaaaaaaa-8888-4888-8888-aaaaaaaaaaaa',
  encode(public.digest(convert_to('M1 policy','UTF8'),'sha256'),'hex'),
  'accepted with evidence',now()+interval '30 days') AS id
  FROM app.risk_evaluation_snapshots residual,app.risk_evaluation_snapshots inherent
 WHERE residual.id='aaaaaaaa-6666-4666-8666-aaaaaaaaaaaa'
   AND inherent.id='aaaaaaaa-5555-4555-8555-aaaaaaaaaaaa';
SELECT app.set_tenant_context('$TOKEN_C');
SELECT app.internal_accept_risk(
  'dddddddddddd',repeat('d',64),'aaaaaaaa-0000-0000-0000-000000000001','ciso',
  (SELECT id FROM m1_approval),'aaaaaaaa-8888-4888-8888-aaaaaaaaaaaa',
  encode(public.digest(convert_to('M1 policy','UTF8'),'sha256'),'hex'),
  'aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa',residual.id,
  app.risk_evaluation_snapshot_sha256(residual),inherent.id,
  app.risk_evaluation_snapshot_sha256(inherent),'accepted with evidence',now()+interval '30 days')
  FROM app.risk_evaluation_snapshots residual,app.risk_evaluation_snapshots inherent
 WHERE residual.id='aaaaaaaa-6666-4666-8666-aaaaaaaaaaaa'
   AND inherent.id='aaaaaaaa-5555-4555-8555-aaaaaaaaaaaa';
SELECT app.internal_accept_risk(
  'dddddddddddd',repeat('d',64),'aaaaaaaa-0000-0000-0000-000000000001','ciso',
  (SELECT id FROM m1_approval),'aaaaaaaa-8888-4888-8888-aaaaaaaaaaaa',
  encode(public.digest(convert_to('M1 policy','UTF8'),'sha256'),'hex'),
  'aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa',residual.id,
  app.risk_evaluation_snapshot_sha256(residual),inherent.id,
  app.risk_evaluation_snapshot_sha256(inherent),'accepted with evidence',now()+interval '30 days')
  FROM app.risk_evaluation_snapshots residual,app.risk_evaluation_snapshots inherent
 WHERE residual.id='aaaaaaaa-6666-4666-8666-aaaaaaaaaaaa'
   AND inherent.id='aaaaaaaa-5555-4555-8555-aaaaaaaaaaaa';
WITH relation AS (
  SELECT generation_id FROM app.framework_relation_origins
   WHERE entity_type='risk_scenario'
     AND entity_id='aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa'
     AND framework_key='ISO27001:2022'
)
SELECT app.request_iso_framework_removal(
  'risk_scenario','aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa',generation_id,
  public.digest(convert_to('risk_scenario:aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa:ISO27001:2022:'||generation_id::text,'UTF8'),'sha256'),
  public.digest(convert_to('risk_scenario:aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa:WITHOUT:ISO27001:2022:'||generation_id::text,'UTF8'),'sha256'),
  'remove ISO','alternate control',now()+interval '1 day') FROM relation;
SELECT app.set_tenant_context('$TOKEN_A');
SELECT app.approve_iso_framework_removal(id) FROM app.iso_framework_removal_requests
 WHERE entity_id='aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa';
SELECT app.set_tenant_context('$TOKEN_C');
SELECT app.execute_iso_framework_removal_v2(id) FROM app.iso_framework_removal_requests
 WHERE entity_id='aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa';
DO \$\$ BEGIN
  IF (SELECT count(*) FROM app.risk_acceptances
       WHERE risk_scenario_id='aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa') <> 1 THEN
    RAISE EXCEPTION 'snapshot acceptance missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app.risk_acceptances
                  WHERE risk_scenario_id='aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa'
                    AND evaluation_snapshot_id='aaaaaaaa-6666-4666-8666-aaaaaaaaaaaa'
                    AND inherent_snapshot_id='aaaaaaaa-5555-4555-8555-aaaaaaaaaaaa') THEN
    RAISE EXCEPTION 'same-timestamp snapshot tie was not resolved by UUID';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app.internal_management_operations
                  WHERE operation_id='dddddddddddd'
                    AND acceptance_reason='accepted with evidence'
                    AND acceptance_expires_at>now()) THEN
    RAISE EXCEPTION 'canonical acceptance payload missing';
  END IF;
  IF EXISTS (SELECT 1 FROM app.risk_scenario_frameworks
              WHERE risk_scenario_id='aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa'
                AND framework_key='ISO27001:2022') THEN
    RAISE EXCEPTION 'ISO relation remains';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app.risk_scenario_frameworks
                  WHERE risk_scenario_id='aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa'
                    AND framework_key='RISK-MANAGEMENT') THEN
    RAISE EXCEPTION 'management relation lost';
  END IF;
END \$\$;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;"

expect_err "M1: 旧 accept_risk は app_rw から実行できない" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
SELECT app.accept_risk('00000000-0000-0000-0000-000000000201',0,1,1,'legacy');
COMMIT;" "does not exist"

echo "-- 受入 #8 接続プール（文脈がトランザクションを越えて残らない）"
expect_err "同一接続でも COMMIT 後は文脈が消えている" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
COMMIT;
SELECT count(*) FROM app.vendors;" "tenant context is not set"

expect_err "autocommit で set_tenant_context だけ呼んでも次の文には残らない" "$RW" "
SELECT app.set_tenant_context('$TOKEN_A');
SELECT count(*) FROM app.vendors;" "tenant context is not set"

expect_err "ROLLBACK すると文脈は戻る" "$RW" "
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
ROLLBACK;
SELECT count(*) FROM app.vendors;" "tenant context is not set"

echo "-- 受入 #9 越境の網羅（vendors だけでなく tenant_id を持つ全テーブル）"
# Checking just one table misses policy gaps in other tables.
# Enumerate all tables with tenant_id and verify B's data isn't visible in A's context.
# To avoid inserting data, put tenant_id directly in the condition and check that "no rows are returned".
TABLES=$(psql -At "$ADMIN" -c "
  select c.relname from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    join pg_attribute a on a.attrelid=c.oid and a.attname='tenant_id' and not a.attisdropped
   where n.nspname='app' and c.relkind='r'
     and c.relname not in ('sessions','device_enrollment_tokens','verification_receipts',
                           'internal_management_service_principals','internal_management_acceptance_approvals')
   order by c.relname")
# If the enumeration fails and comes back empty, the following loop never runs
# and it reports "all tables passed". Always fail if the count is below expectations.
TABLE_COUNT=$(printf '%s\n' $TABLES | grep -c . || true)
if [ "${TABLE_COUNT:-0}" -lt 20 ]; then
  ng "テーブル列挙に失敗（${TABLE_COUNT:-0} 件）。この状態の合格は信用できない"
  printf '\n  合計: \033[32m%d PASS\033[0m / \033[31m%d FAIL\033[0m\n' "$pass" "$fail"
  exit 1
fi

# 0 cross-tenant rows is not enough. Dropping all policies also makes rows "invisible", yielding 0,
# which can't be distinguished from correct isolation (confirmed by measurement).
# Also check within the same test that "the isolation policies are in place".
nopolicy=$(psql -At "$ADMIN" -c "
  select string_agg(c.relname, ' ') from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    join pg_attribute a on a.attrelid=c.oid and a.attname='tenant_id' and not a.attisdropped
   where n.nspname='app' and c.relkind='r'
     and c.relname not in ('sessions','device_enrollment_tokens','verification_receipts',
                           'internal_management_service_principals','internal_management_acceptance_approvals')
     and (not exists (select 1 from pg_policies p
                       where p.schemaname='app' and p.tablename=c.relname
                         and p.policyname='tenant_isolation'
                         and p.roles = array['app_rw']::name[])
       or not exists (select 1 from pg_policies p
                       where p.schemaname='app' and p.tablename=c.relname
                         and p.policyname='tenant_read'
                         and p.roles = array['app_ro']::name[]))")
[ -z "$nopolicy" ] && ok "全テーブルに tenant_isolation / tenant_read が張られている" \
                   || ng "分離ポリシーが欠けているテーブル: $nopolicy"

crossed=""
unreadable=""
for t in $TABLES; do
  out=$(psql -At -v ON_ERROR_STOP=1 "$RW" <<SQL 2>&1
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
SELECT count(*) FROM app.$t WHERE tenant_id = '$TB';
COMMIT;
SQL
)
  if [ $? -ne 0 ]; then
    unreadable="$unreadable $t"
  else
    # Output lists BEGIN / uuid / count / COMMIT. Take the last numeric-only line.
    n=$(printf '%s\n' "$out" | grep -E '^[0-9]+$' | tail -1)
    [ "$n" = "0" ] || crossed="$crossed $t(${n:-読めず})"
  fi
done
[ -z "$crossed" ] || ng "他テナントの行が見えるテーブル:$crossed"
[ -z "$unreadable" ] || ng "app_rw が読めないテーブル（権限漏れ）:$unreadable"
if [ -z "$crossed" ] && [ -z "$unreadable" ]; then
  ok "app_rw: tenant_id を持つ $(printf '%s\n' $TABLES | wc -l | tr -d ' ') テーブル全てで越境 0 件"
fi

ro_bad=""
for t in $TABLES; do
  out=$(psql -At -v ON_ERROR_STOP=1 "$RO" <<SQL 2>&1
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
SELECT count(*) FROM app.$t WHERE tenant_id = '$TB';
COMMIT;
SQL
)
  if [ $? -ne 0 ]; then ro_bad="$ro_bad $t"
  else
    n=$(printf '%s\n' "$out" | grep -E '^[0-9]+$' | tail -1)
    [ "$n" = "0" ] || ro_bad="$ro_bad $t(${n:-読めず})"
  fi
done
[ -z "$ro_bad" ] && ok "app_ro: 同じく全テーブルで越境 0 件" \
                 || ng "app_ro で問題のあるテーブル:$ro_bad"

echo "-- 受入 #14 監査人の兼任禁止"
expect_err "監査人と他ロールの兼任を DB が拒否する" "$ADMIN" "
INSERT INTO app.memberships (tenant_id,user_id,role_key)
VALUES ('$TA','aaaaaaaa-0000-0000-0000-000000000001','auditor');" \
"auditor role cannot be combined"

echo "-- セッションの失効"
expect_err "revoke したトークンでは文脈を作れない" "$RW" "
SELECT app.revoke_session('$TOKEN_A');
SELECT app.set_tenant_context('$TOKEN_A');" "invalid session"

fixture   # restore for subsequent tests

printf '\n  合計: \033[32m%d PASS\033[0m / \033[31m%d FAIL\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
