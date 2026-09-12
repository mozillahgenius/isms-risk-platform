#!/usr/bin/env bash
# Run the acceptance tests (rls_test / domain_test) on a **throwaway DB**.
#
# Why separate them:
#   These tests add rows to both catalog (= the projection of Git) and app. They need FK targets, so
#   inserting into catalog is correct by design. The problem was **running them on the shared isms_dev**.
#   domain_test's TEST-FW / T.1 (theme NULL) actually remained in isms_dev,
#   and later the UI's /graph returned 500. The control count was also off by one from the seed.
#
#   Adding cleanup is not enough. The tests delete audit.audit_log, app.risk_criteria is
#   history and cannot be deleted, and rls_test leaves fixtures at the end. "Throwing away" is more
#   reliable than "restoring", and needs only one way of verifying.
#
# What it checks:
#   1. All tests pass
#   2. **The shared DB ($ISMS_DB, default isms_dev) has not changed by a single row between before and after the tests**
#      - compares catalog key sets and contents by hash. This is the invariant that broke this time.
#
# Where we err on the safe side:
#   - **Do not run if the throwaway DB ($ISMS_TEST_DB, default isms_test_<pid>) already exists**.
#     It is DROPped at the end, so do not create a path that deletes someone else's DB
#   - Do not run if it has the same name as the shared DB
#   - Print the connection target (host / port) first, to make creation on an unintended cluster visible
#   - If a fingerprint cannot be taken, **fail instead of skipping** (do not read "could not take" as "unchanged")
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED="${ISMS_DB:-isms_dev}"
DB="${ISMS_TEST_DB:-isms_test_$$}"

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
die() { red "[test] $*"; exit 1; }

# If DATABASE_URL is set, migrate.sh and the tests connect there. Specify the throwaway DB explicitly.
# Do not unset PGHOST / PGPORT / PGSERVICE (pointing at another cluster can be a legitimate setting).
# Instead, print where we are connected.
unset DATABASE_URL || true

db_exists() { # $1 = dbname
  local n
  n=$(psql -At -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$1'" 2>/dev/null) || return 2
  [ "$n" = "1" ]
}

# Fingerprint of catalog. Counts alone let "added 1 row and deleted 1 row" pass.
# md5 the contents of every table and list them with table names. **Do not swallow failures.**
fingerprint() { # $1 = dbname
  psql -At -d "$1" -v ON_ERROR_STOP=1 <<'SQL'
SELECT coalesce(string_agg(t || ' ' || h, E'\n' ORDER BY t), '(catalog にテーブルが無い)')
FROM (
  SELECT c.relname AS t,
         (xpath('/row/c/text()',
                query_to_xml(
                  format('SELECT md5(coalesce(string_agg(x::text, E''\n'' ORDER BY x::text), ''''))'
                         || ' AS c FROM %I.%I x', n.nspname, c.relname),
                  false, true, '')))[1]::text AS h
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'catalog' AND c.relkind = 'r'
) s;
SQL
}

# Delete only if this run created it. If we fail before creating, do nothing.
CREATED=0
cleanup() {
  local rc=$?
  if [ "$CREATED" = "1" ]; then
    if ! dropdb --if-exists "$DB" >/dev/null 2>&1; then
      red "[test] 使い捨て DB ${DB} を消せませんでした。手動で dropdb してください"
      [ "$rc" -eq 0 ] && rc=1
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
# Interrupts exit with the conventional exit code. The EXIT trap runs once and cleans up.
trap 'exit 130' INT
trap 'exit 143' TERM

# Over a Unix socket, both inet_server_addr() and inet_server_port() are NULL.
# If either is NULL the whole concatenation becomes NULL and the connection target shows as blank.
CONN=$(psql -At -d postgres -c \
  "SELECT coalesce(inet_server_addr()::text, 'unix') || ':' || coalesce(inet_server_port()::text, current_setting('port'))" \
  2>/dev/null) || die "PostgreSQL へ繋げませんでした（psql -d postgres）"
[ -n "$CONN" ] || CONN='(不明)'
echo "== 受入試験（接続先 ${CONN}／使い捨て DB: ${DB}／共有 DB: ${SHARED} は触らない） =="

# The throwaway DB is DROPped at the end. If it points at an existing DB, that DB would be deleted.
[ "$DB" != "$SHARED" ] || die "使い捨て DB 名が共有 DB と同じです（${DB}）。DROP するので実行しません"
db_exists "$DB"; ex=$?
case "$ex" in
  0) die "使い捨て DB ${DB} は既に在ります。DROP するので実行しません（ISMS_TEST_DB を変えてください）" ;;
  1) : ;;
  *) die "使い捨て DB ${DB} の存在を確認できませんでした" ;;
esac

# "Before" fingerprint of the shared DB. If it does not exist, skip the check (what does not exist cannot be polluted).
# If it exists but cannot be fingerprinted, **fail instead of skipping**.
db_exists "$SHARED"; ex=$?
case "$ex" in
  0) SHARED_PRESENT=1 ;;
  1) SHARED_PRESENT=0 ;;
  *) die "共有 DB ${SHARED} の存在を確認できませんでした" ;;
esac
if [ "$SHARED_PRESENT" = "1" ]; then
  SHARED_BEFORE="$(fingerprint "$SHARED")" \
    || die "共有 DB ${SHARED} の指紋を採れませんでした（採れないことを『変わっていない』と読まない）"
  [ -n "$SHARED_BEFORE" ] || die "共有 DB ${SHARED} の指紋が空です"
fi

createdb "$DB" || die "DB を作れませんでした: $DB"
CREATED=1

export ISMS_DB="$DB"
SNAPSHOT_DIR="$ROOT/db/seeds/snapshots"

(cd "$SNAPSHOT_DIR" && shasum -a 256 -c SHA256SUMS) >/dev/null \
  || die "seed（CSV snapshot）の SHA-256 検証が失敗"

"$ROOT/scripts/migrate.sh" up >/dev/null 2>&1 || die "migration の適用が失敗"
# RLS quality gate. Until now it ran only inside agent_acceptance_test.sh, so changes to the check never ran in this acceptance test
# (found 2026-09-12; we missed that the check of permission functions with no identified user fails on a plain connection).
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/scripts/ci/check_rls.sql" >/dev/null || die "RLS の品質ゲート（check_rls.sql）が落ちた"

psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null \
  || die "seed（DOM）が失敗"
python3 "$ROOT/db/seeds/load_csv.py" --scripts-dir "$SNAPSHOT_DIR" >/dev/null \
  || die "seed（CSV snapshot）が失敗"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0002_checks_core.sql" >/dev/null \
  || die "seed（チェック）が失敗"

rc=0
"$ROOT/tests/rls_test.sh"    || rc=1
"$ROOT/tests/domain_test.sh" || rc=1
"$ROOT/tests/isms_risk_read_model.sh" || rc=1
ISMS_TEST_DB="${DB}_management_workflows" "$ROOT/tests/management_workflows.sh" || rc=1
ISMS_TEST_DB="${DB}_0046_reverse" "$ROOT/tests/management_0046_reverse_fixture.sh" || rc=1
ISMS_TEST_DB="${DB}_isms_records" "$ROOT/tests/isms_records.sh" || rc=1
ISMS_TEST_DB="${DB}_isms_registers" "$ROOT/tests/isms_registers.sh" || rc=1

echo
echo "-- 共有 DB を汚していないこと（今回壊れた不変条件。壊すと落ちる）"
if [ "$SHARED_PRESENT" = "0" ]; then
  ylw "  SKIP 共有 DB ${SHARED} が無いので比較しない"
else
  SHARED_AFTER="$(fingerprint "$SHARED")" \
    || die "共有 DB ${SHARED} の指紋を採れませんでした（試験の後）"
  if [ "$SHARED_BEFORE" = "$SHARED_AFTER" ]; then
    grn "  PASS ${SHARED} の catalog は試験の前後で 1 行も変わっていない"
  else
    red "  FAIL ${SHARED} の catalog が試験で書き換わった（試験は使い捨て DB だけを触るはず）"
    diff <(printf '%s\n' "$SHARED_BEFORE") <(printf '%s\n' "$SHARED_AFTER") | sed 's/^/    /' >&2
    rc=1
  fi
fi

[ "$rc" -eq 0 ] || die "受入試験が失敗"
grn "受入試験: 全て緑（使い捨て DB は破棄した）"
