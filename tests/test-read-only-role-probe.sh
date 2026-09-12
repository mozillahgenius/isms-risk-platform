#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROBE="$ROOT/scripts/read_only_role_probe.py"

python3 -m py_compile "$PROBE"
if python3 "$PROBE" --source-id ops --dsn-env ISMS_PULL_DSN_OPS --relation app.accounts --column id >/dev/null 2>&1; then
  echo "reverse check failed: probe without isolated acknowledgement was accepted" >&2
  exit 1
fi
if python3 "$PROBE" --source-id ops --dsn-env ISMS_PULL_DSN_OPS --relation app.accounts --column id --isolated >/dev/null 2>&1; then
  echo "reverse check failed: missing live DSN was treated as a passing probe" >&2
  exit 1
fi

echo "read-only-role-probe: pass missing-live-evidence-is-unverified"
