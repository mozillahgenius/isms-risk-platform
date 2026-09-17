#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/run_read_only_pulls.py"
STUB="$ROOT/tests/fixtures/read-only-psql-stub.sh"
WRITABLE_SQLITE_STUB="$ROOT/tests/fixtures/writable-sqlite-stub.sh"
CONTRACT="$ROOT/connectors/read_only_sources.contract.json"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT
SQLITE_DB="$OUT_DIR/codzilla.sqlite"
sqlite3 "$SQLITE_DB" "create table events (id integer primary key, message text); insert into events (message) values ('a'), ('b'), ('c');"

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

python3 -m py_compile "$RUNNER" "$ROOT/scripts/read_only_role_probe.py" "$ROOT/scripts/sqlite_read_only_probe.py" "$ROOT/scripts/validate_pull_events.py" "$ROOT/scripts/snapshot_pull_events.py"
bash "$ROOT/tests/read-only-pull-contract.sh" >/dev/null
bash "$ROOT/tests/test-read-only-pull-preflight.sh" >/dev/null

python3 "$RUNNER" --contract "$CONTRACT" --psql "$STUB" --isolated --output-dir "$OUT_DIR"
files=("$OUT_DIR"/*.json)
[ "${#files[@]}" -eq 6 ] || { echo "expected six event files" >&2; exit 1; }
python3 - "$OUT_DIR" <<'PY'
import json
import pathlib
import sys

paths = sorted(pathlib.Path(sys.argv[1]).glob("*.json"))
assert {path.stem for path in paths} == {"mkt", "ops", "ssi", "kaname", "codzilla", "el"}
expected_credentials = {f"cred.pull.{path.stem}" for path in paths}
for path in paths:
    data = json.loads(path.read_text(encoding="utf-8"))
    assert data["status"] == "ok"
    assert data["error_class"] is None
    assert data["read_only"] is True
    assert data["record_count"] == 3
    assert data["credential_id"] in expected_credentials
PY

python3 "$ROOT/scripts/validate_pull_events.py" "$OUT_DIR"

MANIFEST="$OUT_DIR/events.manifest"
python3 "$ROOT/scripts/snapshot_pull_events.py" freeze "$OUT_DIR" "$MANIFEST"
python3 "$ROOT/scripts/snapshot_pull_events.py" verify "$OUT_DIR" "$MANIFEST"

python3 - "$OUT_DIR" "$MANIFEST" "$ROOT/scripts/snapshot_pull_events.py" <<'PY'
import pathlib
import subprocess
import sys

event_dir = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
snapshotter = sys.argv[3]
path = event_dir / "mkt.json"
original = path.read_bytes()
path.write_bytes(original + b"\n")
result = subprocess.run(
    [sys.executable, snapshotter, "verify", str(event_dir), str(manifest)],
    capture_output=True,
    text=True,
)
assert result.returncode != 0, "modified event was accepted by snapshot verification"
path.write_bytes(original)
subprocess.run([sys.executable, snapshotter, "verify", str(event_dir), str(manifest)], check=True)
PY

python3 - "$OUT_DIR" "$ROOT/scripts/validate_pull_events.py" <<'PY'
import json
import pathlib
import shutil
import subprocess
import sys

source = pathlib.Path(sys.argv[1])
validator = sys.argv[2]
mutated = source.parent / "mutated-events"
shutil.copytree(source, mutated)
path = mutated / "mkt.json"
data = json.loads(path.read_text(encoding="utf-8"))
data["read_only"] = False
path.write_text(json.dumps(data), encoding="utf-8")
result = subprocess.run([sys.executable, validator, str(mutated)], capture_output=True, text=True)
assert result.returncode != 0, "read_only=false was accepted"
shutil.rmtree(mutated)

mutated = source.parent / "missing-events"
shutil.copytree(source, mutated)
(mutated / "el.json").unlink()
result = subprocess.run([sys.executable, validator, str(mutated)], capture_output=True, text=True)
assert result.returncode != 0, "missing source event was accepted"
shutil.rmtree(mutated)
PY

if python3 "$RUNNER" --contract "$CONTRACT" --psql "$STUB" --output-dir "$OUT_DIR/no-isolated" >/dev/null 2>&1; then
  echo "reverse check failed: missing --isolated was accepted" >&2
  exit 1
fi

if env -u ISMS_PULL_DSN_EL python3 "$RUNNER" --contract "$CONTRACT" --psql "$STUB" --isolated --output-dir "$OUT_DIR/missing" >/dev/null 2>&1; then
  echo "reverse check failed: missing source DSN was accepted" >&2
  exit 1
fi

if READ_ONLY_STUB_ALLOW=INSERT python3 "$RUNNER" --contract "$CONTRACT" --psql "$STUB" --isolated --output-dir "$OUT_DIR/unsafe" >/dev/null 2>&1; then
  echo "reverse check failed: unexpected INSERT permission was accepted" >&2
  exit 1
fi

if python3 "$RUNNER" --contract "$CONTRACT" --psql "$STUB" --sqlite "$WRITABLE_SQLITE_STUB" --isolated --output-dir "$OUT_DIR/unsafe-sqlite" >/dev/null 2>&1; then
  echo "reverse check failed: writable SQLite source was accepted" >&2
  exit 1
fi

echo "read-only-pulls: pass six sources plus reverse checks"
