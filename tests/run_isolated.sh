#!/usr/bin/env bash
# 受入試験（rls_test / domain_test）を**使い捨ての DB**で走らせる。
#
# なぜ分けるか:
#   これらの試験は catalog（＝ Git の投影）にも app にも行を足す。FK の相手が要るので
#   catalog へ入れるのは設計上正しい。問題は、それを**共有の isms_dev で流していた**こと。
#   実際に domain_test の TEST-FW / T.1（theme が NULL）が isms_dev に残り、
#   後から画面の /graph が 500 になった。統制の件数も 304 → 305 にずれていた。
#
#   後始末を足すだけでは足りない。試験は audit.audit_log を消し、app.risk_criteria は
#   履歴なので消せず、rls_test は最後に fixture を残す。「元へ戻す」より
#   「使い捨てる」方が確実で、確かめ方も 1 つで済む。
#
# 見るもの:
#   1. 試験が全て通る
#   2. **共有 DB（$ISMS_DB、既定 isms_dev）が試験の前後で 1 行も変わっていない**
#      — catalog のキー集合と内容をハッシュで突合する。これが今回壊れた不変条件。
#
# 安全側に倒していること:
#   - 使い捨て DB（$ISMS_TEST_DB、既定 isms_test_<pid>）が**既に在るなら実行しない**。
#     最後に DROP するので、他人の DB を消す経路を作らない
#   - 共有 DB と同名でも実行しない
#   - 接続先（host / port）を最初に表示する。意図しないクラスタで作ってしまうのを見えるようにする
#   - 指紋が取れなかったら**飛ばさずに落とす**（取れないことを「変わっていない」と読まない）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED="${ISMS_DB:-isms_dev}"
DB="${ISMS_TEST_DB:-isms_test_$$}"

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
die() { red "[test] $*"; exit 1; }

# DATABASE_URL が居ると migrate.sh もテストもそちらへ繋ぐ。使い捨て DB を明示する。
# PGHOST / PGPORT / PGSERVICE は消さない（別クラスタを指すのは正当な設定であり得る）。
# 代わりに、どこへ繋いでいるかを表示する。
unset DATABASE_URL || true

db_exists() { # $1 = dbname
  local n
  n=$(psql -At -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$1'" 2>/dev/null) || return 2
  [ "$n" = "1" ]
}

# catalog の指紋。件数だけでは「1 行足して 1 行消した」が素通りする。
# 全テーブルの中身を md5 にして、テーブル名つきで並べる。**失敗は握り潰さない。**
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

# この実行で作った時だけ消す。作る前に落ちたら何もしない。
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
# 割り込みは既定の終了コードで抜ける。EXIT トラップが 1 度だけ走って後始末する。
trap 'exit 130' INT
trap 'exit 143' TERM

# Unix ソケット接続では inet_server_addr() も inet_server_port() も NULL になる。
# 片方でも NULL だと連結ごと NULL になり、接続先が空欄で表示されてしまう。
CONN=$(psql -At -d postgres -c \
  "SELECT coalesce(inet_server_addr()::text, 'unix') || ':' || coalesce(inet_server_port()::text, current_setting('port'))" \
  2>/dev/null) || die "PostgreSQL へ繋げませんでした（psql -d postgres）"
[ -n "$CONN" ] || CONN='(不明)'
echo "== 受入試験（接続先 ${CONN}／使い捨て DB: ${DB}／共有 DB: ${SHARED} は触らない） =="

# 使い捨て DB は最後に DROP する。既存の DB を指していたら消してしまう。
[ "$DB" != "$SHARED" ] || die "使い捨て DB 名が共有 DB と同じです（${DB}）。DROP するので実行しません"
db_exists "$DB"; ex=$?
case "$ex" in
  0) die "使い捨て DB ${DB} は既に在ります。DROP するので実行しません（ISMS_TEST_DB を変えてください）" ;;
  1) : ;;
  *) die "使い捨て DB ${DB} の存在を確認できませんでした" ;;
esac

# 共有 DB の「前」の指紋。存在しなければ検査を飛ばす（無いものは汚せない）。
# 存在するのに取れない場合は**飛ばさずに落とす**。
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
# RLS の品質ゲート。これまで agent_acceptance_test.sh の中でしか流れず、この受入試験では検査の変更が一度も実行されていなかった
# （2026-09-12 に判明。本人不明の許可関数の検査が素の接続で落ちるのを見逃した）。
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/scripts/ci/check_rls.sql" >/dev/null || die "RLS の品質ゲート（check_rls.sql）が落ちた"

psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null \
  || die "seed（DOM）が失敗"
python3 "$ROOT/db/seeds/load_csv.py" --scripts-dir "$SNAPSHOT_DIR" >/dev/null \
  || die "seed（CSV snapshot）が失敗"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0002_checks_core.sql" >/dev/null \
  || die "seed（チェック）が失敗"

rc=0
"$ROOT/tests/down_guard_messages_test.sh" || rc=1
"$ROOT/tests/rls_test.sh"    || rc=1
"$ROOT/tests/domain_test.sh" || rc=1
"$ROOT/tests/isms_risk_read_model.sh" || rc=1
"$ROOT/tests/analysis_isms_scope.sh" || rc=1
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
