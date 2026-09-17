#!/usr/bin/env python3
"""Execute the six T-24 read-only probes and emit credential-free events."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import validate_pull_sources
import validate_pull_events


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = ROOT / "connectors" / "read_only_sources.contract.json"
PROBE = ROOT / "scripts" / "read_only_role_probe.py"
SQLITE_PROBE = ROOT / "scripts" / "sqlite_read_only_probe.py"
SOURCES = ("mkt", "ops", "ssi", "kaname", "codzilla", "el")


def event(
    source_id: str,
    snapshot_id: str,
    observed_at: str,
    credential_id: str,
    status: str,
    error_class: str | None,
    record_count: int,
) -> dict:
    return {
        "schema_version": 1,
        "connector_id": source_id,
        "source_system": source_id,
        "target_system": "audit",
        "read_only": True,
        "credential_id": credential_id,
        "scope": [f"{source_id}:read_only_probe"],
        "snapshot_id": snapshot_id,
        "observed_at": observed_at,
        "source_revision": "contract:v2",
        "status": status,
        "error_class": error_class,
        "record_count": record_count,
        "evidence_ref": f"evidence:t24:{source_id}:{snapshot_id}",
    }


def write_event(output_dir: Path | None, item: dict) -> None:
    if output_dir is None:
        print(json.dumps(item, ensure_ascii=False, sort_keys=True))
        return
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / f"{item['connector_id']}.json"
    path.write_text(json.dumps(item, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def parse_probe_output(stdout: str) -> dict | None:
    for line in reversed(stdout.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and "source_id" in value:
            return value
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--psql", default="psql")
    parser.add_argument("--sqlite", default="sqlite3")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--isolated", action="store_true", help="required safety acknowledgement")
    args = parser.parse_args()

    if not args.isolated:
        print("t24-pull: unverified: --isolated is required", file=sys.stderr)
        return 2

    try:
        payload = json.loads(args.contract.read_text(encoding="utf-8"))
        validate_pull_sources.validate(payload)
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as exc:
        print(f"t24-pull: invalid contract: {exc}", file=sys.stderr)
        return 1

    rows = {row["source_id"]: row for row in payload["sources"]}
    observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    snapshot_id = "snap-" + observed_at.replace("-", "").replace(":", "").replace(".", "")
    failed = False
    events: list[dict] = []

    for source_id in SOURCES:
        row = rows[source_id]
        relation = os.environ.get(row["probe_relation_ref"].removeprefix("env:"))
        column = os.environ.get(row["probe_column_ref"].removeprefix("env:"))
        if not relation or not column:
            failed = True
            item = event(source_id, snapshot_id, observed_at, row["credential_ref"], "error", "transport_error", 0)
            events.append(item)
            write_event(args.output_dir, item)
            continue

        probe_script = PROBE if row["driver"] == "postgres" else SQLITE_PROBE
        driver_flag = "--psql" if row["driver"] == "postgres" else "--sqlite"
        command = [
            sys.executable,
            str(probe_script),
            "--source-id",
            source_id,
            "--dsn-env",
            row["dsn_env"],
            "--relation",
            relation,
            "--column",
            column,
            driver_flag,
            args.psql if row["driver"] == "postgres" else args.sqlite,
            "--isolated",
        ]
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
        probe = parse_probe_output(completed.stdout)
        try:
            count = int(probe.get("record_count", 0)) if probe else 0
        except (TypeError, ValueError):
            count = 0
            probe = None
        unexpected = probe.get("unexpected_operations", []) if probe else []
        if completed.returncode != 0 or unexpected:
            failed = True
            error_class = "permission_denied" if unexpected else "transport_error"
            item = event(source_id, snapshot_id, observed_at, row["credential_ref"], "error", error_class, count)
            events.append(item)
            write_event(args.output_dir, item)
        elif count == 0:
            failed = True
            item = event(source_id, snapshot_id, observed_at, row["credential_ref"], "error", "empty_data", 0)
            events.append(item)
            write_event(args.output_dir, item)
        else:
            item = event(source_id, snapshot_id, observed_at, row["credential_ref"], "ok", None, count)
            events.append(item)
            write_event(args.output_dir, item)

    try:
        validate_pull_events.validate_batch(events)
    except ValueError as exc:
        failed = True
        print(f"t24-pull: invalid event batch: {exc}", file=sys.stderr)

    print(f"t24-pull: {'fail' if failed else 'pass'} sources={len(SOURCES)}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
