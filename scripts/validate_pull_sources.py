#!/usr/bin/env python3
"""Validate the six-source read-only pull contract for T-24."""

import argparse
import json
import re
import sys
from pathlib import Path


EXPECTED_SOURCES = {"mkt", "ops", "ssi", "kaname", "codzilla", "el"}
DENIED = {"INSERT", "UPDATE", "DELETE", "TRUNCATE", "CREATE", "ALTER", "DROP"}
REQUIRED_TOP = {"schema_version", "status", "source_ref", "evidence_ref", "sources"}
REQUIRED_SOURCE = {
    "source_id",
    "driver",
    "access_mode",
    "credential_ref",
    "dsn_env",
    "probe_relation_ref",
    "probe_column_ref",
    "role_ref",
    "database_ref",
    "endpoint_ref",
    "read_only",
    "allowed_read_operations",
    "denied_operations",
    "evidence_ref",
}
SECRET_WORDS = {"password", "secret", "token", "private_key", "client_secret"}
DRIVERS = {"postgres", "sqlite"}
ACCESS_MODES = {"database_role", "filesystem_read_only"}
EXPECTED_STATUS = "runner_implemented_pending_runtime_access"
CREDENTIAL_REF = re.compile(r"^cred\.[a-z0-9][a-z0-9._-]*$")


def validate(payload: dict) -> None:
    if set(payload) != REQUIRED_TOP:
        raise ValueError("top-level fields must match the pull contract")
    if payload["schema_version"] != 1 or payload["status"] != EXPECTED_STATUS or not payload["source_ref"].strip() or not payload["evidence_ref"].strip():
        raise ValueError("schema_version/source/evidence are invalid")
    rows = payload["sources"]
    if not isinstance(rows, list) or len(rows) != len(EXPECTED_SOURCES):
        raise ValueError("exactly six pull sources are required")
    seen = set()
    for row in rows:
        if set(row) != REQUIRED_SOURCE:
            raise ValueError("source fields are incomplete or unexpected")
        source_id = row["source_id"]
        if source_id in seen or source_id not in EXPECTED_SOURCES:
            raise ValueError(f"unexpected or duplicate source: {source_id}")
        seen.add(source_id)
        if row["driver"] not in DRIVERS:
            raise ValueError(f"unsupported driver: {source_id}")
        if row["access_mode"] not in ACCESS_MODES:
            raise ValueError(f"unsupported access mode: {source_id}")
        if not isinstance(row["credential_ref"], str) or CREDENTIAL_REF.fullmatch(row["credential_ref"]) is None:
            raise ValueError(f"credential reference is invalid: {source_id}")
        if row["driver"] == "postgres" and row["access_mode"] != "database_role":
            raise ValueError(f"postgres source must use database_role: {source_id}")
        if row["driver"] == "sqlite" and row["access_mode"] != "filesystem_read_only":
            raise ValueError(f"sqlite source must use filesystem_read_only: {source_id}")
        if row["read_only"] is not True:
            raise ValueError(f"source is not read-only: {source_id}")
        if row["allowed_read_operations"] != ["SELECT"]:
            raise ValueError(f"read operations must be SELECT only: {source_id}")
        if set(row["denied_operations"]) != DENIED:
            raise ValueError(f"DML/DDL deny set is incomplete: {source_id}")
        for field in ("dsn_env", "probe_relation_ref", "role_ref", "database_ref", "endpoint_ref", "evidence_ref"):
            if not isinstance(row[field], str) or not row[field].strip():
                raise ValueError(f"{field} missing: {source_id}")
        if not row["dsn_env"].startswith("ISMS_PULL_DSN_") or not row["probe_relation_ref"].startswith("env:") or not row["probe_column_ref"].startswith("env:"):
            raise ValueError(f"live probe references are invalid: {source_id}")
        if row["driver"] == "postgres" and not row["role_ref"].startswith("role."):
            raise ValueError(f"postgres source role reference is invalid: {source_id}")
        if row["driver"] == "sqlite" and not row["role_ref"].startswith("fs."):
            raise ValueError(f"sqlite source filesystem reference is invalid: {source_id}")
        if any(word in json.dumps(row, ensure_ascii=False).lower() for word in SECRET_WORDS):
            raise ValueError(f"secret-like field in source contract: {source_id}")
    if seen != EXPECTED_SOURCES:
        raise ValueError(f"missing sources: {sorted(EXPECTED_SOURCES - seen)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    try:
        validate(json.loads(args.path.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as exc:
        print(f"pull-sources: fail: {exc}", file=sys.stderr)
        return 1
    print("pull-sources: pass sources=6 read=SELECT deny=7")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
