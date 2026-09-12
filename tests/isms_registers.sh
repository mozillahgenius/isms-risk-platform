#!/usr/bin/env bash
# Acceptance for 0065 onward: roles, invariants, tenant isolation and rollback for the previously missing ISMS registers (design doc 2026-09-11 §4).
# Run against a throwaway DB.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${ISMS_TEST_DB:-isms_registers_$$}"
die() { printf '[isms registers] %s\n' "$*" >&2; exit 1; }
pass() { printf '  PASS %s\n' "$*"; }
# Check not only that it failed but that "it failed for the intended reason" (prevents false passes that fail for some other reason).
expect_fail_because() {
  local want="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then die "unexpected success: $*"; fi
  case "$out" in *"$want"*) ;; *) die "failed for the wrong reason (want '$want'): $out" ;; esac
}
sql() { psql -w -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

[ "$DB" != "isms_dev" ] || die "refuse shared db"
# Every psql uses -w (never prompt for a password). If credentials are missing, fail immediately instead of hanging
# (in an unattended deployment psql waited for a password and the acceptance test hung for 30 minutes; 2026-09-13).
# In deployment, this DB's credentials are written to PGPASSFILE by scripts/configure_db_roles.py (fixture_databases).
CREATED_DB=0
# Always drop the DB we created. If it cannot be dropped, fail the test (do not overlook leftover DBs; same as run_isolated.sh).
cleanup() {
  local rc=$?
  if [ "$CREATED_DB" = 1 ] && ! dropdb -w --if-exists "$DB" >/dev/null 2>&1; then
    printf '[isms registers] 使い捨て DB %s を消せませんでした\n' "$DB" >&2
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
AUDITOR=10000000-0000-4000-8000-000000000015
MEMBER=10000000-0000-4000-8000-000000000014
OTHER=20000000-0000-4000-8000-000000000011

sql <<SQL
INSERT INTO app.tenants(id,name,domain,dom_version_id) SELECT '$T1','one','one.test',id FROM catalog.dom_versions LIMIT 1;
INSERT INTO app.tenants(id,name,domain,dom_version_id) SELECT '$T2','two','two.test',id FROM catalog.dom_versions LIMIT 1;
INSERT INTO app.users(tenant_id,id,email,display_name) VALUES
 ('$T1','$CISO','ciso@one.test','ciso'), ('$T1','$ADMIN','admin@one.test','admin'),
 ('$T1','$MANAGER','manager@one.test','manager'), ('$T1','$AUDITOR','auditor@one.test','auditor'),
 ('$T1','$MEMBER','member@one.test','member'),
 ('$T2','$OTHER','other@two.test','other');
INSERT INTO app.memberships(tenant_id,user_id,role_key) VALUES
 ('$T1','$CISO','ciso'), ('$T1','$ADMIN','secretariat'), ('$T1','$MANAGER','risk_owner'),
 ('$T1','$AUDITOR','auditor'), ('$T1','$MEMBER','employee'), ('$T2','$OTHER','secretariat'),
 -- Another tenant's executive. Confirms that even with decision rights, another tenant's request is not found.
 ('$T2','$OTHER','ciso');
SQL

token_for() { sql -c "SET ROLE auth_svc; SELECT app.create_session('$1','$2','$3',interval '1 hour'); RESET ROLE" >/dev/null; }
token_for $T1 $CISO    ciso-token-0000000000000000000000000000000001
token_for $T1 $ADMIN   admin-token-000000000000000000000000000000002
token_for $T1 $MANAGER manager-token-0000000000000000000000000000003
token_for $T1 $AUDITOR auditor-token-0000000000000000000000000000005
token_for $T1 $MEMBER  member-token-00000000000000000000000000000004
token_for $T2 $OTHER   other-token-00000000000000000000000000000006
call_as() { PGPASSWORD='' psql -w -Atq -v ON_ERROR_STOP=1 -U app_rw -d "$DB" -c "BEGIN; SELECT app.set_tenant_context('$1'); $2 COMMIT;"; }
ADMIN_T=admin-token-000000000000000000000000000000002

echo '== 組織の課題・利害関係者（0065）の役割'
call_as $ADMIN_T "SELECT app.require_records_role('context');" >/dev/null && pass "管理者は課題・利害関係者を書ける"
call_as ciso-token-0000000000000000000000000000000001 "SELECT app.require_records_role('context');" >/dev/null && pass "経営層も書ける"
expect_fail_because 'records role required' call_as manager-token-0000000000000000000000000000003 "SELECT app.require_records_role('context');"
pass "マネージャーは書けない（組織の状況の決定は管理者以上）"
expect_fail_because 'records role required' call_as auditor-token-0000000000000000000000000000005 "SELECT app.require_records_role('context');"
pass "監査人は書けない"
call_as auditor-token-0000000000000000000000000000005 "SELECT app.require_records_role('audit');" >/dev/null && pass "0065 の後も監査人は監査を書ける（差し替えで壊していない）"

echo '== 組織の課題（4.1）の不変条件'
expect_fail_because 'context_issues_isms_impact_check' call_as $ADMIN_T \
  "INSERT INTO app.context_issues(tenant_id,kind,title,isms_impact) VALUES(app.current_tenant(),'external','法改正',E' \t\n');"
pass "ISMS にどう効くかが空白だけの課題は入らない"
expect_fail_because 'context_issues_kind_check' call_as $ADMIN_T \
  "INSERT INTO app.context_issues(tenant_id,kind,title,isms_impact) VALUES(app.current_tenant(),'other','法改正','範囲の見直しが要る');"
pass "外部・内部以外の種類は入らない"
call_as $ADMIN_T \
  "INSERT INTO app.context_issues(tenant_id,kind,title,isms_impact) VALUES(app.current_tenant(),'external','法改正','範囲の見直しが要る');" >/dev/null
pass "外部の課題を登録できる"
expect_fail_because 'context_issues_tenant_id_kind_title_key' call_as $ADMIN_T \
  "INSERT INTO app.context_issues(tenant_id,kind,title,isms_impact) VALUES(app.current_tenant(),'external','法改正','別の書き方');"
pass "同じ種類・同じ名前の課題は重ならない"
call_as $ADMIN_T \
  "INSERT INTO app.context_issues(tenant_id,kind,title,isms_impact) VALUES(app.current_tenant(),'internal','法改正','内部の手順が追いつかない');" >/dev/null
pass "同じ名前でも外部と内部は別の課題として登録できる"

echo '== 利害関係者（4.2）の不変条件'
expect_fail_because 'interested_parties_requirements_check' call_as $ADMIN_T \
  "INSERT INTO app.interested_parties(tenant_id,name,category,requirements) VALUES(app.current_tenant(),'主要顧客','customer',E'\t');"
pass "要求が空白だけの利害関係者は入らない"
expect_fail_because 'interested_parties_category_check' call_as $ADMIN_T \
  "INSERT INTO app.interested_parties(tenant_id,name,category,requirements) VALUES(app.current_tenant(),'主要顧客','friend','秘密保持');"
pass "決めた分類以外は入らない"
call_as $ADMIN_T \
  "INSERT INTO app.interested_parties(tenant_id,name,category,requirements,addressed_in_isms) VALUES(app.current_tenant(),'主要顧客','customer','秘密保持と事故時の報告','秘密保持は ISMS で扱う');" >/dev/null
pass "利害関係者を登録できる"
expect_fail_because 'interested_parties_tenant_id_name_key' call_as $ADMIN_T \
  "INSERT INTO app.interested_parties(tenant_id,name,category,requirements) VALUES(app.current_tenant(),'主要顧客','partner','別の要求');"
pass "同じ名前の利害関係者は重ならない"
expect_fail_because 'interested_parties_tenant_id_owner_user_id_fkey' call_as $ADMIN_T \
  "INSERT INTO app.interested_parties(tenant_id,name,category,requirements,owner_user_id) VALUES(app.current_tenant(),'株主','shareholder','情報開示','$OTHER');"
pass "担当に他テナントの利用者は付けられない"

echo '== テナント分離'
# call_as also prints set_tenant_context's result row, so read the count from the last line.
[ "$(call_as other-token-00000000000000000000000000000006 "SELECT count(*) FROM app.context_issues;" | tail -n1)" = 0 ] || die "tenant leak (issues)"
[ "$(call_as other-token-00000000000000000000000000000006 "SELECT count(*) FROM app.interested_parties;" | tail -n1)" = 0 ] || die "tenant leak (parties)"
[ "$(call_as $ADMIN_T "SELECT count(*) FROM app.context_issues;" | tail -n1)" = 2 ] || die "own tenant cannot read"
pass "他テナントからは見えない"
expect_fail_because 'row-level security' call_as other-token-00000000000000000000000000000006 \
  "INSERT INTO app.context_issues(tenant_id,kind,title,isms_impact) VALUES('$T1','external','越境','越境');"
pass "他テナントの行としては書けない"

echo '== 法令・契約上の要求（0066）'
call_as manager-token-0000000000000000000000000000003 "SELECT app.require_records_role('legal');" >/dev/null && pass "マネージャーは要求事項を書ける"
expect_fail_because 'records role required' call_as auditor-token-0000000000000000000000000000005 "SELECT app.require_records_role('legal');"
pass "監査人は要求事項を書けない"
expect_fail_because 'legal_requirements_requirement_check' call_as $ADMIN_T \
  "INSERT INTO app.legal_requirements(tenant_id,kind,title,requirement) VALUES(app.current_tenant(),'law','個人情報保護法',E' \n');"
pass "何を求めているかが空白だけの要求事項は入らない"
expect_fail_because 'legal_requirements_assessment_complete' call_as $ADMIN_T \
  "INSERT INTO app.legal_requirements(tenant_id,kind,title,requirement,compliance_status) VALUES(app.current_tenant(),'law','個人情報保護法','安全管理措置','compliant');"
pass "評価日・評価者なしに「適合」とは書けない"
expect_fail_because 'legal_requirements_review_after_assessment' call_as $ADMIN_T \
  "INSERT INTO app.legal_requirements(tenant_id,kind,title,requirement,compliance_status,assessed_on,assessed_by,next_review_on) VALUES(app.current_tenant(),'law','個人情報保護法','安全管理措置','compliant',current_date,'$ADMIN',current_date);"
pass "次の見直し日は評価日より後"
expect_fail_because 'legal_requirements_tenant_id_measure_id_fkey' call_as $ADMIN_T \
  "INSERT INTO app.legal_requirements(tenant_id,kind,title,requirement,measure_id) VALUES(app.current_tenant(),'contract','主要顧客との契約','秘密保持','10000000-0000-4000-8000-0000000000ff');"
pass "存在しない統制には結べない"
call_as $ADMIN_T \
  "INSERT INTO app.legal_requirements(tenant_id,kind,title,requirement,compliance_status,assessed_on,assessed_by,next_review_on) VALUES(app.current_tenant(),'law','個人情報保護法','安全管理措置','compliant',current_date,'$ADMIN',current_date + 365);" >/dev/null
pass "評価つきの要求事項を登録できる"
[ "$(call_as other-token-00000000000000000000000000000006 "SELECT count(*) FROM app.legal_requirements;" | tail -n1)" = 0 ] || die "tenant leak (legal)"
pass "要求事項は他テナントから見えない"

echo '== 表の側でも役割で拒否する（0067）'
MANAGER_T=manager-token-0000000000000000000000000000003
AUDITOR_T=auditor-token-0000000000000000000000000000005
expect_fail_because 'row-level security' call_as $MANAGER_T \
  "INSERT INTO app.context_issues(tenant_id,kind,title,isms_impact) VALUES(app.current_tenant(),'external','越権','越権');"
pass "マネージャーは関数を通さずに課題を直接書いても拒否される"
expect_fail_because 'row-level security' call_as $AUDITOR_T \
  "INSERT INTO app.legal_requirements(tenant_id,kind,title,requirement) VALUES(app.current_tenant(),'law','越権','越権');"
pass "監査人は要求事項を直接書いても拒否される"
[ "$(call_as $MANAGER_T "WITH u AS (UPDATE app.context_issues SET title = title || 'x' RETURNING 1) SELECT count(*) FROM u;" | tail -n1)" = 0 ] || die "manager updated context"
# First confirm there is something to delete (with no rows, it would pass with 0 even without a policy).
PARTIES_BEFORE="$(sql -At -c "SELECT count(*) FROM app.interested_parties")"
[ "$PARTIES_BEFORE" -ge 1 ] || die "no party to delete (vacuous test)"
[ "$(call_as $MANAGER_T "WITH d AS (DELETE FROM app.interested_parties RETURNING 1) SELECT count(*) FROM d;" | tail -n1)" = 0 ] || die "manager deleted party"
[ "$(sql -At -c "SELECT count(*) FROM app.interested_parties")" = "$PARTIES_BEFORE" ] || die "party count changed"
[ "$(sql -At -c "SELECT count(*) FROM app.context_issues WHERE title LIKE '%x'")" = 0 ] || die "manager update leaked"
pass "マネージャーの更新・削除は対象が 0 件になる（表の側で書けない）"
[ "$(call_as $AUDITOR_T "SELECT count(*) FROM app.context_issues;" | tail -n1)" = 2 ] || die "auditor cannot read"
pass "読み取りは役割で絞らない（監査人も読める）"
call_as $MANAGER_T \
  "INSERT INTO app.legal_requirements(tenant_id,kind,title,requirement) VALUES(app.current_tenant(),'contract','主要顧客との契約','秘密保持');" >/dev/null
pass "マネージャーは要求事項なら直接書ける（許可の表どおり）"
[ "$(sql -At -c "SELECT count(*) FROM pg_policies WHERE schemaname='app' AND policyname IN ('records_role_insert','records_role_update','records_role_delete')")" = 33 ] || die "policy count"
pass "役割ポリシーは 11 表 × 3 枚（0068〜0070 の表・0071 の取り込みの記録 3 表を含む）"

echo '== 事業継続の計画と試験（0068）'
PLAN=10000000-0000-4000-8000-000000000071
call_as $MANAGER_T "SELECT app.require_records_role('continuity');" >/dev/null && pass "マネージャーは事業継続を書ける"
expect_fail_because 'records role required' call_as $AUDITOR_T "SELECT app.require_records_role('continuity');"
pass "監査人は事業継続を書けない"
expect_fail_because 'continuity_plans_scope_check' call_as $ADMIN_T \
  "INSERT INTO app.continuity_plans(tenant_id,title,scope,procedure_location) VALUES(app.current_tenant(),'基幹業務の継続',E'\t','共有ドライブ／BCP');"
pass "何を守るかが空白だけの計画は入らない"
expect_fail_because 'continuity_plans_procedure_location_check' call_as $ADMIN_T \
  "INSERT INTO app.continuity_plans(tenant_id,title,scope,procedure_location) VALUES(app.current_tenant(),'基幹業務の継続','受注と出荷',' ');"
pass "計画の所在が空白だけの計画は入らない"
expect_fail_because 'continuity_plans_rto_hours_check' call_as $ADMIN_T \
  "INSERT INTO app.continuity_plans(tenant_id,title,scope,procedure_location,rto_hours) VALUES(app.current_tenant(),'基幹業務の継続','受注と出荷','共有ドライブ／BCP',0);"
pass "目標復旧時間は 1 時間以上"
call_as $ADMIN_T \
  "INSERT INTO app.continuity_plans(tenant_id,id,title,scope,procedure_location,rto_hours,rpo_hours) VALUES(app.current_tenant(),'$PLAN','基幹業務の継続','受注と出荷','共有ドライブ／BCP',24,4);" >/dev/null
pass "計画を登録できる"
expect_fail_because 'continuity_tests_result_check' call_as $MANAGER_T \
  "INSERT INTO app.continuity_tests(tenant_id,plan_id,tested_on,method,result,performed_by) VALUES(app.current_tenant(),'$PLAN',current_date,'tabletop','ok','$MANAGER');"
pass "決めた結果以外は入らない"
expect_fail_because 'continuity_tests_tenant_id_performed_by_fkey' call_as $MANAGER_T \
  "INSERT INTO app.continuity_tests(tenant_id,plan_id,tested_on,method,result,performed_by) VALUES(app.current_tenant(),'$PLAN',current_date,'tabletop','passed','$OTHER');"
pass "実施者に他テナントの利用者は付けられない"
expect_fail_because 'row-level security' call_as $AUDITOR_T \
  "INSERT INTO app.continuity_tests(tenant_id,plan_id,tested_on,method,result,performed_by) VALUES(app.current_tenant(),'$PLAN',current_date,'tabletop','passed','$AUDITOR');"
pass "監査人は試験の記録を直接書いても拒否される"
call_as $MANAGER_T \
  "INSERT INTO app.continuity_tests(tenant_id,plan_id,tested_on,method,result,rto_met,performed_by) VALUES(app.current_tenant(),'$PLAN',current_date - 1,'tabletop','partially_passed',true,'$MANAGER');" >/dev/null
pass "マネージャーは試験を記録できる"
[ "$(call_as other-token-00000000000000000000000000000006 "SELECT count(*) FROM app.continuity_plans;" | tail -n1)" = 0 ] || die "tenant leak (continuity)"
pass "事業継続は他テナントから見えない"

echo '== 脆弱性（0069）'
VULN=10000000-0000-4000-8000-000000000081
call_as $MANAGER_T "SELECT app.require_records_role('vulnerability');" >/dev/null && pass "マネージャーは脆弱性を書ける"
expect_fail_because 'records role required' call_as $AUDITOR_T "SELECT app.require_records_role('vulnerability');"
pass "監査人は脆弱性を書けない"
expect_fail_because 'vulnerabilities_due_after_detected' call_as $MANAGER_T \
  "INSERT INTO app.vulnerabilities(tenant_id,title,identifier,source,severity,detected_on,due_date) VALUES(app.current_tenant(),'OpenSSL の脆弱性','CVE-2026-0001','advisory','high',current_date,current_date - 1);"
pass "対応期限は検知日より前にできない"
expect_fail_because 'vulnerabilities_resolved_iff_closed' call_as $MANAGER_T \
  "INSERT INTO app.vulnerabilities(tenant_id,title,identifier,source,severity,detected_on,status) VALUES(app.current_tenant(),'OpenSSL の脆弱性','CVE-2026-0001','advisory','high',current_date,'mitigated');"
pass "閉じた日なしに「対処済み」とは書けない"
expect_fail_because 'vulnerabilities_resolved_iff_closed' call_as $MANAGER_T \
  "INSERT INTO app.vulnerabilities(tenant_id,title,identifier,source,severity,detected_on,resolved_on) VALUES(app.current_tenant(),'OpenSSL の脆弱性','CVE-2026-0001','advisory','high',current_date,current_date);"
pass "開いているのに閉じた日は入らない"
expect_fail_because 'vulnerabilities_false_positive_reason' call_as $MANAGER_T \
  "INSERT INTO app.vulnerabilities(tenant_id,title,identifier,source,severity,detected_on,status,resolved_on) VALUES(app.current_tenant(),'誤検知','CVE-2026-0009','scan','low',current_date,'false_positive',current_date);"
pass "誤検知は理由なしに閉じられない"
expect_fail_because 'vulnerabilities_tenant_id_asset_id_fkey' call_as $MANAGER_T \
  "INSERT INTO app.vulnerabilities(tenant_id,title,identifier,source,severity,detected_on,asset_id) VALUES(app.current_tenant(),'OpenSSL の脆弱性','CVE-2026-0001','advisory','high',current_date,'10000000-0000-4000-8000-0000000000ff');"
pass "存在しない資産には結べない"
call_as $MANAGER_T \
  "INSERT INTO app.vulnerabilities(tenant_id,id,title,identifier,source,severity,detected_on,due_date) VALUES(app.current_tenant(),'$VULN','OpenSSL の脆弱性','CVE-2026-0001','advisory','high',current_date - 2,current_date + 14);" >/dev/null
pass "脆弱性を登録できる"
expect_fail_because 'vulnerabilities_open_identifier' call_as $MANAGER_T \
  "INSERT INTO app.vulnerabilities(tenant_id,title,identifier,source,severity,detected_on) VALUES(app.current_tenant(),'同じもの','CVE-2026-0001','scan','high',current_date);"
pass "同じ識別子・同じ資産の、開いている記録は 1 つだけ"
call_as $MANAGER_T "UPDATE app.vulnerabilities SET status='mitigated', resolved_on=current_date, resolution_note='更新を適用' WHERE id='$VULN';" >/dev/null
call_as $MANAGER_T \
  "INSERT INTO app.vulnerabilities(tenant_id,title,identifier,source,severity,detected_on) VALUES(app.current_tenant(),'再発','CVE-2026-0001','scan','high',current_date);" >/dev/null
pass "閉じた後の再発は新しい記録として入る"
expect_fail_because 'row-level security' call_as $AUDITOR_T \
  "INSERT INTO app.vulnerabilities(tenant_id,title,source,severity,detected_on) VALUES(app.current_tenant(),'越権','other','low',current_date);"
pass "監査人は脆弱性を直接書いても拒否される"
[ "$(call_as other-token-00000000000000000000000000000006 "SELECT count(*) FROM app.vulnerabilities;" | tail -n1)" = 0 ] || die "tenant leak (vulnerabilities)"
pass "脆弱性は他テナントから見えない"

echo '== 変更の申請と承認（0070）'
MEMBER_T=member-token-00000000000000000000000000000004
CISO_T=ciso-token-0000000000000000000000000000000001
CR=10000000-0000-4000-8000-000000000091
CR2=10000000-0000-4000-8000-000000000092
call_as $MEMBER_T "SELECT app.require_records_role('change');" >/dev/null && pass "メンバーは変更を申請できる役割"
expect_fail_because 'records role required' call_as $AUDITOR_T "SELECT app.require_records_role('change');"
pass "監査人は変更を申請できない"
expect_fail_because 'change request must start as requested' call_as $MEMBER_T \
  "INSERT INTO app.change_requests(tenant_id,title,description,impact,risk_level,requested_by,status) VALUES(app.current_tenant(),'x','x','x','low','$MEMBER','approved');"
pass "申請を最初から承認済みにはできない"
expect_fail_because 'change_requests_impact_check' call_as $MEMBER_T \
  "INSERT INTO app.change_requests(tenant_id,title,description,impact,risk_level,requested_by) VALUES(app.current_tenant(),'x','x',E' \t','low','$MEMBER');"
pass "影響が空白だけの申請は入らない"
call_as $MEMBER_T \
  "INSERT INTO app.change_requests(tenant_id,id,title,description,impact,risk_level,requested_by) VALUES(app.current_tenant(),'$CR','ファイアウォール規則の変更','外向き 443 を許可','業務アプリの通信が通る','medium','$MEMBER');" >/dev/null
pass "メンバーが変更を申請できる"
expect_fail_because 'requester must be the session user' call_as $MANAGER_T \
  "INSERT INTO app.change_requests(tenant_id,title,description,impact,risk_level,requested_by) VALUES(app.current_tenant(),'なりすまし','内容','影響','low','$ADMIN');"
pass "申請者を他人の名義にして申請できない（他人名義の申請を自分で承認する迂回を防ぐ）"
expect_fail_because 'decision can only be recorded by the approval function' call_as $MANAGER_T \
  "UPDATE app.change_requests SET status='approved', decided_by='$CISO', decided_at=now() WHERE id='$CR';"
pass "表を直接書いて承認済みにはできない（判断の欄は承認の関数だけが書く）"
expect_fail_because 'illegal change request transition' call_as $MANAGER_T \
  "UPDATE app.change_requests SET status='implemented', implemented_by='$MANAGER', implemented_at=now() WHERE id='$CR';"
pass "承認の前に実施にはできない"
expect_fail_because 'executive role required' call_as $ADMIN_T "SELECT app.decide_change_request('$CR', true);"
pass "経営層でなければ判断できない"
call_as $CISO_T \
  "INSERT INTO app.change_requests(tenant_id,id,title,description,impact,risk_level,requested_by) VALUES(app.current_tenant(),'$CR2','経営層の申請','内容','影響','low','$CISO');" >/dev/null
expect_fail_because 'requester cannot decide their own change request' call_as $CISO_T "SELECT app.decide_change_request('$CR2', true);"
pass "申請者は自分の申請を判断できない（経営層でも）"
expect_fail_because 'rejection reason required' call_as $CISO_T "SELECT app.decide_change_request('$CR', false);"
pass "却下には理由が要る"
call_as $CISO_T "SELECT app.decide_change_request('$CR', true, '業務上必要');" >/dev/null
# Verify the hash by content, not length (a JSON array of title, description, impact, risk, rollback plan, asset).
[ "$(sql -At -c "SELECT count(*) FROM app.approvals ap JOIN app.change_requests c ON c.tenant_id=ap.tenant_id AND c.id=ap.target_id WHERE ap.target_type='change_request' AND ap.target_id='$CR' AND ap.approver_user_id='$CISO' AND ap.target_version_hash = public.digest(convert_to(jsonb_build_array(c.title,c.description,c.impact,c.risk_level,c.rollback_plan,coalesce(c.asset_id::text,''))::text,'UTF8'),'sha256')")" = 1 ] || die "approval record"
# A boolean concatenated to a string becomes 'true' / 'false' (not psql's display 't').
[ "$(sql -At -c "SELECT status || ' ' || (decided_by = '$CISO') FROM app.change_requests WHERE id='$CR'")" = "approved true" ] || die "approved state"
pass "経営層が承認でき、承認した中身のハッシュが承認の記録に残る"
expect_fail_because 'not awaiting a decision' call_as $CISO_T "SELECT app.decide_change_request('$CR', true);"
pass "同じ申請は二度判断できない"
expect_fail_because 'content can only be edited while requested' call_as $MEMBER_T \
  "UPDATE app.change_requests SET description='別の変更' WHERE id='$CR';"
pass "承認した後は中身を直せない（承認した中身とずれない）"
call_as $MANAGER_T "UPDATE app.change_requests SET planned_on=current_date + 3 WHERE id='$CR';" >/dev/null
pass "予定日は承認の後も直せる（中身ではない）"
expect_fail_because 'change request id cannot be changed' call_as $MANAGER_T \
  "UPDATE app.change_requests SET id=gen_random_uuid() WHERE id='$CR';"
pass "申請の ID は変えられない（承認の記録との結び付きを保つ）"
expect_fail_because 'implementer must be the session user' call_as $MANAGER_T \
  "UPDATE app.change_requests SET status='implemented', implemented_by='$CISO', implemented_at=now() WHERE id='$CR';"
pass "実施者を他人の名義にして記録できない"
call_as $MANAGER_T \
  "UPDATE app.change_requests SET status='implemented', implemented_by='$MANAGER', implemented_at=now(), result_note='適用した' WHERE id='$CR';" >/dev/null
pass "承認の後は実施を記録できる"
expect_fail_because 'illegal change request transition' call_as $MANAGER_T \
  "UPDATE app.change_requests SET status='cancelled' WHERE id='$CR';"
pass "実施した申請は取りやめにできない（終わった状態は戻さない）"
expect_fail_because 'permission denied' call_as $ADMIN_T "DELETE FROM app.change_requests WHERE id='$CR';"
pass "申請は消せない（取りやめる）"
expect_fail_because 'change request not found' call_as other-token-00000000000000000000000000000006 \
  "SELECT app.decide_change_request('$CR2', true, 'x');"
pass "他テナントの申請は判断の対象にならない（他テナントの経営層でも）"
expect_fail_because 'row-level security' call_as $AUDITOR_T \
  "INSERT INTO app.change_requests(tenant_id,title,description,impact,risk_level,requested_by) VALUES(app.current_tenant(),'越権','越権','越権','low','$AUDITOR');"
pass "監査人は申請を直接書いても拒否される"

echo '== 取り込みの記録（0071）'
B1=10000000-0000-4000-8000-0000000000a1
B2=10000000-0000-4000-8000-0000000000a2
SHA="decode(repeat('ab', 32), 'hex')"
call_as $ADMIN_T "SELECT app.require_records_role('import');" >/dev/null && pass "管理者は取り込める"
expect_fail_because 'records role required' call_as $MANAGER_T "SELECT app.require_records_role('import');"
pass "マネージャーは取り込めない（台帳の一括作成は管理者以上）"
# One import: create the record, asset and items in the same transaction. The record's actor is filled with the actual user, not the written value.
call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by,imported_at)
  VALUES(app.current_tenant(),'$B1','assets',$SHA,1,1,'$CISO',now() - interval '1 day');
INSERT INTO app.assets(tenant_id,asset_key,name,asset_type,classification) VALUES(app.current_tenant(),'IMP-1','取り込んだ資産','情報','internal');
-- Active assets need a risk-management framework (the DB checks at commit). Imports attach it via the same path.
SELECT app.set_management_frameworks_human('asset', id, ARRAY['RISK-MANAGEMENT']) FROM app.assets WHERE asset_key='IMP-1';
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id)
  SELECT app.current_tenant(), '$B1', 1, 'asset', id FROM app.assets WHERE asset_key='IMP-1';" >/dev/null
[ "$(sql -At -c "SELECT imported_by = '$ADMIN' AND imported_at > now() - interval '1 hour' FROM app.import_batches WHERE id='$B1'")" = t ] || die "batch stamp"
pass "取り込みの記録の「誰がいつ」は本人と今で埋まる（他人の名義・過去の日時にできない）"
[ "$(sql -At -c "SELECT count(*) FROM app.import_batch_items WHERE batch_id='$B1'")" = 1 ] || die "batch item"
pass "同じトランザクションで作った行を明細に付けられる"
expect_fail_because 'batch created in this transaction' call_as $ADMIN_T \
  "INSERT INTO app.assets(tenant_id,asset_key,name,asset_type,classification) VALUES(app.current_tenant(),'IMP-2','後から','情報','internal');
   INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id) SELECT app.current_tenant(), '$B1', 2, 'asset', id FROM app.assets WHERE asset_key='IMP-2';"
pass "前の取り込みに後から行を足せない（取り消しで他の行を退役させる迂回を防ぐ）"
call_as $ADMIN_T "INSERT INTO app.assets(tenant_id,asset_key,name,asset_type,classification) VALUES(app.current_tenant(),'OLD-1','前からある資産','情報','internal');
  SELECT app.set_management_frameworks_human('asset', id, ARRAY['RISK-MANAGEMENT']) FROM app.assets WHERE asset_key='OLD-1';" >/dev/null
expect_fail_because 'rows created in this transaction' call_as $ADMIN_T \
  "INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B2','assets',$SHA,1,1,'$ADMIN');
   INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id) SELECT app.current_tenant(), '$B2', 1, 'asset', id FROM app.assets WHERE asset_key='OLD-1';"
pass "前からある行を取り込みの明細に付けられない"
expect_fail_because 'permission denied' call_as $ADMIN_T "UPDATE app.import_batches SET row_count=0 WHERE id='$B1';"
expect_fail_because 'permission denied' call_as $ADMIN_T "DELETE FROM app.import_batch_items WHERE batch_id='$B1';"
pass "取り込みの記録は直せず、消せない（追記だけ）"
expect_fail_because 'row-level security' call_as $MANAGER_T \
  "INSERT INTO app.import_batches(tenant_id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'assets',$SHA,0,0,'$MANAGER');"
pass "マネージャーは取り込みの記録を直接書いても拒否される"
call_as $ADMIN_T "INSERT INTO app.import_undos(tenant_id,batch_id,undone_by,retired_count,skipped_count) VALUES(app.current_tenant(),'$B1','$CISO',1,0);" >/dev/null
[ "$(sql -At -c "SELECT undone_by = '$ADMIN' FROM app.import_undos WHERE batch_id='$B1'")" = t ] || die "undo stamp"
expect_fail_because 'import_undos_pkey' call_as $ADMIN_T \
  "INSERT INTO app.import_undos(tenant_id,batch_id,undone_by,retired_count,skipped_count) VALUES(app.current_tenant(),'$B1','$ADMIN',0,0);"
pass "取り消しは本人の名義で残り、1 回の取り込みに 1 回だけ"
[ "$(call_as other-token-00000000000000000000000000000006 "SELECT count(*) FROM app.import_batches;" | tail -n1)" = 0 ] || die "tenant leak (imports)"
pass "取り込みの記録は他テナントから見えない"

echo '== 取り込みの記録を固める（0072）'
B3=10000000-0000-4000-8000-0000000000a3
B4=10000000-0000-4000-8000-0000000000a4
B5=10000000-0000-4000-8000-0000000000a5
B6=10000000-0000-4000-8000-0000000000a6
TAG="SELECT app.set_management_frameworks_human('asset', id, ARRAY['RISK-MANAGEMENT']) FROM app.assets WHERE asset_key"
CREATED_BEFORE="$(sql -At -c "SELECT created_at FROM app.assets WHERE asset_key='OLD-1'")"
call_as $ADMIN_T "UPDATE app.assets SET created_at = now() + interval '1 day' WHERE asset_key='OLD-1';" >/dev/null
[ "$(sql -At -c "SELECT created_at FROM app.assets WHERE asset_key='OLD-1'")" = "$CREATED_BEFORE" ] || die "created_at changed"
pass "資産の作成日時は更新で変わらない"
expect_fail_because 'rows created in this transaction' call_as $ADMIN_T "
UPDATE app.assets SET created_at = now() WHERE asset_key='OLD-1';
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B3','assets',$SHA,1,1,'$ADMIN');
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id) SELECT app.current_tenant(),'$B3',1,'asset',id FROM app.assets WHERE asset_key='OLD-1';"
pass "作成日時を今に書き換えても、前からある行を取り込みの明細に付けられない"
expect_fail_because 'does not match the batch kind' call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B4','risks',$SHA,1,1,'$ADMIN');
INSERT INTO app.assets(tenant_id,asset_key,name,asset_type,classification) VALUES(app.current_tenant(),'IMP-3','種類違い','情報','internal');
$TAG='IMP-3';
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id) SELECT app.current_tenant(),'$B4',1,'asset',id FROM app.assets WHERE asset_key='IMP-3';"
pass "リスクの取り込みに資産の明細は付けられない（種類と対象の一致）"
expect_fail_because 'outside the batch' call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B5','assets',$SHA,1,1,'$ADMIN');
INSERT INTO app.assets(tenant_id,asset_key,name,asset_type,classification) VALUES(app.current_tenant(),'IMP-4','行番号違い','情報','internal');
$TAG='IMP-4';
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id) SELECT app.current_tenant(),'$B5',5,'asset',id FROM app.assets WHERE asset_key='IMP-4';"
pass "行番号が取り込みの行数を超える明細は付けられない"
expect_fail_because 'do not match the created count' call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B6','assets',$SHA,2,2,'$ADMIN');
INSERT INTO app.assets(tenant_id,asset_key,name,asset_type,classification) VALUES(app.current_tenant(),'IMP-5','件数違い','情報','internal');
$TAG='IMP-5';
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id) SELECT app.current_tenant(),'$B6',1,'asset',id FROM app.assets WHERE asset_key='IMP-5';"
pass "明細の数が作った件数と合わない取り込みはコミットできない"
[ "$(sql -At -c "SELECT retired_count || '/' || skipped_count FROM app.import_undos WHERE batch_id='$B1'")" = "0/1" ] || die "undo counts not computed"
pass "取り消しの件数は DB が数える（書かれた「退役 1 件」ではなく、実際に退役にしていないので 0 件・対象外 1 件）"

echo '== 組織の取り込み（0073）'
B7=10000000-0000-4000-8000-0000000000a7
B8=10000000-0000-4000-8000-0000000000a8
B9=10000000-0000-4000-8000-0000000000a9
DEPT="(SELECT id FROM app.departments WHERE name='取り込み部')"
call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B7','departments',$SHA,1,1,'$ADMIN');
INSERT INTO app.departments(tenant_id,name) VALUES(app.current_tenant(),'取り込み部');
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id) SELECT app.current_tenant(),'$B7',1,'department',$DEPT;" >/dev/null
pass "部署を取り込みの明細付きで作れる"
DEPT_CREATED="$(sql -At -c "SELECT created_at FROM app.departments WHERE name='取り込み部'")"
call_as $ADMIN_T "UPDATE app.departments SET created_at = now() + interval '1 day' WHERE name='取り込み部';" >/dev/null
[ "$(sql -At -c "SELECT created_at FROM app.departments WHERE name='取り込み部'")" = "$DEPT_CREATED" ] || die "department created_at changed"
pass "部署の作成日時は更新で変わらない"
expect_fail_because 'memberships assigned in this transaction' call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B9','assignments',$SHA,1,1,'$ADMIN');
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id,prev_department_id,new_department_id)
  SELECT app.current_tenant(),'$B9',1,'membership',m.id,NULL,$DEPT FROM app.memberships m WHERE m.user_id='$MANAGER' AND m.revoked_at IS NULL;"
pass "このトランザクションで割り当てていない所属は、割り当ての明細に付けられない"
expect_fail_because 'does not match the batch kind' call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B9','assignments',$SHA,1,1,'$ADMIN');
INSERT INTO app.departments(tenant_id,name) VALUES(app.current_tenant(),'種類違いの部');
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id) SELECT app.current_tenant(),'$B9',1,'department',id FROM app.departments WHERE name='種類違いの部';"
pass "割り当ての取り込みに部署の明細は付けられない（種類と対象の一致）"
expect_fail_because 'import_batch_items_membership_values' call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B9','departments',$SHA,1,1,'$ADMIN');
INSERT INTO app.departments(tenant_id,name) VALUES(app.current_tenant(),'値違いの部');
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id,new_department_id) SELECT app.current_tenant(),'$B9',1,'department',id,id FROM app.departments WHERE name='値違いの部';"
pass "部署の明細に割り当ての値は入らない"
# Give the membership a non-null original department (to check that an item's original department matches the department before the actual change; 0075).
PREV="(SELECT id FROM app.departments WHERE name='元の部')"
call_as $ADMIN_T "
INSERT INTO app.departments(tenant_id,name) VALUES(app.current_tenant(),'元の部');
UPDATE app.memberships SET department_id = $PREV WHERE user_id='$MANAGER' AND revoked_at IS NULL;" >/dev/null
expect_fail_because 'from the recorded department' call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B9','assignments',$SHA,1,1,'$ADMIN');
UPDATE app.memberships SET department_id = $DEPT WHERE user_id='$MANAGER' AND revoked_at IS NULL;
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id,prev_department_id,new_department_id)
  SELECT app.current_tenant(),'$B9',1,'membership',m.id,NULL,m.department_id FROM app.memberships m WHERE m.user_id='$MANAGER' AND m.revoked_at IS NULL;"
pass "明細の元の部署は、このトランザクションで変わる前の部署と一致しなければ付けられない（元の部署を偽らせない）"
call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B8','assignments',$SHA,1,1,'$ADMIN');
UPDATE app.memberships SET department_id = $DEPT WHERE user_id='$MANAGER' AND revoked_at IS NULL;
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id,prev_department_id,new_department_id)
  SELECT app.current_tenant(),'$B8',1,'membership',m.id,$PREV,m.department_id FROM app.memberships m WHERE m.user_id='$MANAGER' AND m.revoked_at IS NULL;" >/dev/null
[ "$(sql -At -c "SELECT count(*) FROM app.memberships m JOIN app.departments d ON d.id=m.department_id WHERE m.user_id='$MANAGER' AND d.name='取り込み部'")" = 1 ] || die "assignment"
pass "所属を割り当て、元の部署と入れた部署を明細に残せる"
B12=10000000-0000-4000-8000-0000000000b2
expect_fail_because 'from the recorded department' call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B12','assignments',$SHA,1,1,'$ADMIN');
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id,prev_department_id,new_department_id)
  SELECT app.current_tenant(),'$B12',1,'membership',m.id,$PREV,m.department_id FROM app.memberships m WHERE m.user_id='$MANAGER' AND m.revoked_at IS NULL;"
pass "この取り込みで部署を変えていない所属に、別の元の部署は書けない"
call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B12','assignments',$SHA,1,1,'$ADMIN');
UPDATE app.memberships SET department_id = department_id, updated_at = now() WHERE user_id='$MANAGER' AND revoked_at IS NULL;
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id,prev_department_id,new_department_id)
  SELECT app.current_tenant(),'$B12',1,'membership',m.id,m.department_id,m.department_id FROM app.memberships m WHERE m.user_id='$MANAGER' AND m.revoked_at IS NULL;" >/dev/null
pass "もともと入れる部署だった所属は、元の部署 = 入れた部署として付けられる（画面の取り込みが同じ部署へ割り当てる場合）"
call_as $ADMIN_T "
UPDATE app.memberships SET department_id = $PREV WHERE user_id='$MANAGER' AND revoked_at IS NULL;
INSERT INTO app.import_undos(tenant_id,batch_id,undone_by,retired_count,skipped_count) VALUES(app.current_tenant(),'$B8','$ADMIN',0,9);" >/dev/null
[ "$(sql -At -c "SELECT retired_count || '/' || skipped_count FROM app.import_undos WHERE batch_id='$B8'")" = "1/0" ] || die "assignment undo counts"
pass "割り当ての取り消しは元の部署へ戻した件数を DB が数える"
call_as $ADMIN_T "
UPDATE app.memberships SET updated_at = now() WHERE user_id='$MANAGER' AND revoked_at IS NULL;
INSERT INTO app.import_undos(tenant_id,batch_id,undone_by,retired_count,skipped_count) VALUES(app.current_tenant(),'$B12','$ADMIN',9,0);" >/dev/null
[ "$(sql -At -c "SELECT retired_count || '/' || skipped_count FROM app.import_undos WHERE batch_id='$B12'")" = "0/1" ] || die "no-op undo counts"
pass "既に元の部署にある所属を取り消しで直しただけでは、戻したと数えない"
call_as $ADMIN_T "
DELETE FROM app.departments WHERE name='取り込み部';
INSERT INTO app.import_undos(tenant_id,batch_id,undone_by,retired_count,skipped_count) VALUES(app.current_tenant(),'$B7','$ADMIN',0,9);" >/dev/null
[ "$(sql -At -c "SELECT retired_count || '/' || skipped_count FROM app.import_undos WHERE batch_id='$B7'")" = "1/0" ] || die "department undo counts"
pass "部署の取り消しは消した件数を DB が数える"
call_as $ADMIN_T "
UPDATE app.memberships SET department_id = NULL WHERE user_id='$MANAGER' AND revoked_at IS NULL;
DELETE FROM app.departments WHERE name='元の部';" >/dev/null

echo '== 取り消しの件数とセーブポイント（0074）'
B10=10000000-0000-4000-8000-0000000000b0
call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B10','assets',$SHA,1,1,'$ADMIN');
INSERT INTO app.assets(tenant_id,asset_key,name,asset_type,classification) VALUES(app.current_tenant(),'IMP-6','セーブポイント','情報','internal');
$TAG='IMP-6';
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id) SELECT app.current_tenant(),'$B10',1,'asset',id FROM app.assets WHERE asset_key='IMP-6';" >/dev/null
# Retiring inside a savepoint makes the row's xmin a subtransaction ID. It must still count as "1 retired".
call_as $ADMIN_T "
SAVEPOINT s1;
UPDATE app.assets SET status='retired', updated_at=now() WHERE asset_key='IMP-6';
RELEASE SAVEPOINT s1;
INSERT INTO app.import_undos(tenant_id,batch_id,undone_by,retired_count,skipped_count) VALUES(app.current_tenant(),'$B10','$ADMIN',0,9);" >/dev/null
[ "$(sql -At -c "SELECT retired_count || '/' || skipped_count FROM app.import_undos WHERE batch_id='$B10'")" = "1/0" ] || die "savepoint undo counts"
pass "セーブポイントの中で退役にした行も、取り消しの件数に数える"
# Merely editing another column of an already-retired row in the undo transaction does not count as "retired" (0075; 0074 counted it).
B11=10000000-0000-4000-8000-0000000000b1
call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B11','assets',$SHA,1,1,'$ADMIN');
INSERT INTO app.assets(tenant_id,asset_key,name,asset_type,classification) VALUES(app.current_tenant(),'IMP-7','退役済み','情報','internal');
$TAG='IMP-7';
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id) SELECT app.current_tenant(),'$B11',1,'asset',id FROM app.assets WHERE asset_key='IMP-7';" >/dev/null
call_as $ADMIN_T "UPDATE app.assets SET status='retired', updated_at=now() WHERE asset_key='IMP-7';" >/dev/null
call_as $ADMIN_T "
UPDATE app.assets SET name='直しただけ', updated_at=now() WHERE asset_key='IMP-7';
INSERT INTO app.import_undos(tenant_id,batch_id,undone_by,retired_count,skipped_count) VALUES(app.current_tenant(),'$B11','$ADMIN',9,0);" >/dev/null
[ "$(sql -At -c "SELECT retired_count || '/' || skipped_count FROM app.import_undos WHERE batch_id='$B11'")" = "0/1" ] || die "already retired counted"
pass "既に退役していた資産を取り消しで直しただけでは、退役にしたと数えない"
[ "$(sql -At -c "SELECT count(*) FROM app.row_transitions WHERE target_type='asset' AND new_value='retired'")" -ge 2 ] || die "transitions not recorded"
expect_fail_because 'permission denied' call_as $ADMIN_T "
INSERT INTO app.row_transitions(tenant_id,xact_id,target_type,target_id,old_value,new_value)
  SELECT app.current_tenant(), pg_current_xact_id(), 'asset', id, 'active', 'retired' FROM app.assets WHERE asset_key='IMP-7';"
pass "変化の記録は app_rw から書けない（トリガだけが書く）"

echo '== 規程の取り込み（0076）'
B13=10000000-0000-4000-8000-0000000000b3
B14=10000000-0000-4000-8000-0000000000b4
POL="(SELECT id FROM app.policies WHERE title='取り込み規程')"
call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B13','policies',$SHA,1,2,'$ADMIN');
INSERT INTO app.policies(tenant_id,title) VALUES(app.current_tenant(),'取り込み規程');
INSERT INTO app.policy_versions(tenant_id,policy_id,version,body_md) VALUES(app.current_tenant(),$POL,1,'# 取り込み規程');
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id) VALUES(app.current_tenant(),'$B13',1,'policy',$POL);
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id)
  SELECT app.current_tenant(),'$B13',1,'policy_version',id FROM app.policy_versions WHERE policy_id=$POL;" >/dev/null
pass "規程と版を取り込みの明細付きで作れる（1 行で 2 つの明細）"
expect_fail_because 'rows created in this transaction' call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B14','policies',$SHA,1,1,'$ADMIN');
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id)
  SELECT app.current_tenant(),'$B14',1,'policy_version',id FROM app.policy_versions WHERE policy_id=$POL;"
pass "前からある版は、規程の取り込みの明細に付けられない"
call_as $ADMIN_T "INSERT INTO app.policies(tenant_id,title) VALUES(app.current_tenant(),'前からある規程');" >/dev/null
expect_fail_because 'rows created in this transaction' call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B14','policies',$SHA,1,1,'$ADMIN');
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id)
  SELECT app.current_tenant(),'$B14',1,'policy',id FROM app.policies WHERE title='前からある規程';"
pass "前からある規程は、規程の取り込みの明細に付けられない（取り消しで規程ごと消させない）"
[ "$(sql -At -c "SELECT count(*) FROM app.row_transitions WHERE target_type='policy' AND new_value='created' AND target_id=(SELECT id FROM app.policies WHERE title='前からある規程')")" = 1 ] || die "policy created mark"
pass "作った規程は、変化の記録に「作った」として残る（明細の判定は作成日時ではなくトランザクションで見る。0077）"
sql -c "DELETE FROM app.policies WHERE title='前からある規程';" >/dev/null
# Even a version created in the same transaction cannot be attached once approved (prevents undo from deleting approved versions; only the top executive approves).
expect_fail_because 'rows created in this transaction' call_as ciso-token-0000000000000000000000000000000001 "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B14','policies',$SHA,1,1,'$CISO');
INSERT INTO app.policies(tenant_id,title) VALUES(app.current_tenant(),'承認する規程');
INSERT INTO app.policy_versions(tenant_id,policy_id,version,body_md)
  SELECT app.current_tenant(),id,1,'# 承認する規程' FROM app.policies WHERE title='承認する規程';
SELECT app.approve_policy_version((SELECT v.id FROM app.policy_versions v JOIN app.policies p ON p.tenant_id=v.tenant_id AND p.id=v.policy_id WHERE p.title='承認する規程'), NULL);
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id)
  SELECT app.current_tenant(),'$B14',1,'policy_version',v.id FROM app.policy_versions v JOIN app.policies p ON p.tenant_id=v.tenant_id AND p.id=v.policy_id WHERE p.title='承認する規程';"
pass "同じトランザクションで作って承認した版は、規程の取り込みの明細に付けられない"
expect_fail_because 'does not match the batch kind' call_as $ADMIN_T "
INSERT INTO app.import_batches(tenant_id,id,kind,file_sha256,row_count,created_count,imported_by) VALUES(app.current_tenant(),'$B14','assets',$SHA,1,1,'$ADMIN');
INSERT INTO app.policy_versions(tenant_id,policy_id,version,body_md) VALUES(app.current_tenant(),$POL,2,'# 種類違い');
INSERT INTO app.import_batch_items(tenant_id,batch_id,row_no,target_type,target_id)
  SELECT app.current_tenant(),'$B14',1,'policy_version',id FROM app.policy_versions WHERE policy_id=$POL AND version=2;"
pass "資産の取り込みに規程の版の明細は付けられない（種類と対象の一致）"
POL_CREATED="$(sql -At -c "SELECT created_at FROM app.policy_versions WHERE policy_id=$POL AND version=1")"
call_as $ADMIN_T "UPDATE app.policy_versions SET created_at = now() + interval '1 day' WHERE policy_id=$POL;" >/dev/null
[ "$(sql -At -c "SELECT created_at FROM app.policy_versions WHERE policy_id=$POL AND version=1")" = "$POL_CREATED" ] || die "policy version created_at changed"
pass "規程の版の作成日時は更新で変わらない"
call_as $ADMIN_T "
DELETE FROM app.policy_versions WHERE policy_id=$POL;
DELETE FROM app.policies WHERE title='取り込み規程';
INSERT INTO app.import_undos(tenant_id,batch_id,undone_by,retired_count,skipped_count) VALUES(app.current_tenant(),'$B13','$ADMIN',0,9);" >/dev/null
[ "$(sql -At -c "SELECT retired_count || '/' || skipped_count FROM app.import_undos WHERE batch_id='$B13'")" = "2/0" ] || die "policy undo counts"
pass "規程の取り消しは消した版と規程の件数を DB が数える"

echo '== up/down/up'
# How many to roll back is determined by how many are "currently applied" after that version.
# If a down partway through is refused, everything up to there is already rolled back, so counting files would roll back too far.
applied_after() { sql -At -c "SELECT count(*) FROM public.schema_migrations WHERE version::int > $1"; }
expect_fail_because '0076 rollback refused' "$ROOT/scripts/migrate.sh" down "$(applied_after 75)"
pass "規程の取り込みの記録があるうちは 0076 を巻き戻さない"
sql -c "DELETE FROM app.import_undos WHERE batch_id IN (SELECT id FROM app.import_batches WHERE kind = 'policies');
        DELETE FROM app.import_batch_items WHERE target_type IN ('policy','policy_version');
        DELETE FROM app.import_batches WHERE kind = 'policies';" >/dev/null
expect_fail_because '0073 rollback refused' "$ROOT/scripts/migrate.sh" down "$(applied_after 72)"
pass "組織の取り込みの記録があるうちは 0073 を巻き戻さない"
sql -c "DELETE FROM app.import_undos WHERE batch_id IN (SELECT id FROM app.import_batches WHERE kind IN ('departments','assignments'));
        DELETE FROM app.import_batch_items WHERE target_type IN ('department','membership');
        DELETE FROM app.import_batches WHERE kind IN ('departments','assignments');" >/dev/null
expect_fail_because '0071 rollback refused' "$ROOT/scripts/migrate.sh" down "$(applied_after 70)"
[ "$(sql -At -c "SELECT to_regclass('app.import_batches') IS NOT NULL")" = t ] || die "refused down dropped the table"
pass "取り込みの記録があるうちは 0071 を巻き戻さない"
sql -c "DELETE FROM app.import_undos; DELETE FROM app.import_batch_items; DELETE FROM app.import_batches;" >/dev/null
expect_fail_because '0070 rollback refused' "$ROOT/scripts/migrate.sh" down "$(applied_after 69)"
[ "$(sql -At -c "SELECT to_regclass('app.change_requests') IS NOT NULL")" = t ] || die "refused down dropped the table"
pass "変更の申請があるうちは 0070 を巻き戻さない"
sql -c "DELETE FROM app.change_requests;" >/dev/null
# Even with no requests, do not roll back while approval records (change_request) remain (rolling back and recreating would link old approvals to a request with the same ID).
expect_fail_because '0070 rollback refused' "$ROOT/scripts/migrate.sh" down "$(applied_after 69)"
pass "承認の記録が残っているうちも 0070 を巻き戻さない"
sql -c "DELETE FROM app.approvals WHERE target_type='change_request';" >/dev/null
expect_fail_because '0069 rollback refused' "$ROOT/scripts/migrate.sh" down "$(applied_after 68)"
[ "$(sql -At -c "SELECT to_regclass('app.vulnerabilities') IS NOT NULL")" = t ] || die "refused down dropped the table"
pass "脆弱性の記録があるうちは 0069 を巻き戻さない"
sql -c "DELETE FROM app.vulnerabilities;" >/dev/null
expect_fail_because '0068 rollback refused' "$ROOT/scripts/migrate.sh" down "$(applied_after 67)"
[ "$(sql -At -c "SELECT to_regclass('app.continuity_plans') IS NOT NULL")" = t ] || die "refused down dropped the table"
pass "事業継続の記録があるうちは 0068 を巻き戻さない"
sql -c "DELETE FROM app.continuity_tests; DELETE FROM app.continuity_plans;" >/dev/null
expect_fail_because '0066 rollback refused' "$ROOT/scripts/migrate.sh" down "$(applied_after 65)"
[ "$(sql -At -c "SELECT to_regclass('app.legal_requirements') IS NOT NULL")" = t ] || die "refused down dropped the table"
pass "要求事項の記録があるうちは 0066 を巻き戻さない"
sql -c "DELETE FROM app.legal_requirements;" >/dev/null
expect_fail_because '0065 rollback refused' "$ROOT/scripts/migrate.sh" down "$(applied_after 64)"
[ "$(sql -At -c "SELECT to_regclass('app.context_issues') IS NOT NULL")" = t ] || die "refused down dropped the table"
pass "課題・利害関係者の記録があるうちは 0065 を巻き戻さない"
sql -c "DELETE FROM app.context_issues; DELETE FROM app.interested_parties;" >/dev/null
"$ROOT/scripts/migrate.sh" down "$(applied_after 64)" >/dev/null
[ "$(sql -At -c "SELECT to_regclass('app.context_issues') IS NULL AND to_regclass('app.interested_parties') IS NULL AND to_regclass('app.legal_requirements') IS NULL")" = t ] || die "down left tables"
[ "$(sql -At -c "SELECT count(*) FROM public.schema_migrations WHERE version::int = 64")" = 1 ] || die "rolled back past 0064"
expect_fail_because 'unknown record kind' call_as $ADMIN_T "SELECT app.require_records_role('context');"
expect_fail_because 'unknown record kind' call_as $ADMIN_T "SELECT app.require_records_role('legal');"
[ "$(sql -At -c "SELECT to_regprocedure('app.records_role_allows(text)') IS NULL")" = t ] || die "down left records_role_allows"
call_as ciso-token-0000000000000000000000000000000001 "SELECT app.require_records_role('exception');" >/dev/null
pass "0065 以降の down で表と種類だけが消え、0064 は残る（戻しすぎない）"
"$ROOT/scripts/migrate.sh" up >/dev/null
[ "$(sql -At -c "SELECT to_regclass('app.context_issues') IS NOT NULL AND to_regclass('app.interested_parties') IS NOT NULL AND to_regclass('app.legal_requirements') IS NOT NULL")" = t ] || die "re-up failed"
call_as $ADMIN_T "SELECT app.require_records_role('context');" >/dev/null
call_as manager-token-0000000000000000000000000000003 "SELECT app.require_records_role('legal');" >/dev/null
[ "$(sql -At -c "SELECT count(*) FROM pg_policies WHERE schemaname='app' AND policyname IN ('records_role_insert','records_role_update','records_role_delete')")" = 33 ] || die "re-up policies"
pass "up で戻る"

echo 'isms registers: 全て緑'
