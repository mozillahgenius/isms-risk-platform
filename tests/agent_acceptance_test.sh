#!/usr/bin/env bash
# Phase 3a acceptance: fixed macOS definition, one-time enrollment, signed
# posture landing, local audit log, idempotent retry, and reverse rejection.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${ISMS_AGENT_TEST_DB:-isms_agent_test}"
PORT="${ISMS_AGENT_TEST_PORT:-3111}"
AGENT_TMP="$(mktemp -d)"
SERVER_PID=""

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
die() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  # SERVER_PID is the subshell's PID, and the next-server beyond it **remains**.
  # If it remains when the next run starts, the new one fails to start and talks to the old server (which looks at a different DB),
  # getting HTTP 400. Since that fails with no clear cause, kill whatever is listening too.
  if command -v lsof >/dev/null 2>&1; then
    lsof -ti "tcp:$PORT" 2>/dev/null | xargs -r kill >/dev/null 2>&1 || true
  fi
  dropdb --if-exists "$DB" >/dev/null 2>&1 || true
  rm -rf "$AGENT_TMP"
}
trap cleanup EXIT

# Before starting, check that the port is free. If occupied, fail saying so.
if command -v lsof >/dev/null 2>&1 && [ -n "$(lsof -ti "tcp:$PORT" 2>/dev/null || true)" ]; then
  printf '  \033[31mFAIL\033[0m ポート %s が既に使われています（前回の next-server が残っています）\n' "$PORT"
  printf '        lsof -ti tcp:%s | xargs kill で落としてから流し直してください\n' "$PORT"
  exit 1
fi

printf '\n\033[36m== Phase 3a agent acceptance\033[0m\n'

go -C "$ROOT/agent" test ./... >/dev/null || die 'Go agent tests'
go -C "$ROOT/agent" build -o "$AGENT_TMP/isms-agent" ./cmd/isms-agent
pass '固定定義・正規化・署名・fixture 収集の Go テスト'

dropdb --if-exists "$DB" >/dev/null
createdb "$DB"
ISMS_DB="$DB" "$ROOT/scripts/migrate.sh" up >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0002_checks_core.sql" >/dev/null
ISMS_DB="$DB" python3 "$ROOT/db/seeds/0003_connectors.py" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0004_phase2_checks.sql" >/dev/null
ISMS_DB="$DB" python3 "$ROOT/db/seeds/0005_agent_definition.py" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0006_phase3_device_checks.sql" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/scripts/ci/check_rls.sql" >/dev/null
pass 'migration・seed・RLS ゲート'

INGEST_SECRET=$(openssl rand -hex 32)
ISMS_DB="$DB" ISMS_AGENT_INGEST_SECRET="$INGEST_SECRET" \
  python3 "$ROOT/scripts/set_agent_ingest_key.py" >/dev/null
openssl genpkey -algorithm Ed25519 -out "$AGENT_TMP/definition-key.pem" >/dev/null 2>&1
openssl pkey -in "$AGENT_TMP/definition-key.pem" -outform DER \
  -out "$AGENT_TMP/definition-key.der" >/dev/null 2>&1
DEFINITION_KEY_B64=$(base64 < "$AGENT_TMP/definition-key.der" | tr -d '\n')

(cd "$ROOT/web" && npm run build >/dev/null)

TENANT_OUT=$(ISMS_DB="$DB" python3 "$ROOT/scripts/new_tenant.py" \
  --name 'Agent acceptance' --domain agent-test.invalid \
  --admin-email agent@example.invalid --admin-name 'Agent acceptance')
TENANT_ID=$(printf '%s\n' "$TENANT_OUT" | awk '/^tenant_id:/ {print $2}')
[ -n "$TENANT_ID" ] || die 'tenant_id の取得'
ENROLL_TOKEN=$(ISMS_DB="$DB" python3 "$ROOT/scripts/issue_device_enrollment.py" \
  --tenant-id "$TENANT_ID" --ttl '1 hour')

(cd "$ROOT/web" && ISMS_AGENT_DATABASE_URL="postgres:///$DB?user=app_rw" \
  ISMS_AGENT_INGEST_SECRET="$INGEST_SECRET" \
  ISMS_AGENT_DEFINITION_PRIVATE_KEY_B64="$DEFINITION_KEY_B64" \
  npx next start -H 127.0.0.1 -p "$PORT" >"$AGENT_TMP/web.log" 2>&1) &
SERVER_PID=$!
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$PORT/api/agent/v1/definition" >/dev/null 2>&1; then break; fi
  sleep 1
done
DEFINITION_RESPONSE=$(curl -fsS "http://127.0.0.1:$PORT/api/agent/v1/definition") || die 'definition endpoint'
printf '%s' "$DEFINITION_RESPONSE" | jq -e '.signature and .signing_public_key' >/dev/null \
  || die 'definition endpoint の署名情報'

if ! DEVICE_OUT=$("$AGENT_TMP/isms-agent" enroll \
  --url "http://127.0.0.1:$PORT" --enrollment-token "$ENROLL_TOKEN" \
  --external-id 'fixture-serial' --hostname 'fixture-mac' --model 'Mac mini' \
  --os-family macos --private-key "$AGENT_TMP/device.key" \
  --config "$AGENT_TMP/config.json"); then
  cat "$AGENT_TMP/web.log" >&2
  die 'agent enrollment'
fi
DEVICE_ID=$(printf '%s\n' "$DEVICE_OUT" | awk '/^device_id:/ {print $2}')
[ -n "$DEVICE_ID" ] || die 'device_id の取得'
"$AGENT_TMP/isms-agent" collect --device-id "$DEVICE_ID" --external-id fixture-serial \
  --private-key "$AGENT_TMP/device.key" --fixture "$ROOT/agent/testdata/fixture-good.json" \
  --output "$AGENT_TMP/posture.json" --log "$AGENT_TMP/posture.log"
if ! "$AGENT_TMP/isms-agent" posture --url "http://127.0.0.1:$PORT" \
  --envelope "$AGENT_TMP/posture.json" >/dev/null; then
  cat "$AGENT_TMP/web.log" >&2
  die 'agent posture ingest'
fi
pass 'enroll → fixture collect → Ed25519 posture ingest'

COUNT=$(psql -At -d "$DB" -c "SELECT count(*) FROM app.device_snapshots WHERE device_id='$DEVICE_ID'")
[ "$COUNT" = '1' ] || die "device_snapshots の初回件数 ($COUNT)"
"$AGENT_TMP/isms-agent" posture --url "http://127.0.0.1:$PORT" \
  --envelope "$AGENT_TMP/posture.json" >/dev/null
COUNT=$(psql -At -d "$DB" -c "SELECT count(*) FROM app.device_snapshots WHERE device_id='$DEVICE_ID'")
[ "$COUNT" = '1' ] || die "同一 payload の再送で重複 ($COUNT)"
pass '同一 raw_hash の再送は冪等'

TAMPER_STATUS=$(jq '.payload.disk_encrypted = false' "$AGENT_TMP/posture.json" | \
  curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H 'content-type: application/json' --data-binary @- \
  "http://127.0.0.1:$PORT/api/agent/v1/posture")
[ "$TAMPER_STATUS" = '401' ] || die "改変 payload が HTTP 401 で拒否されない ($TAMPER_STATUS)"
if psql -v ON_ERROR_STOP=1 -q -d "$DB" -c "
  SELECT app.ingest_device_snapshot(
    '$DEVICE_ID'::uuid, now(), 'forged', 2,
    decode(repeat('00',32),'hex'), '{}'::jsonb,
    decode(repeat('00',64),'hex'), decode(repeat('01',32),'hex'),
    decode(repeat('00',32),'hex'))" >/dev/null 2>&1; then
  die 'DB 関数を直接呼んだ偽証票が通る'
fi
if "$AGENT_TMP/isms-agent" enroll --url "http://127.0.0.1:$PORT" \
  --enrollment-token "$ENROLL_TOKEN" --external-id fixture-serial-2 \
  --hostname fixture-mac-2 --model 'Mac mini' --os-family macos \
  --private-key "$AGENT_TMP/device-2.key" >/dev/null 2>&1; then
  die '使用済み enrollment token が再利用できる'
fi
pass '改変署名 payload と使用済み enrollment token を拒否'

MODE=$(stat -f '%Lp' "$AGENT_TMP/posture.log")
[ "$MODE" = '600' ] || die "local posture log の権限が 0600 でない ($MODE)"
printf '\033[32mPhase 3a agent: 全て緑\033[0m\n'
