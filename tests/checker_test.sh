#!/usr/bin/env bash
# Acceptance for the checker. Goes as far as **actually failing when things are broken**.
#
# What it checks:
#   1. A tenant can be created (via the provisioner) / the 12 standard policies are expanded
#   2. **The DB does not accept** an unverified check as pass
#   3. A --skip-verify run passes nothing (all inconclusive)
#   4. A normal run passes everything, leaving negative_verified and digest
#   5. Creating a real violation yields fail (reverting it returns to pass)
#   6. **The fixture does not pollute the target DB** (business data matches before and after the run)
#
# DB used: ISMS_CHECKER_TEST_DB (default isms_checker_test). It is recreated, so existing data is lost.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${ISMS_CHECKER_TEST_DB:-isms_checker_test}"
VERIFY_DB="${ISMS_CHECKER_TEST_VERIFY_DB:-isms_checker_test_verify}"
if [[ -z "${PGUSER:-}" ]]; then
  PGUSER="${USER:-}"
fi
if [[ -z "$PGUSER" ]]; then
  printf 'checker_test: PGUSER または USER を明示してください（uidからの自動推測はしません）\n' >&2
  exit 2
fi
export PGUSER
PGHOST="${PGHOST:-127.0.0.1}"
export PGHOST
ADMIN_PGUSER="${ISMS_ADMIN_PGUSER:-$PGUSER}"

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
die()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

cleanup() {
  PGUSER="$ADMIN_PGUSER" dropdb --if-exists "$DB" >/dev/null 2>&1 || true
  PGUSER="$ADMIN_PGUSER" dropdb --if-exists "$VERIFY_DB" >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '\n\033[36m== checker の受入\033[0m\n'

# ---- 0. shape check of catalog SQL (no DB) -----------------------------------
python3 "$ROOT/tests/checker_sql_guard_test.py" || die "カタログ SQL の形の検査"

PGUSER="$ADMIN_PGUSER" dropdb --if-exists "$DB" >/dev/null
PGUSER="$ADMIN_PGUSER" createdb "$DB"
PGUSER="$ADMIN_PGUSER" ISMS_DB="$DB" "$ROOT/scripts/migrate.sh" up >/dev/null 2>&1 || die "migration が失敗"
PGUSER="$ADMIN_PGUSER" psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null
PGUSER="$ADMIN_PGUSER" psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0002_checks_core.sql" >/dev/null
PGUSER="$ADMIN_PGUSER" ISMS_DB="$DB" python3 "$ROOT/db/seeds/0003_connectors.py" >/dev/null
PGUSER="$ADMIN_PGUSER" psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0004_phase2_checks.sql" >/dev/null
PGUSER="$ADMIN_PGUSER" ISMS_DB="$DB" python3 "$ROOT/db/seeds/0005_agent_definition.py" >/dev/null
PGUSER="$ADMIN_PGUSER" psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0006_phase3_device_checks.sql" >/dev/null

# DB creation, migrations and seeds run as admin; acceptance operations run as the real app role.
# So that superuser privilege bypass does not falsely pass the "read/write/delete denied" checks.
export PGUSER="${ISMS_APP_PGUSER:-app_rw}"

checker() {
  if [[ "${ISMS_CHECKER_VERBOSE:-0}" == "1" ]]; then
    PGUSER="$ADMIN_PGUSER" python3 "$ROOT/scripts/checker.py" "$@"
  else
    PGUSER="$ADMIN_PGUSER" python3 "$ROOT/scripts/checker.py" "$@" >/dev/null 2>&1
  fi
}

# ---- 1. create a tenant -----------------------------------------------------
OUT=$(ISMS_DB="$DB" python3 "$ROOT/scripts/new_tenant.py" \
        --name '検査用' --domain 'test.invalid' \
        --admin-email 'admin@test.invalid' --admin-name '管理者')
TOKEN=$(printf '%s\n' "$OUT" | tail -1)
EXPANDED=$(printf '%s\n' "$OUT" | sed -n 's/^規程の展開: \([0-9]*\) 本$/\1/p')
# Do not hard-code the expected number. The spec is to expand as many standard policies as the
# catalog has, and the count depends on the seed set (this test uses 0001-0006).
# Hard-coding it makes this test fail just by adding a policy (it did fail going 12 -> 28).
WANT_POL=$(psql -At -d "$DB" -c "SELECT count(*) FROM catalog.policies_default")
[ "$EXPANDED" = "$WANT_POL" ] \
  || die "標準規程の展開が catalog の本数と違う（展開 ${EXPANDED} / catalog ${WANT_POL}）"
[ "$EXPANDED" -gt 0 ] || die "標準規程が 1 本も展開されていない"
[ ${#TOKEN} -ge 32 ] || die "トークンが短すぎる"
pass "テナントを作れる（標準規程 ${EXPANDED} 本を展開＝catalog の全数）"

ctx() { # $1=sql  establish the tenant context, run one statement, return only the last value
  # Without -q, BEGIN / COMMIT command tags get mixed in and tail -1 yields 'COMMIT'.
  psql -Atq -d "$DB" -c "BEGIN; SELECT app.set_tenant_context('$TOKEN'); $1; COMMIT;" 2>&1
}

receipt() { # issue a (7) receipt ID covering every check in the current catalog
  ctx "SELECT app.accept_verification_receipt(ARRAY(SELECT key FROM catalog.checks ORDER BY key), 'checker-test')" | tail -1
}

# ---- 2. a run cannot start without a receipt ID (negative check) ------------
BEFORE_RUNS=$(ctx "SELECT count(*) FROM app.check_runs" | tail -1)
ISMS_DB="$DB" ISMS_CHECKER_VERIFY_DB="$VERIFY_DB" \
  checker --token "$TOKEN" --skip-verify || true
AFTER_RUNS=$(ctx "SELECT count(*) FROM app.check_runs" | tail -1)
[ "$BEFORE_RUNS" = "$AFTER_RUNS" ] || die "受付IDなしで checker が実行記録を進めた"
pass "受付IDなしでは checker が実行を進めない"

OUT=$(psql -d "$DB" -v ON_ERROR_STOP=0 2>&1 <<SQL || true
BEGIN;
SELECT app.set_tenant_context('$TOKEN');
INSERT INTO app.check_runs (tenant_id, check_key, started_at, result, negative_verified)
  SELECT app.current_tenant(), 'CHK-CORE-ROLE-001', now(), 'pass', false;
ROLLBACK;
SQL
)
case "$OUT" in
  *"verification receipt id is required before execution"*) pass "DB も受付IDなしの実行記録を拒否する" ;;
  *) die "受付IDなしの実行記録が通ってしまった: $OUT" ;;
esac

WRONG_RECEIPT=$(ctx "SELECT app.accept_verification_receipt(ARRAY['CHK-CORE-POLICY-001'], 'checker-test')" | tail -1)
OUT=$(psql -d "$DB" -v ON_ERROR_STOP=0 2>&1 <<SQL || true
BEGIN;
SELECT app.set_tenant_context('$TOKEN');
INSERT INTO app.check_runs (tenant_id, check_key, started_at, result, negative_verified, verification_receipt_id)
  SELECT app.current_tenant(), 'CHK-CORE-ROLE-001', now(), 'fail', false, '$WRONG_RECEIPT'::uuid;
ROLLBACK;
SQL
)
case "$OUT" in
  *"verification receipt does not authorize this check"*) pass "対象外の受付IDでも実行記録を拒否する" ;;
  *) die "対象外の受付IDで実行記録が通ってしまった: $OUT" ;;
esac

# ---- 3. (7) receipts are append-only (SELECT / UPDATE / DELETE rejected) -----
RECEIPT_ID=$(receipt)
[ -n "$RECEIPT_ID" ] || die "検証受付IDを発行できない"
OUT=$(psql -d "$DB" -v ON_ERROR_STOP=0 2>&1 <<SQL || true
BEGIN;
SELECT app.set_tenant_context('$TOKEN');
SELECT count(*) FROM app.verification_receipts;
ROLLBACK;
SQL
)
case "$OUT" in
  *"permission denied"*) pass "受付レコードの読み出しを拒否する" ;;
  *) die "受付レコードを読めてしまった: $OUT" ;;
esac
OUT=$(psql -d "$DB" -v ON_ERROR_STOP=0 2>&1 <<SQL || true
BEGIN;
SELECT app.set_tenant_context('$TOKEN');
UPDATE app.verification_receipts SET requester='rewritten';
ROLLBACK;
SQL
)
case "$OUT" in
  *"permission denied"*) pass "受付レコードの更新を拒否する" ;;
  *) die "受付レコードを更新できてしまった: $OUT" ;;
esac
OUT=$(psql -d "$DB" -v ON_ERROR_STOP=0 2>&1 <<SQL || true
BEGIN;
SELECT app.set_tenant_context('$TOKEN');
DELETE FROM app.verification_receipts;
ROLLBACK;
SQL
)
case "$OUT" in
  *"permission denied"*) pass "受付レコードの削除を拒否する" ;;
  *) die "受付レコードを削除できてしまった: $OUT" ;;
esac

# ---- 4. the DB rejects an unverified pass -----------------------------------
OUT=$(psql -d "$DB" -v ON_ERROR_STOP=0 2>&1 <<SQL || true
BEGIN;
SELECT app.set_tenant_context('$TOKEN');
INSERT INTO app.check_runs (tenant_id, check_key, started_at, result, negative_verified, verification_receipt_id)
  SELECT app.current_tenant(), 'CHK-CORE-ROLE-001', now(), 'pass', false, '$RECEIPT_ID'::uuid;
ROLLBACK;
SQL
)
case "$OUT" in
  *check_runs_pass_requires_negative_verification*) pass "確認していない pass を DB が拒否する" ;;
  *) die "確認していない pass が通ってしまった: $OUT" ;;
esac

# ---- 5. --skip-verify passes nothing ----------------------------------------
ISMS_DB="$DB" ISMS_CHECKER_VERIFY_DB="$VERIFY_DB" \
  checker --token "$TOKEN" --verification-receipt-id "$RECEIPT_ID" --skip-verify || true
N=$(ctx "SELECT count(*) FROM app.check_runs WHERE result='pass'" | tail -1)
[ "$N" = "0" ] || die "検証を飛ばした実行で pass が $N 件できた"
N=$(ctx "SELECT count(*) FROM app.check_runs WHERE result='inconclusive'" | tail -1)
[ "$N" = "20" ] || die "inconclusive が 20 件ではない（$N）"
pass "検証を飛ばすと 1 本も pass しない（全件 inconclusive）"

# ---- 6, first half: fingerprint of business data before the run ------------
BEFORE=$(ctx "SELECT md5(string_agg(x, '|' ORDER BY x)) FROM (
                SELECT id::text||coalesce(catalog_key,'') FROM app.policies
                UNION ALL SELECT id::text||body_md FROM app.policy_versions
                UNION ALL SELECT id::text||role_key FROM app.memberships) t(x)" | tail -1)

# ---- 6. a normal run passes everything -------------------------------------
RECEIPT_ID=$(receipt)
ISMS_DB="$DB" ISMS_CHECKER_VERIFY_DB="$VERIFY_DB" \
  checker --token "$TOKEN" --verification-receipt-id "$RECEIPT_ID" \
  || die "checker が非ゼロで終わった"
N=$(ctx "SELECT count(*) FROM app.check_runs WHERE result='pass' AND negative_verified
          AND verified_digest ~ '^[0-9a-f]{64}\$'" | tail -1)
[ "$N" = "20" ] || die "確認つきの pass が 20 件ではない（$N）"
pass "通常の実行は全件 pass（negative_verified と digest つき）"

# ---- 6, second half: the target DB is not polluted -------------------------
AFTER=$(ctx "SELECT md5(string_agg(x, '|' ORDER BY x)) FROM (
               SELECT id::text||coalesce(catalog_key,'') FROM app.policies
               UNION ALL SELECT id::text||body_md FROM app.policy_versions
               UNION ALL SELECT id::text||role_key FROM app.memberships) t(x)" | tail -1)
[ "$BEFORE" = "$AFTER" ] || die "checker の実行で業務データが変わった（fixture が対象 DB に漏れている）"
pass "fixture が対象 DB を汚していない"

# ---- 7. detect a real violation ---------------------------------------------
ctx "UPDATE app.policy_versions SET body_md = body_md || E'\n（動かした）'
      WHERE id = (SELECT id FROM app.policy_versions ORDER BY id LIMIT 1)" >/dev/null
ISMS_DB="$DB" ISMS_CHECKER_VERIFY_DB="$VERIFY_DB" \
  checker --token "$TOKEN" --verification-receipt-id "$(receipt)" || true
R=$(ctx "SELECT result FROM app.check_runs WHERE check_key='CHK-CORE-POLICY-003'
          ORDER BY started_at DESC LIMIT 1" | tail -1)
[ "$R" = "fail" ] || die "違反を作ったのに $R（fail のはず）"
pass "実際の違反を fail として検出する"
F=$(ctx "SELECT status||':'||(assigned_to IS NOT NULL) FROM app.findings
          WHERE check_key='CHK-CORE-POLICY-003' ORDER BY detected_at DESC LIMIT 1" | tail -1)
[ "$F" = "detected:true" ] || die "fail から finding が起票・割当されていない: $F"
pass "fail から finding を起票し、担当者へ割り当てる"

ctx "UPDATE app.policy_versions pv SET body_md = d.body_md
       FROM app.policies p JOIN catalog.policies_default d ON d.key = p.catalog_key
      WHERE pv.policy_id = p.id AND pv.tenant_id = p.tenant_id" >/dev/null
ISMS_DB="$DB" ISMS_CHECKER_VERIFY_DB="$VERIFY_DB" \
  checker --token "$TOKEN" --verification-receipt-id "$(receipt)" \
  || die "違反を戻したのに checker が非ゼロ"
R=$(ctx "SELECT result FROM app.check_runs WHERE check_key='CHK-CORE-POLICY-003'
          ORDER BY started_at DESC LIMIT 1" | tail -1)
[ "$R" = "pass" ] || die "違反を戻したのに $R（pass のはず）"
pass "違反を直すと pass に戻る"
F=$(ctx "SELECT status FROM app.findings WHERE check_key='CHK-CORE-POLICY-003'
          ORDER BY detected_at DESC LIMIT 1" | tail -1)
[ "$F" = "retest_passed" ] || die "復旧後の finding が retest_passed ではない: $F"
pass "復旧後は retest_passed へ進み closed にはしない"

# ---- 7. fingerprint verification (DB trigger) ------------------------------
# An arbitrary 64-digit value cannot claim "verified".
OUT=$(psql -d "$DB" -v ON_ERROR_STOP=0 2>&1 <<SQL || true
BEGIN;
SELECT app.set_tenant_context('$TOKEN');
INSERT INTO app.check_runs (tenant_id, check_key, started_at, result,
                            negative_verified, verified_digest, verification_receipt_id)
  SELECT app.current_tenant(), 'CHK-CORE-ROLE-001', now(), 'pass', true,
         repeat('a', 64), '$RECEIPT_ID'::uuid;
ROLLBACK;
SQL
)
case "$OUT" in
  *"いまのカタログが一致しません"*) pass "でたらめな指紋では確認済みを名乗れない" ;;
  *) die "でたらめな指紋が通ってしまった: $OUT" ;;
esac

# If a check's content is rewritten after verification, that fingerprint no longer passes.
D=$(psql -Atq -d "$DB" -c "SELECT catalog.check_digest('CHK-CORE-ROLE-001')")
PGUSER="$ADMIN_PGUSER" psql -q -d "$DB" -c "SET ROLE schema_owner; UPDATE catalog.checks
  SET expect = '{\"max_violations\": 5}'::jsonb WHERE key='CHK-CORE-ROLE-001'" >/dev/null
OUT=$(psql -d "$DB" -v ON_ERROR_STOP=0 2>&1 <<SQL || true
BEGIN;
SELECT app.set_tenant_context('$TOKEN');
INSERT INTO app.check_runs (tenant_id, check_key, started_at, result,
                            negative_verified, verified_digest, verification_receipt_id)
  SELECT app.current_tenant(), 'CHK-CORE-ROLE-001', now(), 'pass', true, '$D',
         '$RECEIPT_ID'::uuid;
ROLLBACK;
SQL
)
case "$OUT" in
  *"いまのカタログが一致しません"*) pass "中身を書き換えると前の確認は通らない" ;;
  *) die "書き換え後も前の指紋が通ってしまった: $OUT" ;;
esac

printf '\033[32mchecker: 全て緑\033[0m\n'
