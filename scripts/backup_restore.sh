#!/usr/bin/env bash
# Production DB backup and restore.
#
#   scripts/backup_restore.sh backup [output dir]   take a backup with pg_dump -Fc (default ~/backups/isms-platform)
#   scripts/backup_restore.sh restore <dump file> <target DB name>  restore into the given DB (refused if the DB exists, to prevent mix-ups)
#   scripts/backup_restore.sh verify  [output dir]   check that the latest backup can actually be restored into a throwaway DB
#
# Connection follows the same convention as scripts/migrate.sh: DATABASE_URL (default postgres:///isms_dev;
# ISMS_DB overrides just the DB name). If DATABASE_URL were ignored in favor of a fixed local DB,
# someone who sets only DATABASE_URL, expecting migrate.sh behavior, would unknowingly operate on the local
# isms_dev (Codex review 2026-09-02 finding).
#
# Added in response to the point that "a backup that has never been test-restored is not a backup".
# The verify subcommand actually restores the latest dump made by backup into a separate DB,
# and confirms that the schema_migrations version count matches the source.
set -euo pipefail

ISMS_DB="${ISMS_DB:-isms_dev}"
DB_URL="${DATABASE_URL:-postgres:///${ISMS_DB}}"
DEFAULT_DIR="$HOME/backups/isms-platform"

die() { printf '\033[31m[backup] %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '[backup] %s\n' "$*"; }

# Label used for file names and lookup keys. Prefer the last segment (dbname) of DATABASE_URL,
# falling back to ISMS_DB. Fixing it to ISMS_DB would make file names disagree with reality when
# DATABASE_URL points to another DB or environment (Codex review 2026-09-02 finding).
db_label() {
  # Strip the query string (?user=app_ro etc.) and fragment first, then take dbname after the last
  # "/". Splitting on "/" first would, when a query value itself contains "/"
  # (e.g. ?sslrootcert=/tmp/ca.pem), turn the tail of the query into the label instead of the dbname
  # (Codex review 2026-09-02 finding; this repository itself uses the
  # postgres:///isms_dev?user=app_ro form = ISMS_WEB_DATABASE_URL etc.).
  local seg="${DB_URL%%\?*}"
  seg="${seg%%#*}"
  seg="${seg##*/}"
  printf '%s' "${seg:-$ISMS_DB}"
}

cmd_backup() {
  local dir="${1:-$DEFAULT_DIR}"
  mkdir -p "$dir"
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  local out="$dir/$(db_label)-${ts}-$$.dump"
  # Not local: the EXIT trap can fire after cmd_backup has returned (at script exit).
  # With local, the variable is out of scope at that point and
  # it fails with "unbound variable" (the cleanup function itself doesn't run).
  tmp="${out}.tmp.$$"
  # Write to a temp file and mv to the real file name only on success (atomic rename).
  # Writing directly to the real file would leave an incomplete dump if pg_dump is interrupted,
  # and verify would pick it up as "the latest backup" (Codex review 2026-09-02 finding).
  # Include $$ in the file name too, so multiple runs in the same second don't collide.
  #
  # Pass a function to trap rather than string-expanding the path (shell-injection countermeasure;
  # Codex review 2026-09-02 finding: if $dir contains single quotes or newlines,
  # the string-expanded version of the trap can be broken).
  cleanup_tmp() { rm -f -- "$tmp"; }
  trap cleanup_tmp EXIT
  pg_dump "$DB_URL" -Fc -f "$tmp"
  mv -- "$tmp" "$out"
  trap - EXIT
  local size; size=$(du -h "$out" | cut -f1)
  info "作成: $out ($size)"
}

cmd_restore() {
  local dump="${1:?dumpファイルを指定してください}"
  local target="${2:?復旧先DB名を指定してください}"
  [ -f "$dump" ] || die "dumpが見つかりません: $dump"
  if psql -lqt | cut -d'|' -f1 | grep -qw "$target"; then
    die "復旧先DB '$target' は既に存在します。取り違え防止のため上書きしません。先に dropdb するか別名を指定してください"
  fi
  createdb "$target"
  pg_restore -d "$target" --no-owner --no-privileges "$dump"
  info "復旧完了: $target"
}

cmd_verify() {
  local dir="${1:-$DEFAULT_DIR}"
  local latest; latest=$(ls -t "$dir"/"$(db_label)"-*.dump 2>/dev/null | head -1)
  [ -n "$latest" ] || die "$dir にバックアップがありません。先に backup を実行してください"
  info "検証対象: $latest"
  # Not local: same reason as tmp in cmd_backup (if out of scope when the EXIT trap
  # fires, it fails with unbound variable).
  verify_db="isms_backup_verify_$$"
  # Set the EXIT trap only after createdb succeeds. If set earlier, when a same-named DB
  # already exists (e.g. due to PID reuse) and createdb fails, the trap would
  # dropdb that existing DB (Codex review 2026-09-02 finding). Pass a function to trap
  # (shell-injection countermeasure against string expansion; same reason as cmd_backup).
  createdb "$verify_db"
  cleanup_verify_db() { dropdb --if-exists -- "$verify_db"; }
  trap cleanup_verify_db EXIT
  pg_restore -d "$verify_db" --no-owner --no-privileges "$latest"
  local restored_versions source_versions
  restored_versions=$(psql -At -d "$verify_db" -c "SELECT count(*) FROM public.schema_migrations" 2>&1) \
    || die "復旧先で schema_migrations を読めません(復旧失敗の可能性)"
  source_versions=$(psql -At "$DB_URL" -c "SELECT count(*) FROM public.schema_migrations" 2>&1)
  [ "$restored_versions" = "$source_versions" ] \
    || die "版数が一致しません(復旧元 $source_versions / 復旧先 $restored_versions)"
  info "検証OK: 復旧先の適用済みマイグレーション数が復旧元と一致(${restored_versions}件)"
}

case "${1:-}" in
  backup)  shift; cmd_backup "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  verify)  shift; cmd_verify "$@" ;;
  *) die "使い方: $0 backup [dir] | restore <dump> <db名> | verify [dir]" ;;
esac
