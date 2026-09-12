#!/usr/bin/env python3
"""Freeze or verify a tamper-evident manifest for one T-24 event snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

import validate_pull_events


MANIFEST_SCHEMA_VERSION = 1


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def event_files(event_dir: Path) -> dict[str, Path]:
    paths = sorted(event_dir.glob("*.json"))
    return {path.stem: path for path in paths}


def load_events(event_dir: Path) -> tuple[dict[str, Path], list[dict[str, Any]]]:
    files = event_files(event_dir)
    items = validate_pull_events.read_items(event_dir)
    validate_pull_events.validate_batch(items)
    return files, items


def freeze(event_dir: Path, manifest_path: Path) -> None:
    files, items = load_events(event_dir)
    if manifest_path.exists():
        raise ValueError("manifest already exists and will not be overwritten")
    snapshots = {item["snapshot_id"] for item in items}
    observed = {item["observed_at"] for item in items}
    manifest = {
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "event_schema_version": 1,
        "snapshot_id": snapshots.pop(),
        "observed_at": observed.pop(),
        "source_hashes": {source_id: digest(files[source_id]) for source_id in sorted(files)},
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with manifest_path.open("x", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
    print(f"t24-snapshot: frozen sources={len(files)}")


def verify(event_dir: Path, manifest_path: Path) -> None:
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError("manifest could not be read") from exc
    required = {"schema_version", "event_schema_version", "snapshot_id", "observed_at", "source_hashes"}
    if set(manifest) != required:
        raise ValueError("manifest fields are incomplete or unexpected")
    if manifest["schema_version"] != MANIFEST_SCHEMA_VERSION or manifest["event_schema_version"] != 1:
        raise ValueError("manifest schema version is unsupported")
    files, items = load_events(event_dir)
    if manifest["snapshot_id"] != items[0]["snapshot_id"] or manifest["observed_at"] != items[0]["observed_at"]:
        raise ValueError("manifest snapshot metadata does not match events")
    expected = manifest["source_hashes"]
    if set(expected) != set(files):
        raise ValueError("manifest source set does not match event files")
    for source_id, path in files.items():
        if expected[source_id] != digest(path):
            raise ValueError(f"event hash mismatch: {source_id}")
    print(f"t24-snapshot: pass sources={len(files)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("freeze", "verify"))
    parser.add_argument("event_dir", type=Path)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    try:
        if args.mode == "freeze":
            freeze(args.event_dir, args.manifest)
        else:
            verify(args.event_dir, args.manifest)
    except (OSError, TypeError, ValueError) as exc:
        print(f"t24-snapshot: fail: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
