#!/usr/bin/env bash
# 本番DBのバックアップ・復旧。
#
#   scripts/backup_restore.sh backup [出力先ディレクトリ]   pg_dump -Fc でバックアップを取る（既定 ~/backups/isms-platform）
#   scripts/backup_restore.sh restore <dumpファイル> <復旧先DB名>  指定DBへ復旧する（既存DBがあれば拒否。取り違え防止）
#   scripts/backup_restore.sh verify  [出力先ディレクトリ]   最新のバックアップを使い捨てDBへ実際に復旧できるか確かめる
#
# 接続先は scripts/migrate.sh と同じ規約: DATABASE_URL（既定 postgres:///isms_dev、
# ISMS_DB で DB 名だけ上書き可）。DATABASE_URL を無視してローカル固定にしていると、
# migrate.sh のつもりで DATABASE_URL だけ設定して実行した人が気づかずローカル
# isms_dev を操作してしまう(Codexレビュー2026-09-02指摘)。
#
# 「一度も復旧を試していないバックアップはバックアップではない」という指摘を受けて追加。
# verify サブコマンドは、backup が作った最新のダンプを実際に別DBへ復旧し、
# schema_migrations の版数が復旧元と一致することまで確認する。
set -euo pipefail

ISMS_DB="${ISMS_DB:-isms_dev}"
DB_URL="${DATABASE_URL:-postgres:///${ISMS_DB}}"
DEFAULT_DIR="$HOME/backups/isms-platform"

die() { printf '\033[31m[backup] %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '[backup] %s\n' "$*"; }

# ファイル名・検索キーに使うラベル。DATABASE_URL の末尾セグメント(dbname)を
# 優先し、無ければ ISMS_DB へ落とす。ISMS_DB 固定だと、DATABASE_URL が別DB・
# 別環境を指す場合にファイル名が実体と食い違う(Codexレビュー2026-09-02指摘)。
db_label() {
  # クエリ文字列(?user=app_ro等)・フラグメントを先に取り除いてから、最後の
  # "/" で dbname を取り出す。先に "/" 区切りをすると、クエリ値自体に "/" を
  # 含む場合(例: ?sslrootcert=/tmp/ca.pem)、dbnameではなくクエリ末尾を
  # ラベル化してしまう(Codexレビュー2026-09-02指摘、このリポジトリ自体は
  # postgres:///isms_dev?user=app_ro 形式を使う=ISMS_WEB_DATABASE_URL等)。
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
  # local にしない: EXIT トラップは cmd_backup が return した後(スクリプト終了時)
  # に発火しうる。local だとその時点で変数がスコープ外になり
  # 「unbound variable」で落ちる(cleanup 関数自体が動かない)。
  tmp="${out}.tmp.$$"
  # 一時ファイルへ書いてから成功時だけ本番ファイル名へ mv する(atomic rename)。
  # 直接本ファイルへ書くと、pg_dump が中断した際に不完全なダンプが残り、
  # verify がそれを「最新のバックアップ」として拾ってしまう(Codexレビュー2026-09-02指摘)。
  # 同一秒に複数回走らせても衝突しないよう、ファイル名にも $$ を含める。
  #
  # trap にパスを文字列展開せず関数を渡す(シェルインジェクション対策、
  # Codexレビュー2026-09-02指摘: $dir にシングルクォートや改行が含まれると
  # 文字列展開版のtrapは壊せてしまう)。
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
  # local にしない: cmd_backup の tmp と同じ理由(EXITトラップ発火時に
  # スコープ外だと unbound variable で落ちる)。
  verify_db="isms_backup_verify_$$"
  # createdb 成功後にだけ EXIT trap を張る。先に張ると、PID再利用等で同名DBが
  # 既に存在していて createdb が失敗した場合でも、trap がその既存DBを
  # dropdb してしまう(Codexレビュー2026-09-02指摘)。trapへは関数を渡す
  # (文字列展開によるシェルインジェクション対策、cmd_backupと同じ理由)。
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
