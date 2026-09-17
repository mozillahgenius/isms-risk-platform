#!/usr/bin/env bash
# 0063 の受入: ISMS の運用記録（内部監査・指摘・是正処置・マネジメントレビュー・統制の有効性評価）の
# 役割・不変条件・承認・テナント分離。使い捨ての DB で走らせる。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${ISMS_TEST_DB:-isms_records_$$}"
die() { printf '[isms records] %s\n' "$*" >&2; exit 1; }
pass() { printf '  PASS %s\n' "$*"; }
# 落ちたことだけでなく「狙った理由で落ちたか」を確かめる（別の理由で落ちても通ってしまう空振りを防ぐ）。
expect_fail_because() {
  local want="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then die "unexpected success: $*"; fi
  case "$out" in *"$want"*) ;; *) die "failed for the wrong reason (want '$want'): $out" ;; esac
}
sql() { psql -w -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

[ "$DB" != "isms_dev" ] || die "refuse shared db"
# どの psql も -w（パスワードを聞かない）。資格情報が足りなければ、止まらずにすぐ落とす
# （無人の配備で psql がパスワードの入力を待ち、受入試験が30分止まった。2026-09-13）。
# 配備では、この DB の資格情報は scripts/configure_runtime_db_roles.py が PGPASSFILE に書く（fixture_databases）。
CREATED_DB=0
# 作った DB は必ず消す。消せなければ試験を失敗にする（残った DB を見逃さない。run_isolated.sh と同じ）。
cleanup() {
  local rc=$?
  if [ "$CREATED_DB" = 1 ] && ! dropdb -w --if-exists "$DB" >/dev/null 2>&1; then
    printf '[isms records] 使い捨て DB %s を消せませんでした\n' "$DB" >&2
    [ "$rc" -ne 0 ] || rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
psql -w -At -d postgres -c "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -qx 1 && die "refuse existing database"
createdb -w "$DB"; CREATED_DB=1
export ISMS_DB="$DB"; unset DATABASE_URL || true
"$ROOT/scripts/migrate.sh" up >/dev/null
psql -w -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null

T1=10000000-0000-4000-8000-000000000001
T2=20000000-0000-4000-8000-000000000001
CISO=10000000-0000-4000-8000-000000000011
ADMIN=10000000-0000-4000-8000-000000000012
MANAGER=10000000-0000-4000-8000-000000000013
MEMBER=10000000-0000-4000-8000-000000000014
AUDITOR=10000000-0000-4000-8000-000000000015
OTHER=20000000-0000-4000-8000-000000000011

sql <<SQL
INSERT INTO app.tenants(id,name,domain,dom_version_id) SELECT '$T1','one','one.test',id FROM catalog.dom_versions LIMIT 1;
INSERT INTO app.tenants(id,name,domain,dom_version_id) SELECT '$T2','two','two.test',id FROM catalog.dom_versions LIMIT 1;
INSERT INTO app.users(tenant_id,id,email,display_name) VALUES
 ('$T1','$CISO','ciso@one.test','ciso'), ('$T1','$ADMIN','admin@one.test','admin'),
 ('$T1','$MANAGER','manager@one.test','manager'), ('$T1','$MEMBER','member@one.test','member'),
 ('$T1','$AUDITOR','auditor@one.test','auditor'), ('$T2','$OTHER','other@two.test','other');
INSERT INTO app.memberships(tenant_id,user_id,role_key) VALUES
 ('$T1','$CISO','ciso'), ('$T1','$ADMIN','secretariat'), ('$T1','$MANAGER','risk_owner'),
 ('$T1','$MEMBER','employee'), ('$T1','$AUDITOR','auditor'), ('$T2','$OTHER','secretariat'),
 -- 他テナントの経営層。承認の権限があっても、別テナントのレビューは見つからないことを確かめるため。
 ('$T2','$OTHER','ciso');
SQL

token_for() { sql -c "SET ROLE auth_svc; SELECT app.create_session('$1','$2','$3',interval '1 hour'); RESET ROLE" >/dev/null; }
token_for $T1 $CISO    ciso-token-0000000000000000000000000000000001
token_for $T1 $ADMIN   admin-token-000000000000000000000000000000002
token_for $T1 $MANAGER manager-token-0000000000000000000000000000003
token_for $T1 $MEMBER  member-token-00000000000000000000000000000004
token_for $T1 $AUDITOR auditor-token-0000000000000000000000000000005
token_for $T2 $OTHER   other-token-00000000000000000000000000000006
call_as() { PGPASSWORD='' psql -w -Atq -v ON_ERROR_STOP=1 -U app_rw -d "$DB" -c "BEGIN; SELECT app.set_tenant_context('$1'); $2 COMMIT;"; }

echo '== 役割（書いてよい記録の種類）'
call_as auditor-token-0000000000000000000000000000005 "SELECT app.require_records_role('audit');" >/dev/null && pass "監査人は監査を書ける"
expect_fail_because 'records role required' call_as member-token-00000000000000000000000000000004 "SELECT app.require_records_role('audit');"
pass "メンバーは監査を書けない"
expect_fail_because 'records role required' call_as auditor-token-0000000000000000000000000000005 "SELECT app.require_records_role('corrective');"
pass "監査人は是正処置を書けない（業務データ）"
call_as manager-token-0000000000000000000000000000003 "SELECT app.require_records_role('corrective');" >/dev/null && pass "マネージャーは是正処置を書ける"
expect_fail_because 'records role required' call_as manager-token-0000000000000000000000000000003 "SELECT app.require_records_role('effectiveness');"
pass "マネージャーは有効性の評価をしない"
expect_fail_because 'records role required' call_as manager-token-0000000000000000000000000000003 "SELECT app.require_records_role('management_review');"
pass "マネージャーはマネジメントレビューを書けない"
expect_fail_because 'unknown record kind' call_as admin-token-000000000000000000000000000000002 "SELECT app.require_records_role('everything');"
pass "知らない種類は拒否"

echo '== 是正処置の不変条件'
call_as admin-token-000000000000000000000000000000002 "
INSERT INTO app.measures(tenant_id,id,measure_key,name,summary,strategy,status) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000031','rec-measure','m','m','mitigate','planned');
SELECT app.set_management_frameworks_human('measure','10000000-0000-4000-8000-000000000031',ARRAY['RISK-MANAGEMENT']);
INSERT INTO app.findings(tenant_id,id,source,title,severity) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000041','manual','f','medium');
INSERT INTO app.corrective_actions(tenant_id,id,finding_id,root_cause,action,owner_user_id) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000051','10000000-0000-4000-8000-000000000041','原因','処置','$MANAGER');" >/dev/null
expect_fail_because 'corrective_actions_effectiveness_after_completion' call_as admin-token-000000000000000000000000000000002 \
  "UPDATE app.corrective_actions SET effectiveness_reviewed_by='$ADMIN', effectiveness_reviewed_at=now(), effectiveness_result='effective' WHERE id='10000000-0000-4000-8000-000000000051';"
pass "処置の完了前に有効性を確認できない"
call_as admin-token-000000000000000000000000000000002 "UPDATE app.corrective_actions SET completed_at=now() WHERE id='10000000-0000-4000-8000-000000000051';" >/dev/null
expect_fail_because 'corrective_actions_reviewer_not_owner' call_as admin-token-000000000000000000000000000000002 \
  "UPDATE app.corrective_actions SET effectiveness_reviewed_by='$MANAGER', effectiveness_reviewed_at=now(), effectiveness_result='effective' WHERE id='10000000-0000-4000-8000-000000000051';"
pass "担当者は自分の処置の有効性を確認できない（職務分離）"
expect_fail_because 'corrective_actions_effectiveness_complete' call_as admin-token-000000000000000000000000000000002 \
  "UPDATE app.corrective_actions SET effectiveness_result='effective' WHERE id='10000000-0000-4000-8000-000000000051';"
pass "確認者・日時・結果は 3 つそろってしか入らない"
call_as admin-token-000000000000000000000000000000002 \
  "UPDATE app.corrective_actions SET effectiveness_reviewed_by='$ADMIN', effectiveness_reviewed_at=now(), effectiveness_result='effective' WHERE id='10000000-0000-4000-8000-000000000051';" >/dev/null
pass "完了後に別の人が確認すれば入る"
call_as admin-token-000000000000000000000000000000002 \
  "INSERT INTO app.corrective_actions(tenant_id,id,finding_id,root_cause,action,owner_user_id,completed_at) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000052','10000000-0000-4000-8000-000000000041','原因','処置2','$MANAGER',now());" >/dev/null
expect_fail_because 'corrective_actions_effectiveness_after_completion' call_as admin-token-000000000000000000000000000000002 \
  "UPDATE app.corrective_actions SET effectiveness_reviewed_by='$ADMIN', effectiveness_reviewed_at=now() - interval '1 day', effectiveness_result='effective' WHERE id='10000000-0000-4000-8000-000000000052';"
pass "完了より前の日時で有効性を確認したことにはできない"

echo '== 統制の有効性評価'
expect_fail_because 'control_effectiveness_criteria_check' call_as admin-token-000000000000000000000000000000002 \
  "INSERT INTO app.control_effectiveness(tenant_id,measure_id,criteria,evaluated_on,evaluator_user_id,result) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000031','  ',current_date,'$ADMIN','effective');"
pass "判定基準の無い評価は入らない"
expect_fail_because 'control_effectiveness_criteria_check' call_as admin-token-000000000000000000000000000000002 \
  "INSERT INTO app.control_effectiveness(tenant_id,measure_id,criteria,evaluated_on,evaluator_user_id,result) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000031',E'\t\n',current_date,'$ADMIN','effective');"
pass "タブや改行だけの判定基準も入らない"
expect_fail_because 'row-level security' call_as manager-token-0000000000000000000000000000003 \
  "INSERT INTO app.control_effectiveness(tenant_id,measure_id,criteria,evaluated_on,evaluator_user_id,result) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000031','基準',current_date,'$MANAGER','effective');"
pass "マネージャーは関数を通さずに有効性評価を直接書いても、表の側で拒否される（0067）"
call_as admin-token-000000000000000000000000000000002 \
  "INSERT INTO app.control_effectiveness(tenant_id,measure_id,criteria,evaluated_on,evaluator_user_id,result) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000031','アクセス権棚卸で不要権限0件',current_date,'$ADMIN','effective');" >/dev/null
# call_as は set_tenant_context の結果行も出すので、件数は最後の 1 行で見る。
[ "$(call_as other-token-00000000000000000000000000000006 "SELECT count(*) FROM app.control_effectiveness;" | tail -n1)" = 0 ] || die "tenant leak"
[ "$(call_as admin-token-000000000000000000000000000000002 "SELECT count(*) FROM app.control_effectiveness;" | tail -n1)" = 1 ] || die "own tenant cannot read"
pass "他テナントからは見えない"

echo '== マネジメントレビューの承認'
call_as admin-token-000000000000000000000000000000002 \
  "INSERT INTO app.management_reviews(tenant_id,id,fiscal_year,held_on,chaired_by,minutes_md) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000061',2026,current_date + 3,'$CISO','議事');" >/dev/null
expect_fail_because 'executive role required' call_as admin-token-000000000000000000000000000000002 "SELECT app.approve_management_review('10000000-0000-4000-8000-000000000061');"
pass "経営層でなければ承認できない"
expect_fail_because 'has not been held' call_as ciso-token-0000000000000000000000000000000001 "SELECT app.approve_management_review('10000000-0000-4000-8000-000000000061');"
pass "先の日付のレビューは承認できない（予定を実施として扱わない）"
call_as admin-token-000000000000000000000000000000002 "UPDATE app.management_reviews SET held_on=current_date - 1, minutes_md='' WHERE id='10000000-0000-4000-8000-000000000061';" >/dev/null
expect_fail_because 'minutes are empty' call_as ciso-token-0000000000000000000000000000000001 "SELECT app.approve_management_review('10000000-0000-4000-8000-000000000061');"
pass "議事が空なら承認できない"
call_as admin-token-000000000000000000000000000000002 "UPDATE app.management_reviews SET minutes_md='入力・決定事項' WHERE id='10000000-0000-4000-8000-000000000061';" >/dev/null
call_as ciso-token-0000000000000000000000000000000001 "SELECT app.approve_management_review('10000000-0000-4000-8000-000000000061','ok');" >/dev/null
pass "経営層は開催済みの議事を承認できる"
expect_fail_because 'already approved' call_as ciso-token-0000000000000000000000000000000001 "SELECT app.approve_management_review('10000000-0000-4000-8000-000000000061');"
pass "同じ議事は二重に承認できない"
call_as admin-token-000000000000000000000000000000002 "UPDATE app.management_reviews SET minutes_md='入力・決定事項（改訂）' WHERE id='10000000-0000-4000-8000-000000000061';" >/dev/null
call_as ciso-token-0000000000000000000000000000000001 "SELECT app.approve_management_review('10000000-0000-4000-8000-000000000061');" >/dev/null
[ "$(sql -At -c "SELECT count(*) FROM app.approvals WHERE target_type='management_review'")" = 2 ] || die "approval count"
pass "議事を直せば改めて承認できる（前の承認記録も残る）"
expect_fail_because 'management review not found' call_as other-token-00000000000000000000000000000006 "SELECT app.approve_management_review('10000000-0000-4000-8000-000000000061');"
pass "他テナントのレビューは承認の対象にならない"

echo '== 第 2 段の役割（0064）'
expect_fail_because 'records role required' call_as admin-token-000000000000000000000000000000002 "SELECT app.require_records_role('exception');"
pass "例外の承認は管理者にもできない（経営層だけ）"
call_as ciso-token-0000000000000000000000000000000001 "SELECT app.require_records_role('exception');" >/dev/null && pass "経営層は例外を承認できる"
expect_fail_because 'records role required' call_as manager-token-0000000000000000000000000000003 "SELECT app.require_records_role('objective');"
pass "マネージャーは目的を登録・評価しない"
call_as admin-token-000000000000000000000000000000002 "SELECT app.require_records_role('objective');" >/dev/null && pass "管理者は目的を登録・評価できる"
expect_fail_because 'records role required' call_as auditor-token-0000000000000000000000000000005 "SELECT app.require_records_role('evidence');"
pass "監査人は証跡（運用の記録）を書けない"
call_as manager-token-0000000000000000000000000000003 "SELECT app.require_records_role('evidence');" >/dev/null && pass "マネージャーは証跡を書ける"
call_as auditor-token-0000000000000000000000000000005 "SELECT app.require_records_role('audit');" >/dev/null && pass "0064 の後も監査人は監査を書ける（差し替えで壊していない）"

echo '== up/down/up'
# 0063 より後（0064 以降）を戻すと第 2 段の種類だけが消え、0063 の種類は残る。
# 後から migration が増えても 0063 の直後まで戻せるよう、戻す本数は数えて決める。
AFTER_0063=$(ls "$ROOT/db/migrations" | grep -E '^[0-9]+_.*\.up\.sql$' | sed -E 's/^([0-9]+)_.*/\1/' | awk '$1 + 0 > 63' | wc -l | tr -d ' ')
"$ROOT/scripts/migrate.sh" down "$AFTER_0063" >/dev/null
expect_fail_because 'unknown record kind' call_as ciso-token-0000000000000000000000000000000001 "SELECT app.require_records_role('exception');"
call_as auditor-token-0000000000000000000000000000005 "SELECT app.require_records_role('audit');" >/dev/null
pass "0064 の down で第 2 段の種類だけが消える"
expect_fail_because '0063 rollback refused' "$ROOT/scripts/migrate.sh" down 1
[ "$(sql -At -c "SELECT to_regclass('app.control_effectiveness') IS NOT NULL")" = t ] || die "refused down dropped the table"
pass "有効性評価の記録があるうちは 0063 を巻き戻さない"
sql -c "DELETE FROM app.control_effectiveness" >/dev/null
"$ROOT/scripts/migrate.sh" down 1 >/dev/null
[ "$(sql -At -c "SELECT to_regclass('app.control_effectiveness') IS NULL")" = t ] || die "down left table"
# 名前は完全一致で数える（前方一致だと既存の corrective_actions_effectiveness_result_check まで拾う）。
[ "$(sql -At -c "SELECT count(*) FROM pg_constraint WHERE conname IN ('corrective_actions_effectiveness_complete','corrective_actions_effectiveness_after_completion','corrective_actions_reviewer_not_owner')")" = 0 ] || die "down left constraints"
[ "$(sql -At -c "SELECT count(*) FROM pg_constraint WHERE conname = 'corrective_actions_effectiveness_result_check'")" = 1 ] || die "down removed a pre-existing constraint"
"$ROOT/scripts/migrate.sh" up >/dev/null
[ "$(sql -At -c "SELECT to_regclass('app.control_effectiveness') IS NOT NULL")" = t ] || die "re-up failed"
pass "0063 は down で消え、up で戻る"

echo 'isms records: 全て緑'
