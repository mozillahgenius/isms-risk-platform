#!/usr/bin/env bash
# 0059 / 0060 の受入: メンバー管理の権限境界、オーナー 0 人の禁止、
# 作業の対象レコード整合、送信キューの権限、テンプレート設問の妥当性、テナント分離。
#
# 「通ること」だけでなく「狙った理由で落ちること」を確かめる。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${ISMS_TEST_DB:-isms_org_members_$$}"
die() { printf '[org members] %s\n' "$*" >&2; exit 1; }
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

T1=10000000-0000-4000-8000-000000000001
T2=20000000-0000-4000-8000-000000000001
sql <<'SQL'
INSERT INTO catalog.asset_classes_default(key,name_ja,rank,external_share_policy)
  VALUES ('internal','fixture',1,'approval_required') ON CONFLICT DO NOTHING;
INSERT INTO app.tenants(id,name,domain,dom_version_id)
  SELECT '10000000-0000-4000-8000-000000000001','one','one.test',id FROM catalog.dom_versions LIMIT 1;
INSERT INTO app.tenants(id,name,domain,dom_version_id)
  SELECT '20000000-0000-4000-8000-000000000001','two','two.test',id FROM catalog.dom_versions LIMIT 1;
INSERT INTO app.users(tenant_id,id,email,display_name) VALUES
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000011','ciso@one.test','ciso'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000012','admin@one.test','admin'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000013','manager@one.test','manager'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000014','member@one.test','member'),
 ('20000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000011','ciso@two.test','other ciso');
INSERT INTO app.memberships(tenant_id,user_id,role_key) VALUES
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000011','ciso'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000012','secretariat'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000013','risk_owner'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000014','employee'),
 ('20000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000011','ciso');
INSERT INTO app.vendors(tenant_id,id,name,discovery_source,criticality)
  VALUES ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000041','vendor one','manual','high');
SQL

token_for() { sql -c "SET ROLE auth_svc; SELECT app.create_session('$1','$2','$3',interval '1 hour'); RESET ROLE" >/dev/null; }
CISO_T=ciso-token-00000000000000000000000000000001
ADMIN_T=admin-token-0000000000000000000000000000002
MGR_T=manager-token-000000000000000000000000000003
MEM_T=member-token-0000000000000000000000000000004
OTHER_T=other-token-00000000000000000000000000000005
token_for "$T1" 10000000-0000-4000-8000-000000000011 "$CISO_T"
token_for "$T1" 10000000-0000-4000-8000-000000000012 "$ADMIN_T"
token_for "$T1" 10000000-0000-4000-8000-000000000013 "$MGR_T"
token_for "$T1" 10000000-0000-4000-8000-000000000014 "$MEM_T"
token_for "$T2" 20000000-0000-4000-8000-000000000011 "$OTHER_T"

call_as() {
  PGPASSWORD='' psql -Atq -v ON_ERROR_STOP=1 -U app_rw -d "$DB" \
    -c "BEGIN; SELECT app.set_tenant_context('$1'); $2 COMMIT;"
}
# 送信ワーカー専用ロール。app_rw では送信キューの状態を進められない（0059）。
call_as_worker() {
  PGPASSWORD='' psql -Atq -v ON_ERROR_STOP=1 -U mail_worker -d "$DB" \
    -c "BEGIN; SELECT app.set_tenant_context('$1'); $2 COMMIT;"
}

# 資産はテナント文脈の中で作る（0046 以降、枠組みの割当を伴わない資産は作れない）。
call_as "$ADMIN_T" "INSERT INTO app.assets(tenant_id,id,asset_key,name,asset_type,classification) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000051','A-1','asset one','system','internal'); SELECT app.set_management_frameworks_human('asset','10000000-0000-4000-8000-000000000051',ARRAY['RISK-MANAGEMENT']);" >/dev/null

# --- メンバー管理の権限境界 -------------------------------------------------
# 通ることを先に確かめてから、落ちることを確かめる（検査が空振りしていない証拠）。
call_as "$ADMIN_T" "INSERT INTO app.users(tenant_id,id,email,display_name) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000015','added@one.test','added');" >/dev/null
[ "$(sql -At -c "SELECT count(*) FROM app.users WHERE email='added@one.test'")" = 1 ] || die "admin could not add a member"
expect_fail_because 'admin role required' call_as "$MEM_T" \
  "INSERT INTO app.users(tenant_id,id,email,display_name) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000016','nope@one.test','nope');"
expect_fail_because 'admin role required' call_as "$MGR_T" \
  "INSERT INTO app.users(tenant_id,id,email,display_name) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000017','nope2@one.test','nope2');"
expect_fail_because 'admin role required' call_as "$MEM_T" \
  "UPDATE app.users SET status='suspended' WHERE id='10000000-0000-4000-8000-000000000015';"

# --- 権限昇格の経路を塞げているか（Codex 指摘 1） ---------------------------
# member が自分に ciso を足せない。オーナーの付け外しは role_manage（オーナー）のみ。
expect_fail_because 'owner role required' call_as "$MEM_T" \
  "INSERT INTO app.memberships(tenant_id,user_id,role_key) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000014','ciso');"
expect_fail_because 'admin role required' call_as "$MEM_T" \
  "INSERT INTO app.memberships(tenant_id,user_id,role_key) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000014','risk_owner');"
# 管理者はオーナーを配れない（自分を昇格させられない）。
expect_fail_because 'owner role required' call_as "$ADMIN_T" \
  "INSERT INTO app.memberships(tenant_id,user_id,role_key) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000015','ciso');"
# 管理者は ciso 行を書き換えて降格させることもできない（新旧の両方を見る）。
expect_fail_because 'owner role required' call_as "$ADMIN_T" \
  "UPDATE app.memberships SET role_key='employee' WHERE user_id='10000000-0000-4000-8000-000000000011' AND role_key='ciso';"
expect_fail_because 'owner role required' call_as "$ADMIN_T" \
  "DELETE FROM app.memberships WHERE user_id='10000000-0000-4000-8000-000000000011' AND role_key='ciso';"
# 管理者は所属の整理はできる（禁止が広すぎないことの確認）。
call_as "$ADMIN_T" "INSERT INTO app.memberships(tenant_id,user_id,role_key) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000015','employee');" >/dev/null
# 部門はオーナー・管理者だけが触れる。
expect_fail_because 'admin role required' call_as "$MGR_T" \
  "INSERT INTO app.departments(tenant_id,name) VALUES(app.current_tenant(),'勝手な部門');"
call_as "$ADMIN_T" "INSERT INTO app.departments(tenant_id,id,name) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000031','営業部');" >/dev/null

# --- 組織設定の書き換え（Codex 指摘 2） -------------------------------------
expect_fail_because 'admin role required' call_as "$MEM_T" \
  "INSERT INTO app.certification_bodies(tenant_id,body_name,certification_standard) VALUES(app.current_tenant(),'勝手な審査機関','ISO/IEC 27001:2022');"
call_as "$ADMIN_T" "INSERT INTO app.certification_bodies(tenant_id,body_name,certification_standard) VALUES(app.current_tenant(),'審査機関A','ISO/IEC 27001:2022');" >/dev/null

# --- オーナーが 0 人になる操作を拒む ----------------------------------------
expect_fail_because 'at least one active owner' call_as "$CISO_T" \
  "UPDATE app.memberships SET revoked_at=now() WHERE user_id='10000000-0000-4000-8000-000000000011' AND role_key='ciso';"
expect_fail_because 'at least one active owner' call_as "$ADMIN_T" \
  "UPDATE app.users SET status='left' WHERE id='10000000-0000-4000-8000-000000000011';"
# 別のオーナーが居れば降ろせる（禁止が広すぎないことの確認）。
call_as "$CISO_T" "INSERT INTO app.memberships(tenant_id,user_id,role_key) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000012','ciso');" >/dev/null
call_as "$CISO_T" "UPDATE app.memberships SET revoked_at=now() WHERE user_id='10000000-0000-4000-8000-000000000011' AND role_key='ciso';" >/dev/null
[ "$(sql -At -c "SELECT count(*) FROM app.memberships WHERE role_key='ciso' AND revoked_at IS NULL AND tenant_id='$T1'")" = 1 ] || die "owner handover failed"

# --- 作業の対象レコード整合 --------------------------------------------------
call_as "$ADMIN_T" "INSERT INTO app.work_items(tenant_id,id,work_type,title,resource_type,resource_id,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000061','asset_inventory','asset work','asset','10000000-0000-4000-8000-000000000051',app.current_session_user(),app.current_session_user());" >/dev/null
expect_fail_because 'resource type does not match work type' call_as "$ADMIN_T" \
  "INSERT INTO app.work_items(tenant_id,id,work_type,title,resource_type,resource_id,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000062','incident_response','mismatch','asset','10000000-0000-4000-8000-000000000051',app.current_session_user(),app.current_session_user());"
expect_fail_because 'assignment target not found' call_as "$ADMIN_T" \
  "INSERT INTO app.work_items(tenant_id,id,work_type,title,resource_type,resource_id,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000063','asset_inventory','ghost','asset','10000000-0000-4000-8000-000000000099',app.current_session_user(),app.current_session_user());"
# 種別だけ・ID だけの片側入力は CHECK が拒む（種別だけの場合はトリガーが
# 先に実在確認で落とすので、CHECK 自体は ID だけの向きで確かめる）。
expect_fail_because 'work_items_resource_pair' call_as "$ADMIN_T" \
  "INSERT INTO app.work_items(tenant_id,id,work_type,title,resource_id,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000064','asset_inventory','half','10000000-0000-4000-8000-000000000051',app.current_session_user(),app.current_session_user());"
expect_fail_because 'assignment target not found' call_as "$ADMIN_T" \
  "INSERT INTO app.work_items(tenant_id,id,work_type,title,resource_type,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000065','asset_inventory','half2','asset',app.current_session_user(),app.current_session_user());"

# --- 送信キューの権限 --------------------------------------------------------
call_as "$MGR_T" "INSERT INTO app.mail_outbox(tenant_id,purpose,to_email,subject,body_text,created_by,updated_by) VALUES(app.current_tenant(),'work_assignment','member@one.test','依頼','本文',app.current_session_user(),app.current_session_user());" >/dev/null
expect_fail_because 'admin role required' call_as "$MGR_T" \
  "INSERT INTO app.mail_outbox(tenant_id,purpose,to_email,subject,body_text,created_by,updated_by) VALUES(app.current_tenant(),'external_questionnaire','x@vendor.test','件名','本文',app.current_session_user(),app.current_session_user());"
expect_fail_because 'manager role required' call_as "$MEM_T" \
  "INSERT INTO app.mail_outbox(tenant_id,purpose,to_email,subject,body_text,created_by,updated_by) VALUES(app.current_tenant(),'work_assignment','member@one.test','件名','本文',app.current_session_user(),app.current_session_user());"
call_as "$ADMIN_T" "INSERT INTO app.mail_outbox(tenant_id,id,purpose,to_email,subject,body_text,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000071','external_questionnaire','x@vendor.test','件名','本文',app.current_session_user(),app.current_session_user());" >/dev/null
expect_fail_because 'violates check constraint' call_as "$ADMIN_T" \
  "INSERT INTO app.mail_outbox(tenant_id,purpose,to_email,subject,body_text,created_by,updated_by) VALUES(app.current_tenant(),'work_assignment','MiXeD@one.test','件名','本文',app.current_session_user(),app.current_session_user());"

# 本人だけを消してガードを迂回する経路は塞がっている（Codex 指摘）。
expect_fail_because 'session user context is required' \
  env PGPASSWORD='' psql -Atq -v ON_ERROR_STOP=1 -U app_rw -d "$DB" -c \
  "BEGIN; SELECT app.set_tenant_context('$MEM_T'); SELECT set_config('app.session_user_id','',true); INSERT INTO app.users(tenant_id,id,email,display_name) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000018','bypass@one.test','bypass'); COMMIT;"
expect_fail_because 'session user context is required' \
  env PGPASSWORD='' psql -Atq -v ON_ERROR_STOP=1 -U app_rw -d "$DB" -c \
  "BEGIN; SELECT app.set_tenant_context('$MEM_T'); SELECT set_config('app.session_user_id','',true); INSERT INTO app.mail_outbox(tenant_id,purpose,to_email,subject,body_text) VALUES(app.current_tenant(),'external_questionnaire','x@vendor.test','迂回','本文'); COMMIT;"

# --- テンプレート ------------------------------------------------------------
call_as "$MGR_T" "INSERT INTO app.questionnaire_templates(tenant_id,id,name,kind,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000081','標準チェック','checklist',app.current_session_user(),app.current_session_user());" >/dev/null
expect_fail_because 'manager role required' call_as "$MEM_T" \
  "INSERT INTO app.questionnaire_templates(tenant_id,name,kind,created_by,updated_by) VALUES(app.current_tenant(),'勝手に作る','checklist',app.current_session_user(),app.current_session_user());"
call_as "$MGR_T" "INSERT INTO app.questionnaire_template_questions(tenant_id,template_id,ordinal,prompt,answer_type,options) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000081',1,'責任者は誰ですか','text','[]'::jsonb);" >/dev/null
expect_fail_because 'violates check constraint' call_as "$MGR_T" \
  "INSERT INTO app.questionnaire_template_questions(tenant_id,template_id,ordinal,prompt,answer_type,options) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000081',2,'選べない設問','single_choice','[]'::jsonb);"
call_as "$MGR_T" "INSERT INTO app.questionnaire_template_questions(tenant_id,template_id,ordinal,prompt,answer_type,options) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000081',2,'実施していますか','single_choice','[\"はい\",\"いいえ\"]'::jsonb);" >/dev/null
expect_fail_because 'violates check constraint' call_as "$MGR_T" \
  "UPDATE app.questionnaire_template_questions SET ordinal=0 WHERE template_id='10000000-0000-4000-8000-000000000081' AND ordinal=1;"

# 質問票を 1 件作り、送信キューへ結び付ける（送信後に状態が進むことを見る）。
call_as "$ADMIN_T" "INSERT INTO app.external_questionnaires(tenant_id,id,vendor_id,template_id,title,recipient_name,recipient_email,status,queued_at,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000091','10000000-0000-4000-8000-000000000041','10000000-0000-4000-8000-000000000081','標準チェック','担当','x@vendor.test','queued',now(),app.current_session_user(),app.current_session_user());" >/dev/null
call_as "$ADMIN_T" "INSERT INTO app.mail_outbox(tenant_id,id,purpose,to_email,subject,body_text,related_type,related_id,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000073','external_questionnaire','x@vendor.test','質問票の件名','質問票の本文','external_questionnaire','10000000-0000-4000-8000-000000000091',app.current_session_user(),app.current_session_user());" >/dev/null

# --- テナント分離 ------------------------------------------------------------
[ "$(call_as "$OTHER_T" "SELECT count(*) FROM app.questionnaire_templates;" | tail -1)" = 0 ] \
  || die "template leaked across tenants"
[ "$(call_as "$OTHER_T" "SELECT count(*) FROM app.mail_outbox;" | tail -1)" = 0 ] \
  || die "mail outbox leaked across tenants"
[ "$(call_as "$OTHER_T" "SELECT count(*) FROM app.work_items;" | tail -1)" = 0 ] \
  || die "work items leaked across tenants"

# --- 送信キューの改ざん（Codex 指摘 8） -------------------------------------
expect_fail_because 'permission denied' call_as "$ADMIN_T" \
  "UPDATE app.mail_outbox SET to_email='attacker@evil.test' WHERE id='10000000-0000-4000-8000-000000000071';"
expect_fail_because 'permission denied' call_as "$ADMIN_T" \
  "UPDATE app.mail_outbox SET body_text='書き換え' WHERE id='10000000-0000-4000-8000-000000000071';"
expect_fail_because 'permission denied' call_as "$ADMIN_T" \
  "DELETE FROM app.mail_outbox WHERE id='10000000-0000-4000-8000-000000000071';"
# 1 通も送らずに「送信済み」を作れない（sent へは sending からしか入れない）。
# app_rw には UPDATE 権限そのものが無い（1 通も送らずに送信済みを作れない）。
expect_fail_because 'permission denied' call_as "$ADMIN_T" \
  "UPDATE app.mail_outbox SET status='sent', sent_at=now() WHERE id='10000000-0000-4000-8000-000000000071';"
expect_fail_because 'permission denied' call_as "$ADMIN_T" \
  "UPDATE app.mail_outbox SET status='failed' WHERE id='10000000-0000-4000-8000-000000000071';"
# 送信関数は mail_worker 専用。app_rw には EXECUTE 権限すら無い。
expect_fail_because 'permission denied for function claim_mail_batch' call_as "$ADMIN_T" \
  "SELECT app.claim_mail_batch(10, false, false);"
expect_fail_because 'permission denied for function mark_mail_sent' call_as "$ADMIN_T" \
  "SELECT app.mark_mail_sent('10000000-0000-4000-8000-000000000071');"

# --- 制御文字は積めない（Codex 指摘 6 の入口側） ----------------------------
expect_fail_because 'violates check constraint' call_as "$ADMIN_T" \
  "INSERT INTO app.mail_outbox(tenant_id,purpose,to_email,subject,body_text,created_by,updated_by) VALUES(app.current_tenant(),'work_assignment','member@one.test',E'件\\x1e名','本文',app.current_session_user(),app.current_session_user());"
# 本文の改行は通る（禁止が広すぎないことの確認）。
call_as "$ADMIN_T" "INSERT INTO app.mail_outbox(tenant_id,id,purpose,to_email,subject,body_text,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000072','work_assignment','member@one.test','改行あり',E'1行目\\n2行目\\t字下げ',app.current_session_user(),app.current_session_user());" >/dev/null

# --- 送信ワーカー ------------------------------------------------------------
# --apply を付けない限り、送信待ちの状態を進めない。
QUEUED_BEFORE="$(sql -At -c "SELECT count(*) FROM app.mail_outbox WHERE status='queued'")"
[ "$QUEUED_BEFORE" = 4 ] || die "送信待ちの件数が想定と違う: $QUEUED_BEFORE"
python3 "$ROOT/scripts/send_mail_outbox.py" --token "$ADMIN_T" --db "$DB" >/dev/null
[ "$(sql -At -c "SELECT count(*) FROM app.mail_outbox WHERE status='queued'")" = 4 ] \
  || die "dry-run changed the queue"

# SMTP 設定が無いまま --apply しても、キューへ触らずに落ちる。
if env -u ISMS_SMTP_HOST -u ISMS_SMTP_USER -u ISMS_SMTP_PASSWORD -u ISMS_SMTP_FROM \
     python3 "$ROOT/scripts/send_mail_outbox.py" --token "$ADMIN_T" --db "$DB" --apply >/dev/null 2>&1; then
  die "apply without SMTP settings unexpectedly succeeded"
fi
[ "$(sql -At -c "SELECT count(*) FROM app.mail_outbox WHERE status='queued'")" = 4 ] \
  || die "failed apply consumed the queue"

# 繋がらない相手なら failed として残し、理由を書く。sending のまま放置しない。
env ISMS_SMTP_HOST=127.0.0.1 ISMS_SMTP_PORT=1 ISMS_SMTP_USER=u ISMS_SMTP_PASSWORD=p \
    ISMS_SMTP_FROM='ISMS <isms@one.test>' ISMS_SMTP_STARTTLS=off \
    python3 "$ROOT/scripts/send_mail_outbox.py" --token "$ADMIN_T" --db "$DB" --apply >/dev/null 2>&1 \
  && die "unreachable smtp unexpectedly succeeded"
[ "$(sql -At -c "SELECT count(*) FROM app.mail_outbox WHERE status='failed' AND last_error <> ''")" = 4 ] \
  || die "unreachable smtp did not record the failure"
[ "$(sql -At -c "SELECT count(*) FROM app.mail_outbox WHERE status='sending'")" = 0 ] \
  || die "rows left stuck in sending"

# 平文は外向きに使えない（ループバック以外では拒む）。
env ISMS_SMTP_HOST=smtp.example.com ISMS_SMTP_PORT=25 ISMS_SMTP_USER=u ISMS_SMTP_PASSWORD=p \
    ISMS_SMTP_FROM='ISMS <isms@one.test>' ISMS_SMTP_STARTTLS=off \
    python3 "$ROOT/scripts/send_mail_outbox.py" --token "$ADMIN_T" --db "$DB" --apply --retry-failed >/dev/null 2>&1 \
  && die "plaintext to a remote host was allowed"

# 実際に SMTP 会話を通し、届いた本文とキューの状態を確かめる。
MAILDIR="$(mktemp -d)"; trap 'dropdb --if-exists "$DB" >/dev/null 2>&1; rm -rf "$MAILDIR"' EXIT
SMTP_PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
python3 "$ROOT/tests/fixtures/fake_smtp.py" --port "$SMTP_PORT" --out "$MAILDIR" --expect 4 &
FAKE_PID=$!
sleep 1
env ISMS_SMTP_HOST=127.0.0.1 ISMS_SMTP_PORT="$SMTP_PORT" ISMS_SMTP_USER=u ISMS_SMTP_PASSWORD=p \
    ISMS_SMTP_FROM='ISMS <isms@one.test>' ISMS_SMTP_STARTTLS=off \
    python3 "$ROOT/scripts/send_mail_outbox.py" --token "$ADMIN_T" --db "$DB" --apply --retry-failed >/dev/null \
  || die "send through the fake smtp failed"
wait "$FAKE_PID" || true
[ "$(ls "$MAILDIR" | wc -l | tr -d ' ')" = 4 ] || die "fake smtp did not receive 4 mails"
# 日本語の件名・本文は RFC2047 / base64 で載るので、復号してから確かめる。
python3 - "$MAILDIR" <<'EOF' || die "delivered mail did not carry the subject and body"
import email, email.header, pathlib, sys
subjects, bodies = [], []
for path in sorted(pathlib.Path(sys.argv[1]).glob('*.eml')):
    message = email.message_from_bytes(path.read_bytes())
    subjects.append(str(email.header.make_header(email.header.decode_header(message['Subject']))))
    bodies.append(message.get_payload(decode=True).decode('utf-8'))
assert any('件名' in s for s in subjects), subjects
assert any('本文' in b for b in bodies), bodies
EOF
[ "$(sql -At -c "SELECT count(*) FROM app.mail_outbox WHERE status='sent' AND sent_at IS NOT NULL")" = 4 ] \
  || die "sent rows were not recorded"
# 実際に出たときだけ質問票が送信済みになる。
[ "$(sql -At -c "SELECT status FROM app.external_questionnaires WHERE id='10000000-0000-4000-8000-000000000091'")" = sent ] \
  || die "questionnaire was not advanced to sent"

# 積む側は配送の状態を指定できない（INSERT で「送信済み」を作れない）。
call_as "$ADMIN_T" "INSERT INTO app.mail_outbox(tenant_id,id,purpose,to_email,subject,body_text,status,sent_at,attempts,last_error,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000075','work_assignment','member@one.test','偽装','本文','sent',now(),9,'でっちあげ',app.current_session_user(),app.current_session_user());" >/dev/null
[ "$(sql -At -c "SELECT status||'/'||attempts||'/'||coalesce(sent_at::text,'-')||'/'||last_error FROM app.mail_outbox WHERE id='10000000-0000-4000-8000-000000000075'")" = 'queued/0/-/' ] \
  || die "INSERT で配送状態を指定できてしまう"

# sending のまま止まった行は、自動再送されず、回収コマンドで見えるようになる
# （Codex 指摘 5）。届いたかもしれないので failed へ落とすだけで再送はしない。
# 本物の sending を作るにはワーカーが掴むしかない（INSERT では作れない）。
call_as "$ADMIN_T" "INSERT INTO app.mail_outbox(tenant_id,id,purpose,to_email,subject,body_text,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000074','work_assignment','member@one.test','取り残し','本文',app.current_session_user(),app.current_session_user());" >/dev/null
call_as_worker "$ADMIN_T" "SELECT app.claim_mail_batch(50,false,false);" >/dev/null
[ "$(sql -At -c "SELECT status FROM app.mail_outbox WHERE id='10000000-0000-4000-8000-000000000074'")" = sending ] \
  || die "worker could not claim the row"
# 経過時間の演出だけは検査の都合で直接書く（本番経路には無い）。
sql -c "UPDATE app.mail_outbox SET updated_at = now() - interval '3 hours' WHERE tenant_id='$T1' AND status='sending';" >/dev/null
# 通常実行も --retry-failed も sending は拾わない。
python3 "$ROOT/scripts/send_mail_outbox.py" --token "$ADMIN_T" --db "$DB" | grep -q '10000000-0000-4000-8000-000000000074' \
  || die "dry-run did not surface the stuck row"
python3 "$ROOT/scripts/send_mail_outbox.py" --token "$ADMIN_T" --db "$DB" --reclaim-stale 60 >/dev/null
[ "$(sql -At -c "SELECT status FROM app.mail_outbox WHERE id='10000000-0000-4000-8000-000000000074'")" = failed ] \
  || die "stale sending row was not reclaimed"
[ "$(sql -At -c "SELECT count(*) FROM app.mail_outbox WHERE status='sending'")" = 0 ] \
  || die "stale reclaim left rows in sending"
# 短すぎるしきい値は拒む（実行中のワーカーを巻き込むため）。
python3 "$ROOT/scripts/send_mail_outbox.py" --token "$ADMIN_T" --db "$DB" --reclaim-stale 5 >/dev/null 2>&1 \
  && die "reclaim accepted a too-short threshold"
# 回収した行は --retry-failed では拾わない（届いたかもしれないので自動再送しない）。
env ISMS_SMTP_HOST=127.0.0.1 ISMS_SMTP_PORT=1 ISMS_SMTP_USER=u ISMS_SMTP_PASSWORD=p \
    ISMS_SMTP_FROM='ISMS <isms@one.test>' ISMS_SMTP_STARTTLS=off \
    python3 "$ROOT/scripts/send_mail_outbox.py" --token "$ADMIN_T" --db "$DB" --apply --retry-failed >/dev/null 2>&1 || true
[ "$(sql -At -c "SELECT attempts FROM app.mail_outbox WHERE id='10000000-0000-4000-8000-000000000074'")" = 1 ] \
  || die "reclaimed row was picked up by --retry-failed"

# app_rw では送信キューの状態を一切動かせない（ロール境界そのものの確認）。
expect_fail_because 'permission denied' call_as "$ADMIN_T" \
  "UPDATE app.mail_outbox SET attempts=attempts+1 WHERE id='10000000-0000-4000-8000-000000000071';"
expect_fail_because 'permission denied for function reclaim_stale_mail' call_as "$ADMIN_T" \
  "SELECT app.reclaim_stale_mail(60);"

# --- 巻き戻し ----------------------------------------------------------------
# 巻き戻す本数は固定値にしない。後から migration が増えると、
# 本数決め打ちでは別の版を巻き戻して検査が空振りする（0061 追加時に踏んだ）。
DOWN_N="$(sql -At -c "SELECT count(*) FROM public.schema_migrations WHERE version >= '0059'")"
"$ROOT/scripts/migrate.sh" down "$DOWN_N" >/dev/null
[ "$(sql -At -c "SELECT to_regclass('app.mail_outbox') IS NULL")" = t ] || die "0059 down left mail_outbox"
[ "$(sql -At -c "SELECT to_regclass('app.questionnaire_templates') IS NULL")" = t ] || die "0060 down left templates"

printf '[org members] ok\n'
