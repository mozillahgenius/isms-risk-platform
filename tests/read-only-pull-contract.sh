#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHECK="$ROOT/scripts/validate_pull_sources.py"
CONTRACT="$ROOT/connectors/read_only_sources.contract.json"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

python3 -m py_compile "$CHECK"
python3 "$CHECK" "$CONTRACT"
cp "$CONTRACT" "$TMP_DIR/missing-ddl-deny.json"
sed -i.bak 's/"DROP"/"DROP_REMOVED"/g' "$TMP_DIR/missing-ddl-deny.json"
if python3 "$CHECK" "$TMP_DIR/missing-ddl-deny.json" >/dev/null 2>&1; then
  echo "reverse check failed: incomplete DDL deny set was accepted" >&2
  exit 1
fi

cp "$CONTRACT" "$TMP_DIR/wrong-access-mode.json"
sed -i.bak 's/"access_mode": "filesystem_read_only"/"access_mode": "database_role"/' "$TMP_DIR/wrong-access-mode.json"
if python3 "$CHECK" "$TMP_DIR/wrong-access-mode.json" >/dev/null 2>&1; then
  echo "reverse check failed: driver/access mode mismatch was accepted" >&2
  exit 1
fi

cp "$CONTRACT" "$TMP_DIR/wrong-status.json"
sed -i.bak 's/"runner_implemented_pending_runtime_access"/"contract-only"/' "$TMP_DIR/wrong-status.json"
if python3 "$CHECK" "$TMP_DIR/wrong-status.json" >/dev/null 2>&1; then
  echo "reverse check failed: stale contract status was accepted" >&2
  exit 1
fi

cp "$CONTRACT" "$TMP_DIR/wrong-credential-ref.json"
sed -i.bak 's/"cred.pull.mkt"/"not-a-credential-reference"/' "$TMP_DIR/wrong-credential-ref.json"
if python3 "$CHECK" "$TMP_DIR/wrong-credential-ref.json" >/dev/null 2>&1; then
  echo "reverse check failed: invalid credential reference was accepted" >&2
  exit 1
fi

echo "read-only-pull-contract: pass"
