#!/usr/bin/env bash
# Acceptance by replaying recorded Google Workspace reader responses.
# Doesn't call the real API; measures normalization, idempotency, and unreadable/gone/coverage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${ISMS_REPLAY_TEST_DB:-isms_connector_replay_test}"

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
die() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
cleanup() { dropdb --if-exists "$DB" >/dev/null 2>&1 || true; }
trap cleanup EXIT

printf '\n\033[36m== connector replay の受入\033[0m\n'
python3 "$ROOT/tests/connector_fixture_hash_test.py" || die "fixture の改変検知"

dropdb --if-exists "$DB" >/dev/null
createdb "$DB"
ISMS_DB="$DB" "$ROOT/scripts/migrate.sh" up >/dev/null 2>&1 || die "migration"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0002_checks_core.sql" >/dev/null
ISMS_DB="$DB" python3 "$ROOT/db/seeds/0003_connectors.py" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/db/seeds/0004_phase2_checks.sql" >/dev/null

OUT=$(ISMS_DB="$DB" python3 "$ROOT/scripts/new_tenant.py" \
  --name '再生検証' --domain replay.invalid --admin-email admin@replay.invalid --admin-name '検証管理者')
TOKEN=$(printf '%s\n' "$OUT" | tail -1)
ISMS_DB="$DB" python3 "$ROOT/scripts/connector_sync.py" --token "$TOKEN" >/dev/null \
  || die "記録済みレスポンスの再生"
pass "記録済みレスポンスを実 API なしで再生"

COUNTS=$(psql -At -d "$DB" -c "select (select count(*) from app.accounts),(select count(*) from app.resources),(select count(*) from app.raw_events),(select count(*) from app.effective_grants)")
[ "$COUNTS" = "2|2|1|2" ] || die "正規化後の件数が想定外: $COUNTS"
pass "正規化グラフの件数（accounts 2 / resources 2 / raw_events 1 / effective_grants 2）"

STATES=$(psql -At -d "$DB" -c "select collection_state||':'||count(*) from app.integration_resource_runs group by collection_state order by collection_state")
printf '%s\n' "$STATES" | grep -qx 'collected:9' || die "collected の資源別証跡が想定外: $STATES"
printf '%s\n' "$STATES" | grep -qx 'gone:1' || die "gone の資源別証跡がありません: $STATES"
printf '%s\n' "$STATES" | grep -qx 'unreadable:1' || die "unreadable の資源別証跡がありません: $STATES"
pass "unreadable / gone を資源別に記録"

COVERAGE=$(psql -At -d "$DB" -c "select coverage_ratio from app.integration_runs where resource_name='drive_permissions' order by started_at desc limit 1")
[ "$COVERAGE" = "0.500" ] || die "coverage_ratio が想定外: $COVERAGE"
pass "coverage_ratio=0.500（1/2）を記録"

BEFORE=$(psql -At -d "$DB" -c "select (select count(*) from app.accounts),(select count(*) from app.resources),(select count(*) from app.grants),(select count(*) from app.groups),(select count(*) from app.raw_events),(select count(*) from app.effective_grants)")
ISMS_DB="$DB" python3 "$ROOT/scripts/connector_sync.py" --token "$TOKEN" >/dev/null \
  || die "同じ fixture の再生"
AFTER=$(psql -At -d "$DB" -c "select (select count(*) from app.accounts),(select count(*) from app.resources),(select count(*) from app.grants),(select count(*) from app.groups),(select count(*) from app.raw_events),(select count(*) from app.effective_grants)")
[ "$BEFORE" = "$AFTER" ] || die "同じ fixture の再生で正規化件数が変わった: $BEFORE -> $AFTER"
pass "同じ fixture の再生が冪等"

printf '\033[32mconnector replay: 全て緑\033[0m\n'
