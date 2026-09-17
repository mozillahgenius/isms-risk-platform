#!/usr/bin/env bash
# マイグレーション適用・巻き戻し。
#
#   scripts/migrate.sh up            未適用を全て適用
#   scripts/migrate.sh down [N]      直近 N 個（既定 1）を巻き戻す
#   scripts/migrate.sh down all      全て巻き戻す
#   scripts/migrate.sh status        適用状況
#
# 接続先は DATABASE_URL（既定 postgres:///isms_dev）。
# 各ファイルは 1 トランザクションで流す。失敗したらそのファイルの変更は残らない。
#
# 実行ロール:
#   ファイル先頭に `-- @run-as: admin` があれば接続ユーザー（superuser）のまま。
#   無ければ `SET ROLE schema_owner` して流す。所有者を schema_owner に固定するため。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGDIR="$ROOT/db/migrations"
DB_URL="${DATABASE_URL:-postgres:///${ISMS_DB:-isms_dev}}"

# -w: パスワードを聞かない。資格情報が足りない接続は、止まらずにすぐ落とす
# （無人の配備で psql がパスワードの入力を待ち、受入試験が30分止まった。2026-09-13）。
psql_run() { psql -w -v ON_ERROR_STOP=1 -q "$DB_URL" "$@"; }

die() { printf '\033[31m[migrate] %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '[migrate] %s\n' "$*"; }

ensure_table() {
  psql_run -c "CREATE TABLE IF NOT EXISTS public.schema_migrations (
                 version    text        PRIMARY KEY,
                 applied_at timestamptz NOT NULL DEFAULT now(),
                 checksum   text        NOT NULL
               )" >/dev/null
  psql_run -c "ALTER TABLE public.schema_migrations
                 ADD COLUMN IF NOT EXISTS down_checksum text" >/dev/null
}

# 同時実行を防ぐ（seed も同じロック番号を使う）
LOCK_ID=8891234501

version_of() { basename "$1" | sed -E 's/^([0-9]+)_.*/\1/'; }

applied_versions() {
  psql_run -At -c "SELECT version FROM public.schema_migrations ORDER BY version" 2>/dev/null || true
}

checksum_of() { shasum -a 256 "$1" | awk '{print $1}'; }

verify_checksums() {
  # 適用済みの migration ファイルが後から書き換えられていないか確かめる。
  # version だけを見ていると、中身を書き換えても「適用済み」として黙って飛ばす。
  local bad=0 v c
  while IFS='|' read -r v c; do
    [ -z "${v:-}" ] && continue
    local f; f=$(ls "$MIGDIR/${v}"_*.up.sql 2>/dev/null | head -1)
    if [ -z "$f" ]; then
      printf '\033[31m[migrate] 適用済み %s の up ファイルが見つかりません\033[0m\n' "$v" >&2
      bad=1; continue
    fi
    local now; now=$(checksum_of "$f")
    if [ "$now" != "$c" ]; then
      printf '\033[31m[migrate] 適用済み %s の中身が変わっています\033[0m\n' "$v" >&2
      printf '           記録 %s\n           実測 %s\n' "$c" "$now" >&2
      printf '           適用済み migration は書き換えず、新しい番号を足してください。\n' >&2
      bad=1
    fi
  done < <(psql_run -At -F'|' -c \
      "SELECT version, checksum FROM public.schema_migrations ORDER BY version" 2>/dev/null || true)
  [ "$bad" -eq 0 ] || die "適用済み migration の改変を検知しました"
}

verify_down_checksums() {
  # down ファイルも台帳へ記録し、適用後に書き換えられていないか確かめる。
  # up だけ検証しても、巻き戻しの中身が差し替えられていれば意味が無い。
  local bad=0 v c
  while IFS='|' read -r v c; do
    [ -z "${v:-}" ] && continue
    local f; f=$(ls "$MIGDIR/${v}"_*.down.sql 2>/dev/null | head -1)
    if [ -z "$f" ]; then
      printf '\033[31m[migrate] 適用済み %s の down ファイルが見つかりません\033[0m\n' "$v" >&2
      bad=1; continue
    fi
    [ -z "${c:-}" ] && continue     # 旧レコード（down_checksum 未記録）は素通し
    local now; now=$(checksum_of "$f")
    if [ "$now" != "$c" ]; then
      printf '\033[31m[migrate] 適用済み %s の down が変わっています\033[0m\n' "$v" >&2
      printf '           記録 %s\n           実測 %s\n' "$c" "$now" >&2
      bad=1
    fi
  done < <(psql_run -At -F'|' -c \
      "SELECT version, coalesce(down_checksum,'') FROM public.schema_migrations
        ORDER BY version" 2>/dev/null || true)
  [ "$bad" -eq 0 ] || die "適用済み down ファイルの改変を検知しました"
}

run_file() {
  local f="$1" direction="$2" version="$3"
  local role_line guard
  if head -1 "$f" | grep -q '@run-as: admin'; then
    role_line=""
  else
    role_line="SET ROLE schema_owner;"
  fi
  # 同時実行への備え。ロックを取った後に「まだ未適用か」をトランザクション内で
  # 確かめる。適用対象の一覧はロックの外で読んでいるので、ここで再確認しないと
  # 2 つのプロセスが同じ migration を二重に流そうとする。
  if [ "$direction" = "up" ]; then
    guard=$(printf "DO \$mig\$ BEGIN
      IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = '%s') THEN
        RAISE EXCEPTION 'ALREADY_APPLIED';
      END IF;
    END \$mig\$;" "$version")
  else
    guard=$(printf "DO \$mig\$ BEGIN
      IF NOT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = '%s') THEN
        RAISE EXCEPTION 'ALREADY_APPLIED';
      END IF;
    END \$mig\$;" "$version")
  fi
  info "$direction $version  $(basename "$f")"
  # ロック → 再確認 → ロール切替 → 本体 → 台帳更新 を 1 トランザクションに入れる。
  # 台帳更新を同一トランザクションにしないと「DDL は通ったが台帳に載っていない」
  # 中途半端な状態が起きる。
  local out rc
  out=$({
    echo "BEGIN;"
    echo "SELECT pg_advisory_xact_lock($LOCK_ID);"
    echo "$guard"
    echo "$role_line"
    cat "$f"
    echo ";"
    echo "RESET ROLE;"
    if [ "$direction" = "up" ]; then
      local down_f down_c
      down_f=$(ls "$MIGDIR/${version}"_*.down.sql 2>/dev/null | head -1)
      down_c=$([ -n "$down_f" ] && checksum_of "$down_f" || echo '')
      printf "INSERT INTO public.schema_migrations (version, checksum, down_checksum)
              VALUES ('%s', '%s', %s);\n" \
        "$version" "$(checksum_of "$f")" \
        "$([ -n "$down_c" ] && printf "'%s'" "$down_c" || echo NULL)"
    else
      printf "DELETE FROM public.schema_migrations WHERE version = '%s';\n" "$version"
    fi
    echo "COMMIT;"
  } | psql_run -f - 2>&1) || rc=$?
  if [ "${rc:-0}" -ne 0 ]; then
    if grep -q 'ALREADY_APPLIED' <<<"$out"; then
      info "  → 他のプロセスが先に処理済み。飛ばします"
      return 0
    fi
    printf '%s\n' "$out" >&2
    die "$direction $version が失敗しました"
  fi
}

cmd_up() {
  ensure_table
  verify_checksums
  local applied; applied=$(applied_versions)
  local ran=0
  for f in "$MIGDIR"/*.up.sql; do
    [ -e "$f" ] || die "マイグレーションが 1 つもありません: $MIGDIR"
    local v; v=$(version_of "$f")
    if grep -qx "$v" <<<"$applied"; then continue; fi
    run_file "$f" up "$v"
    ran=$((ran + 1))
  done
  [ "$ran" -eq 0 ] && info "適用済み（新規なし）"
  cmd_status
}

cmd_down() {
  ensure_table
  verify_checksums          # down の前にも up ファイルの改変を検知する
  verify_down_checksums
  local n="${1:-1}"
  local versions; versions=$(psql_run -At -c \
    "SELECT version FROM public.schema_migrations ORDER BY version DESC")
  [ -z "$versions" ] && { info "巻き戻す対象がありません"; return; }
  local count=0
  while read -r v; do
    [ -z "$v" ] && continue
    if [ "$n" != "all" ] && [ "$count" -ge "$n" ]; then break; fi
    local f; f=$(ls "$MIGDIR/${v}"_*.down.sql 2>/dev/null | head -1)
    [ -n "$f" ] || die "down が見つかりません: $v"
    run_file "$f" down "$v"
    count=$((count + 1))
  done <<<"$versions"
  cmd_status
}

cmd_status() {
  ensure_table
  local total applied
  total=$(ls "$MIGDIR"/*.up.sql 2>/dev/null | wc -l | tr -d ' ')
  applied=$(psql_run -At -c "SELECT count(*) FROM public.schema_migrations")
  info "適用 $applied / 全 $total  (${DB_URL})"
  verify_checksums
}

case "${1:-up}" in
  up)     cmd_up ;;
  down)   cmd_down "${2:-1}" ;;
  status) cmd_status ;;
  *)      die "使い方: migrate.sh {up|down [N|all]|status}" ;;
esac
