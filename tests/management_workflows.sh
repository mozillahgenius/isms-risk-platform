#!/usr/bin/env bash
# Isolated M3 workflow acceptance: roles, tenant isolation, expiry, close, history, rollback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${ISMS_TEST_DB:-isms_management_workflows_$$}"
die() { printf '[management workflows] %s\n' "$*" >&2; exit 1; }
expect_fail() { if "$@" >/dev/null 2>&1; then die "unexpected success: $*"; fi; }
# 落ちたことだけでなく「狙った理由で落ちたか」を確かめる。理由を見ないと、
# 存在しないIDや別の制約違反でも通ってしまい、検査が空振りする。
expect_fail_because() {
  local want="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then die "unexpected success: $*"; fi
  case "$out" in
    *"$want"*) ;;
    *) die "failed for the wrong reason (want '$want'): $out" ;;
  esac
}
sql() { psql -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

[ "$DB" != "isms_dev" ] || die "refuse shared db"
psql -At -d postgres -c "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -qx 1 && die "refuse existing database"
createdb "$DB"; trap 'dropdb --if-exists "$DB" >/dev/null 2>&1' EXIT
export ISMS_DB="$DB"; unset DATABASE_URL || true
"$ROOT/scripts/migrate.sh" up >/dev/null
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null

sql <<'SQL'
INSERT INTO catalog.asset_classes_default(key,name_ja,rank,external_share_policy) VALUES ('internal','fixture',1,'approval_required') ON CONFLICT DO NOTHING;
INSERT INTO app.tenants(id,name,domain,dom_version_id) SELECT '10000000-0000-4000-8000-000000000001','one','one.test',id FROM catalog.dom_versions LIMIT 1;
INSERT INTO app.tenants(id,name,domain,dom_version_id) SELECT '20000000-0000-4000-8000-000000000001','two','two.test',id FROM catalog.dom_versions LIMIT 1;
INSERT INTO app.users(tenant_id,id,email,display_name) VALUES
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000011','requester@one.test','requester'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000012','owner@one.test','owner'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000013','ciso@one.test','ciso'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000014','viewer@one.test','viewer'),
 ('20000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000011','other@two.test','other');
INSERT INTO app.memberships(tenant_id,user_id,role_key) VALUES
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000011','secretariat'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000012','risk_owner'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000013','ciso'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000013','secretariat'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000014','employee'),
 ('20000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000011','risk_owner');
SQL

# 有効な資産は RISK-MANAGEMENT を持たなければならない（0050 の制約トリガー）。
# この不変条件は 0061 まで実際には発火していなかった（SECURITY DEFINER の判定関数が
# FORCE RLS で app.assets を 1 行も読めず、is_active が NULL のまま素通りしていた）。
# 0061 で所有者向けの SELECT ポリシーが付き、初めて効くようになったので、
# 以後この fixture も枠組みを付ける。
# Use signed context helpers by making short-lived sessions as auth_svc is not needed in this isolated fixture.
token_for() { local tenant="$1" user="$2" token="$3"; sql -c "SET ROLE auth_svc; SELECT app.create_session('$tenant','$user','$token',interval '1 hour'); RESET ROLE" >/dev/null; }
token_for 10000000-0000-4000-8000-000000000001 10000000-0000-4000-8000-000000000011 requester-token-000000000000000000000000000001
token_for 10000000-0000-4000-8000-000000000001 10000000-0000-4000-8000-000000000012 owner-token-000000000000000000000000000000002
token_for 10000000-0000-4000-8000-000000000001 10000000-0000-4000-8000-000000000013 ciso-token-000000000000000000000000000000003
token_for 10000000-0000-4000-8000-000000000001 10000000-0000-4000-8000-000000000014 viewer-token-0000000000000000000000000000004
token_for 20000000-0000-4000-8000-000000000001 20000000-0000-4000-8000-000000000011 other-token-00000000000000000000000000000005

call_as() { local token="$1" statement="$2"; PGPASSWORD='' psql -Atq -v ON_ERROR_STOP=1 -U app_rw -d "$DB" -c "BEGIN; SELECT app.set_tenant_context('$token'); $statement COMMIT;"; }
call_as requester-token-000000000000000000000000000001 "INSERT INTO app.risk_scenarios(tenant_id,id,risk_key,domain,area,phase,theme,measure,frame,summary,status) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000021','m3-risk','m3','m3',1,'m3','m3','管理可能性','m3','active'); SELECT app.set_management_frameworks_human('risk_scenario','10000000-0000-4000-8000-000000000021',ARRAY['RISK-MANAGEMENT']);" >/dev/null
call_as other-token-00000000000000000000000000000005 "INSERT INTO app.risk_scenarios(tenant_id,id,risk_key,domain,area,phase,theme,measure,frame,summary,status) VALUES(app.current_tenant(),'20000000-0000-4000-8000-000000000021','other-risk','m3','m3',1,'m3','m3','管理可能性','m3','active'); SELECT app.set_management_frameworks_human('risk_scenario','20000000-0000-4000-8000-000000000021',ARRAY['RISK-MANAGEMENT']);" >/dev/null
call_as requester-token-000000000000000000000000000001 "INSERT INTO app.measures(tenant_id,id,measure_key,name,summary,strategy,status) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000031','m3-measure','m3','m3','mitigate','planned'); SELECT app.set_management_frameworks_human('measure','10000000-0000-4000-8000-000000000031',ARRAY['RISK-MANAGEMENT']);" >/dev/null
call_as requester-token-000000000000000000000000000001 "INSERT INTO app.assets(tenant_id,id,asset_key,name,asset_type,classification) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000071','assigned-asset','assigned asset','system','internal'); SELECT app.set_management_frameworks_human('asset','10000000-0000-4000-8000-000000000071',ARRAY['RISK-MANAGEMENT']); INSERT INTO app.work_items(tenant_id,id,work_type,title,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000072','asset_inventory','asset inventory',app.current_session_user(),app.current_session_user()); INSERT INTO app.work_item_assignees(tenant_id,work_item_id,user_id,assignment_role,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000072','10000000-0000-4000-8000-000000000014','editor',app.current_session_user(),app.current_session_user());" >/dev/null
call_as viewer-token-0000000000000000000000000000004 "UPDATE app.assets SET name='assigned asset updated' WHERE id='10000000-0000-4000-8000-000000000071'; SELECT app.set_management_frameworks_for_work('asset','10000000-0000-4000-8000-000000000071',ARRAY['RISK-MANAGEMENT']);" >/dev/null
[ "$(sql -At -c "SELECT name FROM app.assets WHERE id='10000000-0000-4000-8000-000000000071'")" = 'assigned asset updated' ] || die "assigned member asset update failed"
[ "$(sql -At -c "SELECT count(*) FROM app.asset_frameworks WHERE asset_id='10000000-0000-4000-8000-000000000071' AND framework_key='RISK-MANAGEMENT'")" = 1 ] || die "assigned member framework update failed"
call_as requester-token-000000000000000000000000000001 "UPDATE app.work_item_assignees SET status='completed',completed_at=now() WHERE work_item_id='10000000-0000-4000-8000-000000000072';" >/dev/null
expect_fail_because 'active work assignment required' call_as viewer-token-0000000000000000000000000000004 "SELECT app.require_work_permission('asset','10000000-0000-4000-8000-000000000071','write');"
op=aaaaaaaaaaaa; hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
id="$(call_as requester-token-000000000000000000000000000001 "SELECT (app.request_management_deviation('$op','$hash','M3 deviation','description','corrective action','10000000-0000-4000-8000-000000000012',now()+interval '2 days',now()+interval '3 days',ARRAY['10000000-0000-4000-8000-000000000021']::uuid[])->>'deviation_id');" | tail -1 | tr -d ' ')"
[ -n "$id" ] || die "authorized request failed"
call_as requester-token-000000000000000000000000000001 "SELECT app.request_management_deviation('$op','$hash','M3 deviation','description','corrective action','10000000-0000-4000-8000-000000000012',now()+interval '2 days',now()+interval '3 days',ARRAY['10000000-0000-4000-8000-000000000021']::uuid[]);" >/dev/null
[ "$(sql -At -c "SELECT count(*) FROM app.management_deviations")" = 1 ] || die "request idempotency failed"
[ "$(sql -At -c "SELECT count(*) FROM app.management_deviation_risks")" = 1 ] || die "risk link missing"
expect_fail call_as ciso-token-000000000000000000000000000000003 "SELECT app.request_management_deviation('$op','$hash','M3 deviation','description','corrective action','10000000-0000-4000-8000-000000000012',now()+interval '2 days',now()+interval '3 days',ARRAY['10000000-0000-4000-8000-000000000021']::uuid[]);"
expect_fail call_as viewer-token-0000000000000000000000000000004 "SELECT app.request_management_deviation('bbbbbbbbbbbb','$hash','x','x','x','10000000-0000-4000-8000-000000000012',now()+interval '2 days',now()+interval '3 days');"
expect_fail call_as requester-token-000000000000000000000000000001 "SELECT app.approve_management_deviation('$id','bbbbbbbbbbbb','$hash');"
approve_op=dddddddddddd; approve_hash=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
call_as ciso-token-000000000000000000000000000000003 "SELECT app.approve_management_deviation('$id','$approve_op','$approve_hash');" >/dev/null
call_as ciso-token-000000000000000000000000000000003 "SELECT app.approve_management_deviation('$id','$approve_op','$approve_hash');" >/dev/null
expect_fail call_as ciso-token-000000000000000000000000000000003 "SELECT app.approve_management_deviation('$id','$approve_op','eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee');"
close_op=eeeeeeeeeeee; close_hash=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
call_as owner-token-000000000000000000000000000000002 "SELECT app.close_management_deviation('$id','completed','$close_op','$close_hash');" >/dev/null
call_as owner-token-000000000000000000000000000000002 "SELECT app.close_management_deviation('$id','completed','$close_op','$close_hash');" >/dev/null
[ "$(sql -At -c "SELECT status FROM app.management_deviations WHERE id='$id'")" = closed ] || die "close failed"
expect_fail call_as ciso-token-000000000000000000000000000000003 "SELECT app.close_management_deviation('$id','completed','$close_op','$close_hash');"
expect_fail call_as other-token-00000000000000000000000000000005 "SELECT app.close_management_deviation('$id','cross tenant','ffffffffffff','$close_hash');"
SELF_ID="$(call_as ciso-token-000000000000000000000000000000003 "SELECT (app.request_management_deviation('cccccccccccc','$hash','self request','description','corrective action','10000000-0000-4000-8000-000000000012',now()+interval '2 days',now()+interval '3 days')->>'deviation_id');" | tail -1 | tr -d ' ')"
expect_fail call_as ciso-token-000000000000000000000000000000003 "SELECT app.approve_management_deviation('$SELF_ID','ffffffffffff','$approve_hash');"
call_as requester-token-000000000000000000000000000001 "UPDATE app.measures SET status='in_progress' WHERE id='10000000-0000-4000-8000-000000000031';" >/dev/null
[ "$(sql -At -c "SELECT count(*) FROM app.measure_change_history")" = 1 ] || die "measure history missing"
expect_fail sql -c "UPDATE app.measure_change_history SET changed_at=now()"
sql <<'SQL'
INSERT INTO app.risk_evaluation_snapshots
  (tenant_id,id,risk_scenario_id,stage,assessed_on,probability,impact,rationale,source_note)
VALUES
  ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000041','10000000-0000-4000-8000-000000000021','inherent',(now() AT TIME ZONE 'Asia/Tokyo')::date,4,4,'fixture','fixture');
INSERT INTO app.risk_evaluation_snapshots
  (tenant_id,id,risk_scenario_id,measure_id,stage,assessed_on,probability,impact,rationale,source_note)
VALUES
  ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000042','10000000-0000-4000-8000-000000000021','10000000-0000-4000-8000-000000000031','after_measure',(now() AT TIME ZONE 'Asia/Tokyo')::date,2,3,'fixture','fixture');
INSERT INTO app.policies(tenant_id,id,title)
VALUES ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000051','Risk acceptance policy');
INSERT INTO app.policy_versions
  (tenant_id,id,policy_id,version,body_md,approved_by,approved_at,effective_from)
VALUES
  ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000052','10000000-0000-4000-8000-000000000051',1,'approved policy','10000000-0000-4000-8000-000000000013',now(),(now() AT TIME ZONE 'Asia/Tokyo')::date);
SQL
accept_op=abababababab; accept_hash=abababababababababababababababababababababababababababababababab
accept_call="SELECT app.accept_risk_snapshot_human_evidenced('$accept_op','$accept_hash','10000000-0000-4000-8000-000000000021','10000000-0000-4000-8000-000000000042',app.risk_evaluation_snapshot_sha256((SELECT s FROM app.risk_evaluation_snapshots s WHERE id='10000000-0000-4000-8000-000000000042')),'10000000-0000-4000-8000-000000000041',app.risk_evaluation_snapshot_sha256((SELECT s FROM app.risk_evaluation_snapshots s WHERE id='10000000-0000-4000-8000-000000000041')),'evidenced acceptance','2026-12-01T18:00:00+09:00','10000000-0000-4000-8000-000000000052',encode(digest(convert_to('approved policy','UTF8'),'sha256'),'hex'));"
call_as ciso-token-000000000000000000000000000000003 "$accept_call" >/dev/null
call_as ciso-token-000000000000000000000000000000003 "$accept_call" >/dev/null
[ "$(sql -At -c "SELECT count(*) FROM app.internal_management_operations WHERE operation_id='$accept_op' AND origin_kind='human'")" = 1 ] || die "human acceptance receipt missing"
[ "$(sql -At -c "SELECT count(*) FROM app.internal_management_audit_events WHERE operation_id='$accept_op' AND acceptance_reason='evidenced acceptance'")" = 1 ] || die "human acceptance audit missing"
[ "$(sql -At -c "SELECT count(*) FROM app.internal_management_acceptance_approvals WHERE operation_id='$accept_op' AND acceptance_reason='evidenced acceptance'")" = 1 ] || die "human acceptance approval missing"
expect_fail call_as ciso-token-000000000000000000000000000000003 "SELECT app.accept_risk_snapshot_human_evidenced('$accept_op','cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd','10000000-0000-4000-8000-000000000021','10000000-0000-4000-8000-000000000042','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','10000000-0000-4000-8000-000000000041','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','changed',now()+interval '31 days','10000000-0000-4000-8000-000000000052','cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc')"
sql -c "UPDATE app.policy_versions SET effective_from=(now() AT TIME ZONE 'Asia/Tokyo')::date+1 WHERE id='10000000-0000-4000-8000-000000000052'" >/dev/null
expect_fail call_as ciso-token-000000000000000000000000000000003 "${accept_call/$accept_op/fefefefefefe}"
sql -c "UPDATE app.policy_versions SET effective_from=(now() AT TIME ZONE 'Asia/Tokyo')::date,superseded_at=now() WHERE id='10000000-0000-4000-8000-000000000052'" >/dev/null
expect_fail call_as ciso-token-000000000000000000000000000000003 "${accept_call/$accept_op/abababababac}"
sql -c "INSERT INTO app.risk_acceptances(tenant_id,risk_scenario_id,expected_version,residual_level,inherent_level,reason,accepted_by) VALUES ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000021',999,1,1,'default expiry','10000000-0000-4000-8000-000000000013')" >/dev/null
[ "$(sql -At -c "SELECT expiry_status FROM app.risk_acceptance_status WHERE expected_version=999")" = current ] || die "acceptance default expiry missing"
expect_fail sql -c "INSERT INTO app.risk_acceptances(tenant_id,risk_scenario_id,expected_version,residual_level,inherent_level,reason,accepted_by,expires_at) VALUES ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000021',998,1,1,'null expiry','10000000-0000-4000-8000-000000000013',NULL)"
expect_fail sql -c "INSERT INTO app.risk_acceptances(tenant_id,risk_scenario_id,expected_version,residual_level,inherent_level,reason,accepted_by,expires_at) VALUES ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000021',997,1,1,'past expiry','10000000-0000-4000-8000-000000000013',now()-interval '1 day')"
sql -c "ALTER TABLE app.risk_acceptances DISABLE TRIGGER risk_acceptances_future_expiry" >/dev/null
sql -c "INSERT INTO app.risk_acceptances(tenant_id,risk_scenario_id,expected_version,residual_level,inherent_level,reason,accepted_by,expires_at) VALUES ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000021',996,1,1,'legacy expiry','10000000-0000-4000-8000-000000000013',NULL)" >/dev/null
sql -c "ALTER TABLE app.risk_acceptances ENABLE TRIGGER risk_acceptances_future_expiry" >/dev/null
[ "$(sql -At -c "SELECT expiry_status FROM app.risk_acceptance_status WHERE expected_version=996")" = legacy_unknown ] || die "legacy acceptance status missing"
expect_fail sql -c "UPDATE app.risk_acceptances SET expires_at=now()+interval '2 days' WHERE expected_version=999"

# 教育・訓練は CISO / 事務局だけが取込・評価できる。画面の非表示だけでなく DB で強制する。
expect_fail call_as viewer-token-0000000000000000000000000000004 "INSERT INTO app.trainings(tenant_id,title,fiscal_year) VALUES(app.current_tenant(),'forbidden',2026);"
call_as requester-token-000000000000000000000000000001 "INSERT INTO app.trainings(tenant_id,id,title,fiscal_year,tags,source_system,external_training_id) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000061','ISMS course',2026,ARRAY['isms'],'elearning','course-1'); INSERT INTO app.training_records(tenant_id,training_id,user_id,evidence_ref,source_payload,source_sha256,imported_at) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000061','10000000-0000-4000-8000-000000000014','elearning://course/course-1/year/2026/user/viewer','{\"completed\":true}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',now());" >/dev/null
expect_fail call_as viewer-token-0000000000000000000000000000004 "UPDATE app.training_records SET evaluation_status='有効',evaluated_at=now(),evaluated_by=app.current_session_user() WHERE training_id='10000000-0000-4000-8000-000000000061';"
call_as ciso-token-000000000000000000000000000000003 "UPDATE app.training_records SET evaluation_status='有効',evaluated_at=now(),evaluated_by=app.current_session_user() WHERE training_id='10000000-0000-4000-8000-000000000061';" >/dev/null
[ "$(sql -At -c "SELECT evaluation_status FROM app.training_records WHERE training_id='10000000-0000-4000-8000-000000000061'")" = 有効 ] || die "training evaluation failed"
# eラーニングの取込元が全社共通でも、他テナントの受講者の記録は作れない。
# training_records は (tenant_id,user_id) → app.users(tenant_id,id) の複合FKなので、
# 別テナントの利用者IDを渡した時点で落ちる。取込コードの名寄せに頼らず DB で保証する。
# 使う利用者IDが本当に「別テナントに実在する」ことを先に確かめる。存在しないIDだと
# 同じFK違反でも別の理由になり、検査が意味を失う。
[ "$(sql -At -c "SELECT tenant_id FROM app.users WHERE id='20000000-0000-4000-8000-000000000011'")" = 20000000-0000-4000-8000-000000000001 ] || die "cross-tenant fixture user missing"
expect_fail_because 'training_records_tenant_id_user_id_fkey' call_as requester-token-000000000000000000000000000001 "INSERT INTO app.training_records(tenant_id,training_id,user_id,evidence_ref,source_payload,source_sha256,imported_at) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000061','20000000-0000-4000-8000-000000000011','elearning://course/course-1/year/2026/user/cross-tenant','{\"completed\":true}','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',now());"
# 0054 の一意索引が年度を含むので、同じ external_training_id が年度ごとに別行になる。
# 取込コードが「どの年度の取消か決められない」と判断する根拠がこの分割なので、
# 分割そのものが効いていることを DB 側で固定する（判定規則の検査は
# web/tests/trainingSync.test.ts にある。ここは DB が保証する部分だけを見る）。
# count は必ずテナントで絞る。別テナントに同じ external_training_id があると前提が崩れる。
[ "$(sql -At -c "SELECT count(*) FROM app.trainings WHERE tenant_id='10000000-0000-4000-8000-000000000001' AND source_system='elearning' AND external_training_id='course-1'")" = 1 ] || die "expected a single fiscal year before the second row"
call_as requester-token-000000000000000000000000000001 "INSERT INTO app.trainings(tenant_id,id,title,fiscal_year,tags,source_system,external_training_id) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000062','ISMS course',2025,ARRAY['isms'],'elearning','course-1');" >/dev/null
# 件数だけでなく、実際に別々の年度として並んでいることを見る。
[ "$(sql -At -c "SELECT string_agg(fiscal_year::text,',' ORDER BY fiscal_year) FROM app.trainings WHERE tenant_id='10000000-0000-4000-8000-000000000001' AND source_system='elearning' AND external_training_id='course-1'")" = 2025,2026 ] || die "fiscal-year separated trainings missing"
# 同じ (source_system, external_training_id, fiscal_year) は二重に作れない。
expect_fail_because 'trainings_external_source_unique' call_as requester-token-000000000000000000000000000001 "INSERT INTO app.trainings(tenant_id,id,title,fiscal_year,tags,source_system,external_training_id) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000063','ISMS course',2025,ARRAY['isms'],'elearning','course-1');"
# 連携証跡がある状態で 0054 を戻すとデータを失うため拒否する。
expect_fail sql -f "$ROOT/db/migrations/0054_training_integration_guards.down.sql"
# 0052 の「証跡がある状態では巻き戻せない」という固有の安全弁を直接検証する。
# 後続 migration が増えても、単なる「最新1本の down」へ対象がずれないようにする。
expect_fail sql -f "$ROOT/db/migrations/0052_management_workflows.down.sql"
echo "management_workflows: PASS"
