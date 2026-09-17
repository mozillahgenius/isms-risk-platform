#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASES="/opt/isms-platform/releases/isms"
CURRENT="$RELEASES/current"
LEGACY_RELEASE="/opt/isms-platform/Projects/isms-platform-release-vault"
BACKUP_ROOT="/opt/isms-platform/backups/isms-deploy"
SERVICE="isms-runtime.service"
ALLOWED_REF="origin/main"
DB_HOST="127.0.0.1"
DB_PORT="15432"
DB_NAME="isms_dev"
DB_ADMIN="postgres"
PG_DUMP="/usr/lib/postgresql/17/bin/pg_dump"
PG_RESTORE="/usr/lib/postgresql/17/bin/pg_restore"
EXPECTED_ORIGIN="${ISMS_EXPECTED_ORIGIN:-https://github.com/example-org/isms-platform.git}"

wait_http() {
  local url="$1"
  local attempt
  for attempt in $(seq 1 30); do
    if curl --connect-timeout 2 --max-time 5 --fail --silent "$url" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if [ "${1:-}" != "--apply" ] || [[ ! "${2:-}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "usage: deploy_runtime.sh --apply <40-hex-commit>" >&2
  exit 2
fi
COMMIT="$2"
if [ -n "${ISMS_DEPLOY_UID:-}" ] && [ "$(id -u)" != "$ISMS_DEPLOY_UID" ]; then
  echo "deploy is restricted to the configured deployment user" >&2
  exit 1
fi
if [ ! -x "$PG_DUMP" ] || [ ! -x "$PG_RESTORE" ] \
   || [[ "$("$PG_DUMP" --version)" != "pg_dump (PostgreSQL) 17."* ]] \
   || [[ "$("$PG_RESTORE" --version)" != "pg_restore (PostgreSQL) 17."* ]]; then
  echo "PostgreSQL 17 backup/restore clients are required" >&2
  exit 1
fi
if [ "$ROOT" != "/opt/isms-platform/Projects/isms-platform-deploy-control" ]; then
  echo "deploy wrapper must run from the clean RUNTIME deploy-control worktree" >&2
  exit 1
fi
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  echo "canonical source clone is not clean" >&2
  exit 1
fi
if [ "$(git -C "$ROOT" remote get-url origin)" != "$EXPECTED_ORIGIN" ]; then
  echo "unexpected origin remote" >&2
  exit 1
fi
if [ "$(systemctl --user show -p FragmentPath --value "$SERVICE")" \
     != "/opt/isms-platform/.config/systemd/user/isms-runtime.service" ]; then
  echo "unexpected ISMS service unit" >&2
  exit 1
fi
if ! systemctl --user cat "$SERVICE" | grep -Fqx 'ExecStart=/opt/isms-platform/bin/start-isms.sh'; then
  echo "unexpected ISMS service entrypoint" >&2
  exit 1
fi
NATIVE_DB_ENV="/opt/isms-platform/runtime-native-postgres.env"
if [ ! -f "$NATIVE_DB_ENV" ] || [ -L "$NATIVE_DB_ENV" ] \
   || [ "$(stat -c '%u:%a' "$NATIVE_DB_ENV")" != "1001:600" ]; then
  echo "native PostgreSQL credential file ownership or mode is invalid" >&2
  exit 1
fi
source "$NATIVE_DB_ENV"
if [ "${#PLATFORM_NATIVE_POSTGRES_PASSWORD}" -lt 32 ]; then
  echo "native PostgreSQL credential is missing" >&2
  exit 1
fi
export -n PLATFORM_NATIVE_POSTGRES_PASSWORD

mkdir -p /opt/isms-platform/.local/state "$BACKUP_ROOT" "$RELEASES"
chmod 700 /opt/isms-platform/.local/state "$BACKUP_ROOT" "$RELEASES"
exec 9>/opt/isms-platform/.local/state/isms-deploy.lock
if ! flock -n 9; then
  echo "another ISMS deployment is running" >&2
  exit 1
fi

git -C "$ROOT" fetch --prune origin main
git -C "$ROOT" cat-file -e "${COMMIT}^{commit}"
if [ "$(git -C "$ROOT" rev-parse "$ALLOWED_REF")" != "$COMMIT" ]; then
  echo "commit is not the fetched reviewed deployment ref tip" >&2
  exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
BACKUP="$BACKUP_ROOT/$STAMP"
NEW_RELEASE="$RELEASES/$COMMIT"
RESTORE_DB="isms_restore_${STAMP//[^0-9A-Za-z]/}"
CLEAN_FIXTURE_DB="isms_restore_clean_${STAMP//[^0-9A-Za-z]/}"
ISOLATED_DB="isms_test_deploy_${STAMP//[^0-9A-Za-z]/}"
mkdir "$BACKUP"
chmod 700 "$BACKUP"

if [ -L "$CURRENT" ]; then
  OLD_TARGET="$(readlink -f "$CURRENT")"
else
  OLD_TARGET="$LEGACY_RELEASE"
fi
cp -p /opt/isms-platform/bin/start-isms.sh "$BACKUP/start-isms.sh"
if [ -f /opt/isms-platform/target-env/isms-db-roles.env ]; then
  cp -p /opt/isms-platform/target-env/isms-db-roles.env "$BACKUP/isms-db-roles.env"
  HAD_ROLE_ENV=1
else
  HAD_ROLE_ENV=0
fi
RESTORE_CREATED=0
CLEAN_FIXTURE_CREATED=0
SWITCHED=0
APP_MUTATED=0
DB_MUTATION_STARTED=0
TEST_ROLE_PGPASS=""

rollback() {
  local rc=$?
  local recovery_ok=1
  trap - EXIT INT TERM HUP
  if [ -n "$TEST_ROLE_PGPASS" ] && [ -f "$TEST_ROLE_PGPASS" ] && [ ! -L "$TEST_ROLE_PGPASS" ]; then
    rm -f "$TEST_ROLE_PGPASS" || recovery_ok=0
  fi
  if [ "$RESTORE_CREATED" = "1" ]; then
    PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
      dropdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" --if-exists "$RESTORE_DB" \
      || recovery_ok=0
  fi
  if [ "$CLEAN_FIXTURE_CREATED" = "1" ]; then
    PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
      dropdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" --if-exists "$CLEAN_FIXTURE_DB" \
      || recovery_ok=0
  fi
  if [ "$rc" -ne 0 ]; then
    if [ "$DB_MUTATION_STARTED" = "0" ]; then
      if [ "$recovery_ok" = "1" ]; then
        echo "[deploy] pre-cutover gate failed; active application release was not switched" >&2
        exit "$rc"
      fi
      echo "[deploy] pre-cutover cleanup failed; manually remove $RESTORE_DB and inspect $BACKUP" >&2
      exit 70
    fi
    # Migration files commit independently.  Once the first production mutation
    # starts, the old release may no longer understand the DB and must never be
    # made active again.  Prefer the release that owns the new schema; if it
    # cannot start, stop rather than serving a known-incompatible application.
    install -m 700 "$NEW_RELEASE/ops/runtime/start-isms.sh" /opt/isms-platform/bin/start-isms.sh || recovery_ok=0
    ln -sfn "$NEW_RELEASE" "$RELEASES/current.recovery" || recovery_ok=0
    mv -Tf "$RELEASES/current.recovery" "$CURRENT" || recovery_ok=0
    if [ "$recovery_ok" = "1" ] \
       && systemctl --user restart "$SERVICE" \
       && systemctl --user is-active --quiet "$SERVICE" \
       && wait_http http://127.0.0.1:13110/; then
      echo "[deploy] DB mutation started; new release remains active for forward recovery (manual investigation required: $BACKUP)" >&2
    else
      systemctl --user stop "$SERVICE" || recovery_ok=0
      if systemctl --user is-active --quiet "$SERVICE"; then
        recovery_ok=0
      fi
      echo "[deploy] DB mutation started; service stopped. Do not activate $OLD_TARGET. Manual forward recovery is required: $BACKUP" >&2
      rc=70
    fi
  fi
  exit "$rc"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [ -d "$NEW_RELEASE" ]; then
  if [ "$(git -C "$NEW_RELEASE" rev-parse HEAD)" != "$COMMIT" ] \
     || [ -n "$(git -C "$NEW_RELEASE" status --porcelain)" ]; then
    echo "existing release directory is not the requested clean commit" >&2
    exit 1
  fi
else
  git -C "$ROOT" worktree add --detach "$NEW_RELEASE" "$COMMIT"
fi

GO_BIN="$("$ROOT/scripts/ensure_go_toolchain.sh" --print-path)"
export GO_BIN

npm --prefix "$NEW_RELEASE/web" ci
"$NEW_RELEASE/scripts/build-agent-artifacts.sh" "$NEW_RELEASE/agent-artifacts"
npm --prefix "$NEW_RELEASE/web" run typecheck
npm --prefix "$NEW_RELEASE/web" test
npm --prefix "$NEW_RELEASE/web" run build
TEST_ROLE_PGPASS="$BACKUP/isms-isolated.pgpass"
PLATFORM_NATIVE_POSTGRES_PASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
python3 "$NEW_RELEASE/scripts/configure_runtime_db_roles.py" \
  --pgpass-target "$TEST_ROLE_PGPASS" \
  --host "$DB_HOST" --port "$DB_PORT" \
  --source-database "$DB_NAME" --database "$ISOLATED_DB" \
  --admin-user "$DB_ADMIN" --admin-password-env PLATFORM_NATIVE_POSTGRES_PASSWORD
if [ -L "$TEST_ROLE_PGPASS" ] || [ "$(stat -c '%u:%a' "$TEST_ROLE_PGPASS")" != "1001:600" ]; then
  echo "isolated-test pgpass ownership or mode is invalid" >&2
  exit 1
fi
(
  unset PGPASSWORD
  PGPASSFILE="$TEST_ROLE_PGPASS" \
    PGHOST="$DB_HOST" PGPORT="$DB_PORT" PGUSER="$DB_ADMIN" ISMS_DB="$DB_NAME" \
    ISMS_TEST_DB="$ISOLATED_DB" \
    "$NEW_RELEASE/tests/run_isolated.sh"
)
rm -f "$TEST_ROLE_PGPASS"
TEST_ROLE_PGPASS=""

PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  "$PG_DUMP" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$DB_NAME" \
  --format=custom --file="$BACKUP/isms.dump"
chmod 600 "$BACKUP/isms.dump"
"$PG_RESTORE" --list "$BACKUP/isms.dump" >/dev/null
PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  createdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" "$RESTORE_DB"
RESTORE_CREATED=1
PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  "$PG_RESTORE" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$RESTORE_DB" \
  --clean --if-exists "$BACKUP/isms.dump"
PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$RESTORE_DB" \
  -v ON_ERROR_STOP=1 -At -c "SELECT count(*) FROM public.schema_migrations" >/dev/null
PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  DATABASE_URL="postgresql://$DB_ADMIN@$DB_HOST:$DB_PORT/$RESTORE_DB" \
  "$NEW_RELEASE/scripts/migrate.sh" up
PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$RESTORE_DB" \
  -v ON_ERROR_STOP=1 -At -c "SELECT count(*) FROM app.identity_principals" >/dev/null
if PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  psql -w -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$RESTORE_DB" \
  -v ON_ERROR_STOP=1 -c "SET ROLE app_ro; SELECT count(*) FROM app.identity_principals" >/dev/null 2>&1; then
  echo "restore rehearsal: app_ro bypassed tenant context" >&2
  exit 1
fi
if PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  psql -w -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$RESTORE_DB" \
  -v ON_ERROR_STOP=1 -c "SET ROLE app_rw; INSERT INTO app.identity_principals(tenant_id,provider,primary_email) VALUES(gen_random_uuid(),'google_workspace','forbidden@example.invalid')" >/dev/null 2>&1; then
  echo "restore rehearsal: app_rw directly wrote provider state" >&2
  exit 1
fi
# 巻き戻しの深さは **実測から数える**。ここを固定値で持つと、migration を
# 足すたびに目盛りがずれ、ゲートが守っているつもりの境界へ届かなくなる
# （実際 0053/0054 を足した時点で down 7 は 0045 ではなく 0047 で止まった）。
# 「境界より上に何段あるか」を数えて、その数だけ戻す。
# **数えられなかったことを「浅い」と混ぜない。** psql が落ちた・空を返した・
# 数値でない値を返したときに、そのまま比較へ流すと条件式がエラーになって
# 素通りし得る。取り出した値の形まで確かめ、駄目なら戻さずに落とす。
downs_above() { # $1=DB $2=境界のバージョン(4桁) -> 戻すべき段数
  local db="$1" boundary="$2" n
  [[ "$boundary" =~ ^[0-9]{4}$ ]] || {
    echo "downs_above: 境界の指定が 4 桁ではありません: ${boundary}" >&2; return 1; }
  # 値は psql 変数で渡す。文字列連結で SQL を組み立てない。
  # **-c では :'var' が展開されない**（psql の変数展開は stdin/ファイル入力だけ）。
  # -c に書くとサーバへ literal の :'boundary' が渡り syntax error になる。
  n=$(PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
      psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$db" \
      -v ON_ERROR_STOP=1 -At -v boundary="$boundary" <<'SQL'
SELECT count(*) FROM public.schema_migrations WHERE version > :'boundary';
SQL
      ) || { echo "downs_above: 段数を数えられませんでした（${db}）" >&2; return 1; }
  [[ "$n" =~ ^[0-9]+$ ]] || {
    echo "downs_above: 段数が数値になりません: ${n}" >&2; return 1; }
  printf '%s\n' "$n"
}

# リリースが持つ migration の最大版。**ここを固定値で書かない。**
# 「往復して元の高さへ戻ったか」の期待値は、その時のリリースの高さであって、
# 特定の版ではない（0052 と書いていたため 0053/0054 追加で配備が止まった）。
release_max_migration() { # $1=リリースのパス
  local v
  # ls の出力形式に依存しない（環境によって装飾が付く）。
  # 下の PENDING 算出と同じ find の形に揃える。
  v=$(find "$1/db/migrations" -maxdepth 1 -name '*.up.sql' -print 2>/dev/null \
      | sed -E 's#.*/([0-9]{4})_.*#\1#' | sort -u | tail -1)
  [[ "$v" =~ ^[0-9]{4}$ ]] || {
    echo "release_max_migration: 最大版を特定できません: ${v}" >&2; return 1; }
  printf '%s\n' "$v"
}

# 段数だけでは「その境界の手前に目的の migration が居る」ことを保証できない。
# 欠番や重複があっても数は合ってしまうので、対象そのものの適用を 1 件で確かめる。
assert_migration_applied() { # $1=DB $2=バージョン(4桁)
  local db="$1" version="$2" c
  [[ "$version" =~ ^[0-9]{4}$ ]] || {
    echo "assert_migration_applied: 版の指定が 4 桁ではありません: ${version}" >&2; return 1; }
  c=$(PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
      psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$db" \
      -v ON_ERROR_STOP=1 -At -v version="$version" <<'SQL'
SELECT count(*) FROM public.schema_migrations WHERE version = :'version';
SQL
      ) || { echo "assert_migration_applied: ${version} の適用を確かめられませんでした" >&2; return 1; }
  [ "$c" = "1" ] || {
    echo "assert_migration_applied: ${version} の適用が 1 件ではありません（${c}）" >&2; return 1; }
}

# A production-data clone must prove that its management evidence blocks down.
# This sentinel is confined to the clone; it deliberately models post-M1 human
# evidence that 0050's down migration is required to refuse to discard.
PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$RESTORE_DB" \
  -v ON_ERROR_STOP=1 -c "INSERT INTO app.framework_relation_origins(tenant_id,entity_type,entity_id,framework_key,generation_id,origin_kind,origin_id) VALUES(gen_random_uuid(),'measure',gen_random_uuid(),'RISK-MANAGEMENT',gen_random_uuid(),'service','deploy-rollback-rehearsal')" >/dev/null
assert_migration_applied "$RESTORE_DB" 0050 || exit 1
DATA_BEARING_DOWNS=$(downs_above "$RESTORE_DB" 0045) || exit 1
if [ "$DATA_BEARING_DOWNS" -lt 5 ]; then
  echo "restore rehearsal: 0050 まで戻る段数が足りません（${DATA_BEARING_DOWNS}）" >&2
  exit 1
fi
if PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  DATABASE_URL="postgresql://$DB_ADMIN@$DB_HOST:$DB_PORT/$RESTORE_DB" \
  "$NEW_RELEASE/scripts/migrate.sh" down "$DATA_BEARING_DOWNS" >"$BACKUP/data-bearing-down-rejected.log" 2>&1; then
  echo "restore rehearsal: data-bearing 0050 down unexpectedly succeeded" >&2
  exit 1
fi
# **どの guard で止まるかは、その時点で入っているデータで決まる。**
# down は version の降順に進むので、データを持つ最も新しい guard が先に拒否する。
# 0050 固定で見ていたため、教育データを入れた時点で 0054 が先に拒否して
# 「予期しない理由」と誤判定した（実際は保護が正しく働いていた）。
#
# **ゆるめてはいない。** 既知の guard の文言だけを合格とし、構文誤り・権限不足など
# 保護以外の失敗は従来どおり落とす。guard を足したらここにも 1 行足す。
DOWN_GUARD_MESSAGES=(
  '0050 rollback blocked by non-representable management evidence'
  '0050 rollback blocked by measure management evidence'
  '0052 rollback blocked by non-representable management evidence'
  '0054 rollback refused: training integration data would be lost'
  '0055 rollback refused: security objectives would be lost'
  # 2026-09-13: 本番にすでにある down の拒否文のうち、ここに無かったもの(書式の引数より前の固定部分)。
  # 足さないと、運用記録や取り込みの記録がある本番の複製で、これらが先に拒否して「予期しない理由」で止まる。
  # ゆるめてはいない(既知の保護の文言だけを足した)。tests/down_guard_messages_test.sh が漏れを検査する。
  '0063 rollback refused: control effectiveness records would be lost'
  '0065 rollback refused: context issues would be lost'
  '0065 rollback refused: interested parties would be lost'
  '0066 rollback refused: legal requirements would be lost'
  '0068 rollback refused: continuity tests would be lost'
  '0068 rollback refused: continuity plans would be lost'
  '0069 rollback refused: vulnerabilities would be lost'
  '0070 rollback refused: change requests would be lost'
  '0070 rollback refused: change request approvals remain'
  '0071 rollback refused: import records would be lost'
  '0073 rollback refused: organization import records remain'
  '0076 rollback refused: policy import records remain'
  '0078 rollback refused: ISMS-scoped simulation runs would lose their scope'
  '0079 rollback refused: non-macOS posture snapshots would be lost'
  '0080 rollback refused: management device login requests would be lost'
  '0083 rollback refused: agent distribution mail records would be lost'
)
down_guard_matched=0
for _msg in "${DOWN_GUARD_MESSAGES[@]}"; do
  if grep -Fq "$_msg" "$BACKUP/data-bearing-down-rejected.log"; then
    down_guard_matched=1
    echo "[deploy] data-bearing down は既知の保護で拒否された: ${_msg}"
    break
  fi
done
if [ "$down_guard_matched" != 1 ]; then
  echo "restore rehearsal: data-bearing down failed for an unexpected reason" >&2
  exit 1
fi
PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  dropdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" "$RESTORE_DB"
RESTORE_CREATED=0

# Full down/up is valid only on an empty fixture.  Do not use a production-data
# clone for this destructive rehearsal after it has established rollback refusal.
PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  createdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" "$CLEAN_FIXTURE_DB"
CLEAN_FIXTURE_CREATED=1
PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  DATABASE_URL="postgresql://$DB_ADMIN@$DB_HOST:$DB_PORT/$CLEAN_FIXTURE_DB" \
  "$NEW_RELEASE/scripts/migrate.sh" up
assert_migration_applied "$CLEAN_FIXTURE_DB" 0050 || exit 1
CLEAN_FIXTURE_DOWNS=$(downs_above "$CLEAN_FIXTURE_DB" 0045) || exit 1
if [ "$CLEAN_FIXTURE_DOWNS" -lt 7 ]; then
  echo "restore rehearsal: 0045 まで戻る段数が足りません（${CLEAN_FIXTURE_DOWNS}）" >&2
  exit 1
fi
PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  DATABASE_URL="postgresql://$DB_ADMIN@$DB_HOST:$DB_PORT/$CLEAN_FIXTURE_DB" \
  "$NEW_RELEASE/scripts/migrate.sh" down "$CLEAN_FIXTURE_DOWNS"
if PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$CLEAN_FIXTURE_DB" \
  -At -c "SELECT max(version)='0045' AND to_regclass('app.management_deviations') IS NULL AND to_regclass('app.finding_risk_scenarios') IS NULL FROM public.schema_migrations" | grep -Fqx 't'; then
  :
else
  echo "restore rehearsal: clean fixture down did not restore the 0045 boundary" >&2
  exit 1
fi
PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  DATABASE_URL="postgresql://$DB_ADMIN@$DB_HOST:$DB_PORT/$CLEAN_FIXTURE_DB" \
  "$NEW_RELEASE/scripts/migrate.sh" up
RELEASE_MAX=$(release_max_migration "$NEW_RELEASE") || exit 1
if PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$CLEAN_FIXTURE_DB" \
  -At -v expected="$RELEASE_MAX" <<'SQL' | grep -Fqx 't'; then
SELECT max(version) = :'expected' FROM public.schema_migrations;
SQL
  :
else
  echo "restore rehearsal: clean fixture up did not restore the ${RELEASE_MAX} boundary" >&2
  exit 1
fi
PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  dropdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" "$CLEAN_FIXTURE_DB"
CLEAN_FIXTURE_CREATED=0

# 承認済み migration は production では down しない。restore複製で拒否条件を確認し、
# 空fixtureだけでup/downを往復する。失敗時は旧applicationを再活性化しない。
PENDING="$(comm -23 \
  <(find "$NEW_RELEASE/db/migrations" -maxdepth 1 -name '*.up.sql' -print \
      | sed -E 's#.*/([0-9]+)_.*#\1#' | sort) \
  <(PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
      psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$DB_NAME" -At \
      -c 'SELECT version FROM public.schema_migrations ORDER BY version'))"
# **本番へ当ててよい migration をここに明示列挙する。**
# 未レビューの migration が紛れ込んだら落とすためのゲートなので、
# 「db/migrations にある全部」で自動生成してはいけない（それでは何も守らない）。
# 足すときは、その migration をレビューし、人が承認したうえで 1 行足す。
#
# 0046-0052: 2026-09-05 承認
# 0053-0054: 2026-09-07 承認（教育・力量の eLearning 連携）。
#   Codex レビューの指摘を実測で確かめたうえで承認した。残る留意点は 2 つ。
#   (1) 0053 の down はデータ存在チェック無しに統合データを削除する。
#       ただし migrate.sh の down は version の降順固定なので、ツール経由なら
#       0054→0053 の順が守られる。手で 0053 の down だけを流す経路のみ危険。
#   (2) SECURITY DEFINER 関数の SET search_path が app を含む。
#       app スキーマに非信頼ロールの CREATE 権限が無い前提に依存している。
# 0055: 2026-09-07 承認（情報セキュリティ目的 6.2 の受け皿）。
#   Codex レビューを 3 巡し、指摘に対応済み。
#   - 測り方（measure_how）を NOT NULL ＋空文字禁止。測れない目的を作らせない
#   - 達成の評価は実測値・評価日・評価者が 3 つ揃うか 3 つとも空か
#   - down はデータがあると拒否。SHARE ロック＋lock_timeout 10s で
#     count と DROP の間の INSERT を塞ぐ（TOCTOU）
#   実測で否定した指摘: 「admin が RLS を回避できない可能性」→ 本番の接続
#   ユーザーは postgres で super=true / bypassrls=true（実測）。
#   「created_by に FK が無い」→ created_by を持つ app の 54 表のうち FK は
#   1 表だけで、FK なしが既存の設計。
# 0056: 2026-09-07 承認（適用範囲 4.3 の承認を記録する関数）。
#   規程の承認（0034 の approve_policy_version）と同じ形にそろえた。
#   ciso のみ実行可・承認時の本文ハッシュを結ぶ・同じ本文の二重承認は拒否。
#   down は関数だけ落とし、承認記録（app.approvals の行）は消さない。
#   逆向き検証: 正常系／二重承認拒否／空本文拒否／ciso でなければ拒否／
#   down で承認記録が消えないこと、をすべて実測した。
#   実測で否定した指摘（記録として残す）:
#   - 「source_sha256 のコメントが実装と食い違う」→ 誤り。再同期で内容が
#     変わったときに評価を未評価へ戻す処理は web/src/app/training/actions.ts の
#     ON CONFLICT DO UPDATE に実装されている（DB のトリガではなくアプリ側）。
#   - 「新しい台帳がテナント分離されていない」→ 誤り。app.trainings と
#     app.competency_requirements は FORCE ROW LEVEL SECURITY ＋
#     tenant_id = app.current_tenant() が効いている（別テナントの行を入れて実測）。
# 0057-0058: 2026-09-07 承認（作業台帳・複数メンバー割当・外部質問票基盤）。
#   0057 は外部質問票と既存レコード依頼の互換基盤、0058 は作業単位の正本。
#   隔離DBでテナント分離、アサイン済みメンバーの正系、完了後の拒否を実測。
# 0059-0060: 2026-09-08 承認（組織・メンバー管理／作業の対象レコード／メール送信
#   キュー／質問票テンプレート）。隔離 DB で tests/org_members_and_questionnaires.sh
#   を通し、落ちることまで実測した。要点と、実測で見つけた既存の穴:
#   - メンバーの登録・停止は owner/admin のみ（member/manager で拒まれることを実測）。
#     app.provision_tenant(0021) と tests/*.sh は文脈なしで app.users へ書くので、
#     app.has_actor_context() が偽のときは素通しする（縛るとテナント作成が落ちる）。
#   - app.users だけでなく app.memberships / app.departments /
#     app.certification_bodies にも権限トリガーを置く。0015 で app_rw は同一
#     テナント内の全 DML を持つため、Server Action を通らない経路から member が
#     自分に ciso を足せてしまう（Codex 指摘。実測で塞いだことを確認）。
#     ciso の付け外しだけ role_manage（オーナー）、他は member_manage / org_manage。
#   - オーナー（ciso）が 0 人になる更新・削除を制約トリガーで拒む。ただし所属が
#     1 件も残っていないテナント（解体中・作成前）は対象外。これを入れないと
#     tests/rls_test.sh の後始末（memberships の全削除）が落ちる。
#     検査は app.lock_owner_guard() の助言ロックでテナント単位に直列化する。
#     取らないと、別々のオーナーを同時に降ろす 2 つの操作が互いに「相手が
#     残っている」と見て両方通る（Codex 指摘）。
#   - **0057 の app.assignment_target_exists は常に false を返す**（実測）。
#     SECURITY DEFINER で schema_owner として走る一方、app.assets 等は FORCE RLS で
#     app_rw / app_ro 向けのポリシーしか持たない（0015）。結果として 0057 の
#     app.work_assignments は INSERT が必ず 'assignment target not found' で落ちる。
#     0059 は同じ関数を使わず、呼び出し元の権限のまま実在確認する。
#     work_assignments 自体を畳むかどうかは別の判断として残す。
#   - app.mail_outbox へは Web から積むだけ。SMTP 資格情報は
#     ops/runtime/send-mail-outbox.sh 側だけが読む。平文送信はループバック宛のみ許可。
#     積んだ後は宛先・件名・本文・関連先を凍結し（trg_guard_mail_outbox_update）、
#     DELETE は誰にも与えない。sent から他の状態へは戻せない。
#     宛名・件名は制御文字を持てない（送信ワーカーの解析を壊さないため）。
#   - down は 0060 → 0059 の順で当てて実測済み（列・表・関数が残らないこと）。
# 0061: 2026-09-08 承認（利用システム台帳・部門ごとの利用実態・情報資産の所在場所）。
#   隔離 DB で tests/systems_department_usage.sh を通し、落ちることまで実測した。
#   さらに使い捨て DB と本番同等のプロキシ経路で画面を実操作し、メンバーが
#   システムを登録・自部門へ紐付け、資産の所在にそれを選び、部門ビューに
#   反映されるところまで目視した。要点:
#   - **0045 の統制を外していない。** 0045 は app_rw から app.application_catalog の
#     INSERT/UPDATE/DELETE を剥奪し「専用RPCを追加してからだけ書き込む」と定めている。
#     権限は戻さず、予告どおり app.create_system / app.update_system を足した。
#     プロビジョニング側（identity_principals / entitlement_assignments /
#     provisioning_requests / license_catalog）は読み取り専用のまま触っていない。
#   - 利用システムの編集だけ member へ開放（app.require_system_edit_permission。
#     監査人と所属なしは不可）。**app.assets の書き込み権限（0058）は変えていない。**
#   - 新設テーブルは app.department_systems の 1 本のみ。app.assets へは
#     location_system_id（FK→application_catalog）と location_note を足した。
#     owner_department_id は 0027 から未使用のまま在った列で、画面に出しただけ。
#   - SECURITY DEFINER（schema_owner）が読む app.assets / app.application_catalog へ
#     所有者向けポリシーを足した。**app.current_tenant_or_null() で比較する。**
#     app.current_tenant() は未設定で RAISE するため、以後の ALTER TABLE の
#     検証スキャンが落ちる（0060 の FK 追加で実際に踏んだ）。
#   - ガードトリガーは created_at / created_by を呼び出し側に決めさせない
#     （INSERT は本人と now() で上書き、UPDATE は OLD 固定。Codex 指摘）。
#   - **副作用として 0050 の休眠していた統制が目覚める。人の承認を取ったうえで
#     意図的にそうしている。** 0050 の assert_active_management_framework() は
#     SECURITY DEFINER（schema_owner）で app.assets を読むが、所有者向けの
#     ポリシーが無かったため 1 行も見えず、is_active が NULL のまま
#     coalesce(is_active,false) で常に素通りしていた＝「有効な資産には
#     RISK-MANAGEMENT が必要」は配備以来一度も発火していない。0061 で
#     所有者向け SELECT ポリシーが付き、初めて効くようになる。
#     本番データは準拠済み（有効な資産18・リスク24・施策26 のいずれも
#     未準拠 0 件を実測）。画面の saveAsset と seed_business_register.py は
#     枠組みを必ず付ける。枠組み無しで資産を作っていた tests/management_workflows.sh
#     の fixture だけを是正した。
#   - down は 0061 を当てて往復し、表・関数・ポリシー・列・FK・索引が残らないこと、
#     資産そのものは壊れないことを実測した。**down で戻すと上の統制はまた眠る。**
# 0062（2026-09-12、人の承認済み: 本人「本番反映しつつ、その他も進めて」）:
#   - schema_owner 向けの permissive ポリシー 30 枚の条件を app.current_tenant() の直呼びから
#     (SELECT app.current_tenant_or_null()) へ ALTER POLICY で差し替える。表・列・データは変えない。
#   - 文脈があるときの意味は同じ。文脈が無いとき（テナント作成・seed）に RAISE せず、その枝が偽になるだけ。
#     新規 DB で provision_tenant と seed 0009 が落ちていたのを直す（設計書 2026-09-11 §9.3）。
#   - 末尾で「schema_owner 向けで current_tenant() を直に呼ぶポリシーが残っていない」ことを検査する。
#   - down は current_tenant() の直呼びへ戻すだけで、データは残る。新規 DB での逆向き検証
#     （down で new_tenant が再び落ち、up で通る）と tests/run_isolated.sh の全緑を確認済み。
# 0063〜0077（2026-09-13、人の承認済み: 本人「承認して反映する」— 0063〜0077 を1つの束として承認）:
#   - 設計書 2026-09-11 §4・§5 の運用記録（0063〜0070: 是正の有効性・マネジメントレビュー・目的・証跡・例外・
#     組織の状況の課題と利害関係者・法令等の要求事項・事業継続・脆弱性・変更の申請）。役割は DB でも強制
#     （records_role_allows の RESTRICTIVE ポリシー。check_rls.sql が形と対象表を固定）。
#   - §8 の初期データ取り込みの記録（0071〜0074・0076: 資産・リスク・部署・所属の割り当て・規程の下書き）と、
#     取り込みの明細・取り消しの件数の根拠になる変化の記録（0075・0077。トリガだけが書く）。
#   - どれも tests/run_isolated.sh 全緑・画面検証・Codex レビュー済み。down は記録が残っていれば拒否するか、
#     今のトランザクションの判定にしか使わない変化の記録だけを消す（0075・0077）。
REVIEWED_MIGRATIONS="$(printf '%s\n' 0046 0047 0048 0049 0050 0051 0052 0053 0054 0055 0056 0057 0058 0059 0060 0061 0062 0063 0064 0065 0066 0067 0068 0069 0070 0071 0072 0073 0074 0075 0076 0077 0078 0079 0080 0081 0082 0083)"
# 0078（2026-09-13、人の承認済み: 本人「承認して反映する」）:
#   - AI分析を ISMS 側でも使えるようにする変更の、シミュレーションの実行記録に範囲の列(scope)を足す移行。
#     既存の行は ALL として残し、以後の INSERT は範囲を必ず書く(既定値なし)。管理者のまま流す(FORCE RLS のため)。
#   - down は ISMS 範囲の実行記録が残っていれば拒否する(文言は DOWN_GUARD_MESSAGES に登録済み)。
#   - tests/run_isolated.sh 全緑(tests/analysis_isms_scope.sh の既存の行がある状態での down/up を含む)・両モードの画面確認・
#     Codex レビュー済み。本番の実行記録は承認時点で0件。
# 0079（2026-09-13、人の承認済み: 本人「windows対応も出して」2026-09-13 22:5x JST）:
#   - W2（management の Windows posture 対応）の移行。posture の定義を OS ごとに持ち(platform に windows を足す)、
#     取り込み関数は端末の OS の定義で照合する。W2 側では 0078_agent_posture_windows として作り、反映ブランチへ
#     取り込んだ順で 0079 に付け直した(総指揮の決定 2026-09-13 15:20。反映ブランチには既に 0078 がある)。
#   - down は macOS 以外の定義で取り込んだ posture が残っていれば拒否する(文言は DOWN_GUARD_MESSAGES に登録済み)。
#   - W2 の受入 2026-09-13 16:20・W2 の Codex レビュー完了 17:10。付け直しの差分(移行のファイル名・拒否文・
#     DOWN_GUARD_MESSAGES)も Codex レビュー済み(指摘なし)。tests/run_isolated.sh 全緑。
# 0080（2026-09-14、人の承認済み: 本人「Managementも独立して持たせる」）:
#   - Management自身の端末台帳で、登録コード方式とGWS/OAuth承認方式を完結させる。
#     Kaname・Codzillaを必須中央APIにせず、Management DBの登録要求・承認・公開鍵・端末行へ記録する。
#   - RLS、署名付き受け取り、ワンタイムコード、期限、nonce再利用拒否、属性・公開鍵の不一致時
#     ENROLLMENT_INCONSISTENT、管理者専用UIを実装。全品質ゲート、Web/Goテスト、UIビルドを通過。
#   - down は登録要求が残っている場合に拒否する（文言は DOWN_GUARD_MESSAGES に登録済み）。
# 0082（2026-09-15、人の承認済み: 本人「対象機器上のGmailログインでアクティベート」）:
#   - Managementの送付済みGWS導入を対象機器上のGWS/Gmail本人認証で承認する。
#     送付先メールとの不一致、期限切れ、別組織の要求はエラーで拒否し、管理者のコード承認経路は維持する。
#   - down は配布トークンに紐づく登録要求が残っている場合に拒否する。
# 0083（2026-09-15、0081の適用済みdown checksumを保つための後続保護）:
#   - 0081のdownを書き換えず、配布メールが残る本番データのrollbackを0083のdownで先に拒否する。
#     強制RLSの影響を受けないmigration接続主体で全体を確認し、検出時は既知の保護文言で配備ゲートを通す。
# 未適用のものは、承認済みリストの**末尾から連続した並び**でなければならない。
# 途中だけ一致する並びを通すと、承認していない版を飛ばして当てられる。
if [ -n "$PENDING" ]; then
  pending_count="$(printf '%s\n' "$PENDING" | wc -l | tr -d ' ')"
  reviewed_suffix="$(printf '%s' "$REVIEWED_MIGRATIONS" | tail -n "$pending_count")"
  if [ "$reviewed_suffix" != "$PENDING" ]; then
    echo "pending migrations are not a reviewed suffix: $PENDING" >&2
    exit 1
  fi
fi
# 証跡はファイル名からの推測ではなく、**いまの DB の版と、これから当てる版**を書く。
MIG_FROM=$(PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 -At -c "SELECT coalesce(max(version),'none') FROM public.schema_migrations") \
  || { echo "配備記録: 現在の migration 版を読めません" >&2; exit 1; }
MIG_TO=$(release_max_migration "$NEW_RELEASE") \
  || { echo "配備記録: 適用先の migration 版を特定できません" >&2; exit 1; }
printf 'started_at=%s\ncommit=%s\ndatabase=%s\nmigrations=%s->%s\n' "$(date -u +%FT%TZ)" "$COMMIT" "$DB_NAME" "$MIG_FROM" "$MIG_TO" \
  >"$BACKUP/db-mutation-started"
chmod 600 "$BACKUP/db-mutation-started"
sync -f "$BACKUP/db-mutation-started"
DB_MUTATION_STARTED=1
PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  DATABASE_URL="postgresql://$DB_ADMIN@$DB_HOST:$DB_PORT/$DB_NAME" \
  "$NEW_RELEASE/scripts/migrate.sh" up
printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$BACKUP/db-mutation-complete"
chmod 600 "$BACKUP/db-mutation-complete"

APP_MUTATED=1
# 送信ワーカーの env があれば mail_worker も同じ経路で配り直す。
# 手で付けたパスワードが env と食い違って「昨日は送れたのに今日は送れない」に
# ならないよう、ロールの資格情報の出どころを 1 本にまとめる。
MAIL_ENV=/opt/isms-platform/target-env/isms-mail.env
MAIL_ENV_ARGS=()
if [ -f "$MAIL_ENV" ]; then
  MAIL_ENV_ARGS=(--mail-env-file "$MAIL_ENV")
fi
PLATFORM_NATIVE_POSTGRES_PASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
python3 "$NEW_RELEASE/scripts/configure_runtime_db_roles.py" \
  --admin-user "$DB_ADMIN" --admin-password-env PLATFORM_NATIVE_POSTGRES_PASSWORD \
  "${MAIL_ENV_ARGS[@]}"
install -m 700 "$NEW_RELEASE/ops/runtime/start-isms.sh" /opt/isms-platform/bin/start-isms.sh
ln -sfn "$NEW_RELEASE" "$RELEASES/current.next"
mv -Tf "$RELEASES/current.next" "$CURRENT"
SWITCHED=1

unset PGPASSWORD
READ_DSN="postgresql://app_ro@$DB_HOST:$DB_PORT/$DB_NAME"
WRITE_DSN="postgresql://app_rw@$DB_HOST:$DB_PORT/$DB_NAME"
if [ "$(PGPASSFILE=/opt/isms-platform/.pgpass psql -At "$READ_DSN" -c 'SELECT current_user')" != "app_ro" ]; then
  echo "read DSN did not authenticate as app_ro" >&2
  exit 1
fi
if [ "$(PGPASSFILE=/opt/isms-platform/.pgpass psql -At "$WRITE_DSN" -c 'SELECT current_user')" != "app_rw" ]; then
  echo "write DSN did not authenticate as app_rw" >&2
  exit 1
fi
if [ "$(PGPASSFILE=/opt/isms-platform/.pgpass psql -At "$READ_DSN" -c "SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname=current_user")" != "f" ]; then
  echo "read role can bypass RLS" >&2
  exit 1
fi
if PGPASSFILE=/opt/isms-platform/.pgpass psql "$READ_DSN" -v ON_ERROR_STOP=1 \
  -c "INSERT INTO app.tenants(id,name,status) VALUES(gen_random_uuid(),'forbidden','active')" >/dev/null 2>&1; then
  echo "app_ro unexpectedly accepted a persistent write" >&2
  exit 1
fi
if [ "$(PGPASSFILE=/opt/isms-platform/.pgpass PGOPTIONS='-c default_transaction_read_only=on' psql -At "$READ_DSN" -c 'SHOW transaction_read_only')" != "on" ]; then
  echo "web-equivalent read-only transaction gate failed" >&2
  exit 1
fi
if PGPASSFILE=/opt/isms-platform/.pgpass psql "$WRITE_DSN" -v ON_ERROR_STOP=1 \
  -c "SELECT count(*) FROM app.identity_principals" >/dev/null 2>&1; then
  echo "app_rw read tenant data without a signed context" >&2
  exit 1
fi

# Exercise the exact proxy-identity boundary with the live server-held session,
# but keep the Management write in one transaction and roll it back.  The token
# and selected email are passed through psql's environment, never its argv/log.
set -a
source /opt/isms-platform/target-env/isms.env
set +a
if [ -z "${ISMS_WEB_TENANT_TOKEN:-}" ] || [ "${#ISMS_WEB_TENANT_TOKEN}" -lt 32 ]; then
  echo "proxy identity smoke requires a server-held tenant session" >&2
  exit 1
fi
PROXY_SMOKE_EMAIL="$(PGPASSWORD="$PLATFORM_NATIVE_POSTGRES_PASSWORD" \
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d "$DB_NAME" -At <<'SQL'
\getenv proxy_token ISMS_WEB_TENANT_TOKEN
SELECT u.email
  FROM app.sessions s
  JOIN app.users u ON u.tenant_id=s.tenant_id AND u.id=s.user_id
 WHERE s.token_hash=public.digest(pg_catalog.convert_to(:'proxy_token','UTF8'),'sha256')
   AND s.expires_at>pg_catalog.now() AND s.revoked_at IS NULL
 LIMIT 1;
SQL
)"
if [[ ! "$PROXY_SMOKE_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; then
  echo "proxy identity smoke could not resolve the live session actor" >&2
  exit 1
fi
export PROXY_SMOKE_EMAIL
if PGPASSFILE=/opt/isms-platform/.pgpass \
  psql "$WRITE_DSN" \
  -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
\getenv proxy_token ISMS_WEB_TENANT_TOKEN
\getenv proxy_email PROXY_SMOKE_EMAIL
BEGIN;
SELECT app.set_tenant_context_for_proxy(:'proxy_token',:'proxy_email'::citext);
ROLLBACK;
SQL
then
  echo "app_rw unexpectedly established trusted proxy identity" >&2
  exit 1
fi
PROXY_DB_PASSWORD="$(printf 'management-web:%s' "$ISMS_DEVICE_CONTROL_PROXY_SECRET" | sha256sum | awk '{print $1}')"
PGPASSWORD="$PROXY_DB_PASSWORD" \
  psql -h "$DB_HOST" -p "$DB_PORT" -U management_web -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
\getenv proxy_token ISMS_WEB_TENANT_TOKEN
\getenv proxy_email PROXY_SMOKE_EMAIL
BEGIN;
SELECT app.set_tenant_context_for_proxy(:'proxy_token',:'proxy_email'::citext);
DO $$
DECLARE v_risk uuid;
BEGIN
  IF app.current_tenant() IS NULL OR app.current_session_user() IS NULL THEN
    RAISE EXCEPTION 'proxy identity context was not retained';
  END IF;
  SELECT id INTO v_risk FROM app.risk_scenarios
   WHERE tenant_id=app.current_tenant() ORDER BY id LIMIT 1;
  IF v_risk IS NULL THEN
    RAISE EXCEPTION 'proxy identity smoke found no management risk';
  END IF;
  PERFORM app.set_management_frameworks_human(
    'risk_scenario', v_risk, ARRAY['RISK-MANAGEMENT']);
END $$;
ROLLBACK;
SQL
unset PROXY_DB_PASSWORD

systemctl --user restart "$SERVICE"
systemctl --user is-active --quiet "$SERVICE"
wait_http http://127.0.0.1:13110/
curl --connect-timeout 5 --max-time 15 --fail --silent --show-error \
  http://127.0.0.1:13110/operations/identity-access >/dev/null
curl --config - >/dev/null <<EOF
url = "http://127.0.0.1:13110/internal/health/management-proxy"
request = "POST"
connect-timeout = 5
max-time = 15
fail
silent
show-error
header = "Authorization: Bearer $ISMS_DEVICE_CONTROL_PROXY_SECRET"
header = "x-forwarded-email: $PROXY_SMOKE_EMAIL"
header = "x-ib-device-control-proxy-secret: $ISMS_DEVICE_CONTROL_PROXY_SECRET"
EOF
unset PROXY_SMOKE_EMAIL
unset ISMS_WEB_TENANT_TOKEN
if ss -H -ltn 'sport = :13110' | awk '{print $4}' | grep -Evq '^127\.0\.0\.1:13110$'; then
  echo "ISMS listener is exposed beyond loopback" >&2
  exit 1
fi
PUBLIC_STATUS="$(curl --connect-timeout 5 --max-time 15 --silent --show-error \
  --output /dev/null --write-out '%{http_code}' \
  https://management.example.invalid/)"
if [ "$PUBLIC_STATUS" != "403" ]; then
  echo "public SSO boundary returned unexpected status: $PUBLIC_STATUS" >&2
  exit 1
fi
printf '%s\n' "$OLD_TARGET" >"$BACKUP/previous-release"
printf '%s\n' "$NEW_RELEASE" >"$BACKUP/deployed-release"
chmod 600 "$BACKUP/previous-release" "$BACKUP/deployed-release"
trap - EXIT INT TERM HUP
echo "[deploy] success commit=$COMMIT backup=$BACKUP public_status=$PUBLIC_STATUS"
