#!/usr/bin/env python3
"""Run T-24 read-only permission probes against a SQLite source."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys


IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
REFUSAL_WORDS = (
    "attempt to write a readonly database",
    "attempt to write a read-only database",
    "not authorized",
    "permission denied",
)


def quote_identifier(value: str) -> str:
    if not IDENTIFIER.fullmatch(value):
        raise ValueError("SQLite probe identifiers must be simple names")
    return '"' + value + '"'


def run_sql(sqlite: str, database: str, sql: str) -> tuple[int, str]:
    completed = subprocess.run(
        [sqlite, "-readonly", "-batch", "-bail", "-noheader", database, sql],
        text=True,
        capture_output=True,
        check=False,
    )
    return completed.returncode, (completed.stderr + completed.stdout).lower()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-id", required=True)
    parser.add_argument("--dsn-env", required=True, help="environment variable containing the SQLite path")
    parser.add_argument("--relation", required=True, help="SQLite table name")
    parser.add_argument("--column", required=True, help="existing column used only in a rolled-back UPDATE")
    parser.add_argument("--sqlite", default="sqlite3")
    parser.add_argument("--isolated", action="store_true", help="required safety acknowledgement")
    args = parser.parse_args()

    if not args.isolated:
        print("sqlite-read-only-probe: unverified: --isolated is required", file=sys.stderr)
        return 2
    database = os.environ.get(args.dsn_env)
    if not database:
        print(f"sqlite-read-only-probe: unverified: {args.dsn_env} is absent", file=sys.stderr)
        return 2
    try:
        relation = quote_identifier(args.relation)
        column = quote_identifier(args.column)
    except ValueError as exc:
        print(f"sqlite-read-only-probe: fail: {exc}", file=sys.stderr)
        return 1

    read_rc, read_output = run_sql(args.sqlite, database, f"select count(*) from {relation};")
    if read_rc != 0:
        print(f"sqlite-read-only-probe: fail source={args.source_id} read=failed", file=sys.stderr)
        return 1
    try:
        record_count = int(read_output.strip().splitlines()[-1])
    except (IndexError, ValueError):
        print(f"sqlite-read-only-probe: fail source={args.source_id} count=invalid", file=sys.stderr)
        return 1

    statements = {
        "INSERT": f"begin; insert into {relation} select * from {relation} where 0; rollback;",
        "UPDATE": f"begin; update {relation} set {column} = {column} where 0; rollback;",
        "DELETE": f"begin; delete from {relation} where 0; rollback;",
        "TRUNCATE": f"begin; truncate table {relation}; rollback;",
        "CREATE": f'begin; create table "_pull_probe_{args.source_id}" (id integer); rollback;',
        "ALTER": f"begin; alter table {relation} add column _pull_probe_col text; rollback;",
        "DROP": f"begin; drop table {relation}; rollback;",
    }
    failures = []
    for operation, sql in statements.items():
        rc, output = run_sql(args.sqlite, database, sql)
        unsupported_truncate = operation == "TRUNCATE" and rc != 0 and "syntax error" in output
        refused = any(word in output for word in REFUSAL_WORDS)
        if rc == 0 or not (refused or unsupported_truncate):
            failures.append(operation)

    result = {
        "source_id": args.source_id,
        "read": "pass",
        "record_count": record_count,
        "denied_operations": sorted(set(statements) - set(failures)),
        "unexpected_operations": failures,
    }
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
