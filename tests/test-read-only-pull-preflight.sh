#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="$ROOT/scripts/read_only_pull_preflight.py"
CONTRACT="$ROOT/connectors/read_only_sources.contract.json"
STUB="$ROOT/tests/fixtures/read-only-psql-stub.sh"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT
SQLITE_DB="$OUT_DIR/codzilla.sqlite"
sqlite3 "$SQLITE_DB" "create table events (id integer primary key, message text); insert into events (message) values ('a');"

export ISMS_PULL_DSN_MKT=fixture_mkt
export ISMS_PULL_DSN_OPS=fixture_ops
export ISMS_PULL_DSN_SSI=fixture_ssi
export ISMS_PULL_DSN_KANAME=fixture_kaname
export ISMS_PULL_DSN_CODZILLA="$SQLITE_DB"
export ISMS_PULL_DSN_EL=fixture_el
export ISMS_PULL_PROBE_RELATION_MKT=public.source_mkt
export ISMS_PULL_PROBE_RELATION_OPS=public.source_ops
export ISMS_PULL_PROBE_RELATION_SSI=public.source_ssi
export ISMS_PULL_PROBE_RELATION_KANAME=public.source_kaname
export ISMS_PULL_PROBE_RELATION_CODZILLA=events
export ISMS_PULL_PROBE_RELATION_EL=public.source_el
export ISMS_PULL_PROBE_COLUMN_MKT=id
export ISMS_PULL_PROBE_COLUMN_OPS=id
export ISMS_PULL_PROBE_COLUMN_SSI=id
export ISMS_PULL_PROBE_COLUMN_KANAME=id
export ISMS_PULL_PROBE_COLUMN_CODZILLA=message
export ISMS_PULL_PROBE_COLUMN_EL=id

python3 -m py_compile "$PREFLIGHT"
python3 "$PREFLIGHT" --contract "$CONTRACT" --psql "$STUB" --sqlite sqlite3 --isolated

if env -u ISMS_PULL_DSN_SSI python3 "$PREFLIGHT" --contract "$CONTRACT" --psql "$STUB" --sqlite sqlite3 --isolated >/dev/null 2>&1; then
  echo "reverse check failed: missing source DSN was accepted" >&2
  exit 1
fi

ISMS_PULL_PROBE_RELATION_CODZILLA='events;drop' \
  python3 "$PREFLIGHT" --contract "$CONTRACT" --psql "$STUB" --sqlite sqlite3 --isolated >/dev/null 2>&1 && {
  echo "reverse check failed: unsafe SQLite relation was accepted" >&2
  exit 1
}

if python3 "$PREFLIGHT" --contract "$CONTRACT" --psql "$OUT_DIR/missing-psql" --sqlite sqlite3 --isolated >/dev/null 2>&1; then
  echo "reverse check failed: unavailable PostgreSQL driver was accepted" >&2
  exit 1
fi

ISMS_PULL_DSN_CODZILLA="$OUT_DIR/missing.sqlite" \
  python3 "$PREFLIGHT" --contract "$CONTRACT" --psql "$STUB" --sqlite sqlite3 --isolated >/dev/null 2>&1 && {
  echo "reverse check failed: missing SQLite file was accepted" >&2
  exit 1
}

echo "read-only-pull-preflight: pass no connections plus reverse checks"
