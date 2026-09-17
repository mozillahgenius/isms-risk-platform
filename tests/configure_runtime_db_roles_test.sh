#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
DATA_DIR="$TMP_ROOT/data"
SOCKET_DIR="$TMP_ROOT/socket"
SOURCE_PGPASS="$TMP_ROOT/source.pgpass"
TARGET_PGPASS="$TMP_ROOT/target.pgpass"
TWO_ROLE_PGPASS="$TMP_ROOT/two-role.pgpass"
ROLE_ENV="$TMP_ROOT/roles.env"
PROXY_ENV="$TMP_ROOT/proxy.env"
BAD_PGPASS="$TMP_ROOT/bad.pgpass"
PORT=$((55000 + $$ % 5000))
ADMIN_USER="$(id -un)"
STARTED=0

cleanup() {
  if [ "$STARTED" = "1" ]; then
    pg_ctl -D "$DATA_DIR" -m immediate stop >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM HUP

mkdir "$SOCKET_DIR"
initdb -D "$DATA_DIR" --auth-local=trust --auth-host=scram-sha-256 >/dev/null
pg_ctl -D "$DATA_DIR" -o "-k $SOCKET_DIR -p $PORT -c listen_addresses=127.0.0.1" -w start >/dev/null
STARTED=1

psql -h "$SOCKET_DIR" -p "$PORT" -d postgres -v ON_ERROR_STOP=1 \
  -v admin_user="$ADMIN_USER" >/dev/null <<'SQL'
CREATE ROLE app_ro LOGIN PASSWORD 'ro-pass';
CREATE ROLE app_rw LOGIN PASSWORD 'rw-pass';
CREATE ROLE auth_svc LOGIN PASSWORD 'auth-pass';
CREATE ROLE management_web LOGIN PASSWORD 'old-proxy-pass';
ALTER ROLE :"admin_user" PASSWORD 'admin-pass';
CREATE DATABASE source_db;
CREATE DATABASE target_db;
CREATE DATABASE target_db_management_workflows;
SQL

printf '%s\n' \
  "127.0.0.1:$PORT:source_db:app_ro:ro-pass" \
  "127.0.0.1:$PORT:source_db:app_rw:rw-pass" \
  "127.0.0.1:$PORT:source_db:auth_svc:auth-pass" >"$SOURCE_PGPASS"
chmod 600 "$SOURCE_PGPASS"
printf '%s\n' \
  "127.0.0.1:$PORT:source_db:app_ro:ro-pass" \
  "127.0.0.1:$PORT:source_db:app_rw:rw-pass" >"$TWO_ROLE_PGPASS"
chmod 600 "$TWO_ROLE_PGPASS"
printf '%s\n' "ISMS_DEVICE_CONTROL_PROXY_SECRET=proxy-secret-0123456789abcdef" >"$PROXY_ENV"
chmod 600 "$PROXY_ENV"

TEST_ADMIN_PASSWORD=admin-pass \
python3 "$ROOT/scripts/configure_runtime_db_roles.py" \
  --pgpass "$SOURCE_PGPASS" \
  --pgpass-target "$TARGET_PGPASS" \
  --host 127.0.0.1 \
  --port "$PORT" \
  --source-database source_db \
  --database target_db \
  --admin-user "$ADMIN_USER" \
  --admin-password-env TEST_ADMIN_PASSWORD >/dev/null

printf '%s\n' "127.0.0.1:$PORT:target_db:auth_svc:wrong-password" >"$BAD_PGPASS"
chmod 600 "$BAD_PGPASS"
if PGPASSFILE="$BAD_PGPASS" PGCONNECT_TIMEOUT=5 \
  psql -w -h 127.0.0.1 -p "$PORT" -U auth_svc -d target_db \
  -At -v ON_ERROR_STOP=1 -c 'SELECT current_user' </dev/null >/dev/null 2>&1; then
  echo "bad pgpass unexpectedly authenticated" >&2
  exit 1
fi

AUTHENTICATED_USER="$(
  PGPASSFILE="$TARGET_PGPASS" PGCONNECT_TIMEOUT=5 \
    psql -w -h 127.0.0.1 -p "$PORT" -U auth_svc -d target_db \
    -At -v ON_ERROR_STOP=1 -c 'SELECT current_user' </dev/null
)"
[ "$AUTHENTICATED_USER" = "auth_svc" ]
[ "$(stat -f '%Lp' "$TARGET_PGPASS" 2>/dev/null || stat -c '%a' "$TARGET_PGPASS")" = "600" ]
NESTED_AUTHENTICATED_USER="$(
  PGPASSFILE="$TARGET_PGPASS" PGCONNECT_TIMEOUT=5 \
    psql -w -h 127.0.0.1 -p "$PORT" -U auth_svc -d target_db_management_workflows \
    -At -v ON_ERROR_STOP=1 -c 'SELECT current_user' </dev/null
)"
[ "$NESTED_AUTHENTICATED_USER" = "auth_svc" ]
NESTED_ADMIN_USER="$(
  PGPASSFILE="$TARGET_PGPASS" PGCONNECT_TIMEOUT=5 \
    psql -w -h 127.0.0.1 -p "$PORT" -U "$ADMIN_USER" -d target_db_management_workflows \
    -At -v ON_ERROR_STOP=1 -c 'SELECT current_user' </dev/null
)"
[ "$NESTED_ADMIN_USER" = "$ADMIN_USER" ]

TEST_ADMIN_PASSWORD=admin-pass \
python3 "$ROOT/scripts/configure_runtime_db_roles.py" \
  --pgpass "$TWO_ROLE_PGPASS" \
  --target "$ROLE_ENV" \
  --proxy-env-file "$PROXY_ENV" \
  --host 127.0.0.1 \
  --port "$PORT" \
  --database source_db \
  --admin-user "$ADMIN_USER" \
  --admin-password-env TEST_ADMIN_PASSWORD >/dev/null
grep -Fq 'ISMS_WEB_DATABASE_URL=' "$ROLE_ENV"
grep -Fq 'ISMS_PROXY_DATABASE_URL=' "$ROLE_ENV"

echo "configure_runtime_db_roles_test: PASS"
