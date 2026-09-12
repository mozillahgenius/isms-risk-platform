#!/usr/bin/env python3
"""Validate T-24 runtime wiring without connecting to any source."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

import validate_pull_sources


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = ROOT / "connectors" / "read_only_sources.contract.json"
POSTGRES_IDENTIFIER = re.compile(r"^[a-z_][a-z0-9_]*(?:\.[a-z_][a-z0-9_]*)?$")
SQLITE_IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def command_available(command: str) -> bool:
    if os.path.sep in command:
        path = Path(command)
        return path.is_file() and os.access(path, os.X_OK)
    return shutil.which(command) is not None


def validate_runtime(payload: dict, environ: dict[str, str], psql: str, sqlite: str) -> list[str]:
    validate_pull_sources.validate(payload)
    issues: list[str] = []
    checked_commands: set[str] = set()
    for row in payload["sources"]:
        source_id = row["source_id"]
        dsn_name = row["dsn_env"]
        relation_name = row["probe_relation_ref"].removeprefix("env:")
        column_name = row["probe_column_ref"].removeprefix("env:")
        dsn = environ.get(dsn_name)
        relation = environ.get(relation_name)
        column = environ.get(column_name)
        if not dsn:
            issues.append(f"{source_id}: missing {dsn_name}")
        if not relation:
            issues.append(f"{source_id}: missing {relation_name}")
        if not column:
            issues.append(f"{source_id}: missing {column_name}")
        if relation and column:
            identifier = POSTGRES_IDENTIFIER if row["driver"] == "postgres" else SQLITE_IDENTIFIER
            if identifier.fullmatch(relation) is None:
                issues.append(f"{source_id}: invalid probe relation in {relation_name}")
            if identifier.fullmatch(column) is None:
                issues.append(f"{source_id}: invalid probe column in {column_name}")
        command = psql if row["driver"] == "postgres" else sqlite
        if command not in checked_commands:
            checked_commands.add(command)
            if not command_available(command):
                issues.append(f"{row['driver']}: driver is unavailable")
        if row["driver"] == "sqlite" and dsn:
            database = Path(dsn)
            if not database.is_file():
                issues.append(f"{source_id}: SQLite source path is not a file")
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--psql", default="psql")
    parser.add_argument("--sqlite", default="sqlite3")
    parser.add_argument("--isolated", action="store_true", help="required safety acknowledgement")
    args = parser.parse_args()
    if not args.isolated:
        print("t24-preflight: unverified: --isolated is required", file=sys.stderr)
        return 2
    try:
        payload = json.loads(args.contract.read_text(encoding="utf-8"))
        issues = validate_runtime(payload, dict(os.environ), args.psql, args.sqlite)
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as exc:
        print(f"t24-preflight: fail: {exc}", file=sys.stderr)
        return 1
    if issues:
        for issue in issues:
            print(f"t24-preflight: fail: {issue}", file=sys.stderr)
        return 1
    print("t24-preflight: pass sources=6 connections=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
