#!/usr/bin/env python3
"""Run T-24 read-only permission probes against one isolated PostgreSQL source."""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path


IDENTIFIER = re.compile(r"^[a-z_][a-z0-9_]*(?:\.[a-z_][a-z0-9_]*)?$")
REFUSAL_WORDS = ("permission denied", "must be owner", "not have permission", "insufficient privilege")


def quote_relation(value: str) -> str:
    if not IDENTIFIER.fullmatch(value):
        raise ValueError("probe relation must be a simple schema.table identifier")
    return ".".join('"' + part + '"' for part in value.split("."))


def run_psql(psql: str, dsn: str, sql: str) -> tuple[int, str]:
    completed = subprocess.run(
        [psql, dsn, "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
        text=True,
        capture_output=True,
        check=False,
    )
    return completed.returncode, (completed.stderr + completed.stdout).lower()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-id", required=True)
    parser.add_argument("--dsn-env", required=True)
    parser.add_argument("--relation", required=True)
    parser.add_argument("--column", required=True, help="existing writable column used only in a rolled-back UPDATE")
    parser.add_argument("--psql", default="psql")
    parser.add_argument("--isolated", action="store_true", help="required safety acknowledgement")
    args = parser.parse_args()
    if not args.isolated:
        print("read-only-probe: unverified: --isolated is required", file=sys.stderr)
        return 2
    dsn = os.environ.get(args.dsn_env)
    if not dsn:
        print(f"read-only-probe: unverified: {args.dsn_env} is absent", file=sys.stderr)
        return 2
    try:
        relation = quote_relation(args.relation)
        column = quote_relation(args.column)
    except ValueError as exc:
        print(f"read-only-probe: fail: {exc}", file=sys.stderr)
        return 1

    read_rc, read_output = run_psql(args.psql, dsn, f"select count(*) from {relation};")
    if read_rc != 0:
        print(f"read-only-probe: fail source={args.source_id} read=failed", file=sys.stderr)
        return 1
    try:
        record_count = int(read_output.strip().splitlines()[-1])
    except (IndexError, ValueError):
        print(f"read-only-probe: fail source={args.source_id} count=invalid", file=sys.stderr)
        return 1

    statements = {
        "INSERT": f"begin; insert into {relation} default values; rollback;",
        "UPDATE": f"begin; update {relation} set {column} = {column} where false; rollback;",
        "DELETE": f"begin; delete from {relation} where false; rollback;",
        "TRUNCATE": f"begin; truncate table {relation}; rollback;",
        "ALTER": f"begin; alter table {relation} add column _pull_probe_col text; rollback;",
        "DROP": f"begin; drop table {relation}; rollback;",
    }
    # CREATE is tested in the declared schema and rolled back before commit.
    schema = args.relation.split(".", 1)[0] if "." in args.relation else "public"
    create_name = f'"_pull_probe_{args.source_id}"'
    statements["CREATE"] = f'begin; create table "{schema}".{create_name} (id integer); rollback;'
    failures = []
    for operation, sql in statements.items():
        rc, output = run_psql(args.psql, dsn, sql)
        if rc == 0 or not any(word in output for word in REFUSAL_WORDS):
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
