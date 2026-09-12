#!/usr/bin/env python3
"""Validate credential-free T-24 pull events before delivery to ⑦."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


EXPECTED_SOURCES = {"mkt", "ops", "backoffice", "knowledge", "automation", "el"}
REQUIRED_FIELDS = {
    "schema_version", "connector_id", "source_system", "target_system",
    "read_only", "credential_id", "scope", "snapshot_id", "observed_at",
    "source_revision", "status", "error_class", "record_count", "evidence_ref",
}
CREDENTIAL_REF = re.compile(r"^cred\.[a-z0-9][a-z0-9._-]*$")
SNAPSHOT_ID = re.compile(r"^snap-[0-9TZ]+$")
ERROR_CLASSES = {"transport_error", "permission_denied", "empty_data"}


def validate_event(item: dict[str, Any]) -> None:
    if set(item) != REQUIRED_FIELDS:
        raise ValueError("event fields are incomplete or unexpected")
    source_id = item.get("connector_id")
    if source_id not in EXPECTED_SOURCES:
        raise ValueError("event source is not one of the six declared sources")
    if item.get("schema_version") != 1:
        raise ValueError("event schema_version must be 1")
    if item.get("source_system") != source_id or item.get("target_system") != "audit":
        raise ValueError("event source or target is inconsistent")
    if item.get("read_only") is not True:
        raise ValueError("event must declare read_only=true")
    credential_id = item.get("credential_id")
    if not isinstance(credential_id, str) or CREDENTIAL_REF.fullmatch(credential_id) is None:
        raise ValueError("event credential_id must be a reference")
    if credential_id != f"cred.pull.{source_id}":
        raise ValueError("event credential_id does not match its source")
    if item.get("scope") != [f"{source_id}:read_only_probe"]:
        raise ValueError("event scope is inconsistent")
    snapshot_id = item.get("snapshot_id")
    if not isinstance(snapshot_id, str) or SNAPSHOT_ID.fullmatch(snapshot_id) is None:
        raise ValueError("event snapshot_id is invalid")
    observed_at = item.get("observed_at")
    if not isinstance(observed_at, str):
        raise ValueError("event observed_at is missing")
    try:
        datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("event observed_at is not an ISO timestamp") from exc
    if item.get("source_revision") != "contract:v2":
        raise ValueError("event source_revision is stale")
    status = item.get("status")
    error_class = item.get("error_class")
    record_count = item.get("record_count")
    if not isinstance(record_count, int) or record_count < 0:
        raise ValueError("event record_count is invalid")
    if status == "ok":
        if error_class is not None or record_count <= 0:
            raise ValueError("ok event must have data and no error")
    elif status == "error":
        if error_class not in ERROR_CLASSES:
            raise ValueError("error event has an unknown error_class")
    else:
        raise ValueError("event status is invalid")
    evidence_ref = item.get("evidence_ref")
    if evidence_ref != f"evidence:t24:{source_id}:{snapshot_id}":
        raise ValueError("event evidence_ref is inconsistent")


def validate_batch(items: list[dict[str, Any]]) -> None:
    if len(items) != len(EXPECTED_SOURCES):
        raise ValueError("exactly six pull events are required")
    for item in items:
        validate_event(item)
    sources = {item["connector_id"] for item in items}
    if sources != EXPECTED_SOURCES:
        raise ValueError("pull event sources are incomplete or duplicated")
    if len({item["snapshot_id"] for item in items}) != 1:
        raise ValueError("pull events must share one snapshot_id")
    if len({item["observed_at"] for item in items}) != 1:
        raise ValueError("pull events must share one observed_at")


def read_items(path: Path) -> list[dict[str, Any]]:
    paths = sorted(path.glob("*.json")) if path.is_dir() else [path]
    items: list[dict[str, Any]] = []
    for item_path in paths:
        try:
            payload = json.loads(item_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError("event JSON could not be read") from exc
        if not isinstance(payload, dict):
            raise ValueError("event JSON must be an object")
        items.append(payload)
    return items


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="one event JSON or a directory of six events")
    args = parser.parse_args()
    try:
        items = read_items(args.path)
        if args.path.is_dir():
            validate_batch(items)
            print("t24-events: pass sources=6")
        else:
            if len(items) != 1:
                raise ValueError("one event JSON is required")
            validate_event(items[0])
            print("t24-event: pass")
    except (OSError, TypeError, ValueError) as exc:
        print(f"t24-events: fail: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
