#!/usr/bin/env bash
# Apply and roll back migrations.
#
#   scripts/migrate.sh up            apply all pending
#   scripts/migrate.sh down [N]      roll back the latest N (default 1)
#   scripts/migrate.sh down all      roll back everything
#   scripts/migrate.sh status        show status
#
# Target is DATABASE_URL (default postgres:///isms_dev).
# Each file runs in one transaction. If it fails, none of that file's changes remain.
#
# Executing role:
#   If the file starts with `-- @run-as: admin`, it runs as the connecting user (superuser).
#   Otherwise it runs after `SET ROLE schema_owner`, to pin the owner to schema_owner.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGDIR="$ROOT/db/migrations"
DB_URL="${DATABASE_URL:-postgres:///${ISMS_DB:-isms_dev}}"

# -w: never prompt for a password. A connection lacking credentials fails immediately instead of hanging
# (in an unattended deploy psql waited for a password and the acceptance tests stalled for 30 minutes, 2026-09-13).
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

# Prevent concurrent runs (seeds use the same lock number)
LOCK_ID=8891234501

version_of() { basename "$1" | sed -E 's/^([0-9]+)_.*/\1/'; }

applied_versions() {
  psql_run -At -c "SELECT version FROM public.schema_migrations ORDER BY version" 2>/dev/null || true
}

checksum_of() { shasum -a 256 "$1" | awk '{print $1}'; }

verify_checksums() {
  # Check that applied migration files have not been rewritten afterwards.
  # Looking only at version would silently skip rewritten content as "already applied".
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
  # down files are also recorded in the ledger and checked for rewrites after applying.
  # Verifying only up is pointless if the rollback content has been swapped.
  local bad=0 v c
  while IFS='|' read -r v c; do
    [ -z "${v:-}" ] && continue
    local f; f=$(ls "$MIGDIR/${v}"_*.down.sql 2>/dev/null | head -1)
    if [ -z "$f" ]; then
      printf '\033[31m[migrate] 適用済み %s の down ファイルが見つかりません\033[0m\n' "$v" >&2
      bad=1; continue
    fi
    [ -z "${c:-}" ] && continue     # old records (no down_checksum recorded) pass through
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
  # Guard against concurrent runs. After taking the lock, confirm inside the transaction that
  # it is still unapplied. The list of targets is read outside the lock, so without re-checking here
  # two processes would try to run the same migration twice.
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
  # Put lock → re-check → role switch → body → ledger update in one transaction.
  # If the ledger update is not in the same transaction, a half-done state
  # "the DDL succeeded but it is not in the ledger" can occur.
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
  verify_checksums          # detect tampering of up files before down as well
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
