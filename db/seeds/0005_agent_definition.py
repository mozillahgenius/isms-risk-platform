#!/usr/bin/env python3
"""Project the reviewed isms-agent definition into catalog.agent_definitions."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEFINITION = ROOT / 'agent' / 'internal' / 'definition' / 'v2.json'
ROLLBACK_DEFINITION = ROOT / 'agent' / 'internal' / 'definition' / 'v1.json'


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def main() -> int:
    raw = DEFINITION.read_bytes()
    document = json.loads(raw)
    rollback_raw = ROLLBACK_DEFINITION.read_bytes()
    rollback_document = json.loads(rollback_raw)
    items = document.get('items', [])
    names = [item.get('name') for item in items]
    expected = [
        'disk_encrypted', 'screen_lock', 'os_version', 'patch_current',
        'auto_update_checks_enabled', 'firewall_enabled', 'edr_running',
        'edr_vendor', 'builtin_protection', 'admin_account_count',
        'password_manager_installed', 'unapproved_apps',
        'device_identity', 'off_premise',
    ]
    if document.get('version') != 2 or document.get('platform') != 'macos' or names != expected:
        raise SystemExit('[agent-definition] v2 macOS collector definition shape is invalid')
    if rollback_document.get('version') != 1 or rollback_document.get('platform') != 'macos':
        raise SystemExit('[agent-definition] v1 macOS rollback definition is invalid')

    digest = hashlib.sha256(raw).hexdigest()
    definition_json = json.dumps(document, ensure_ascii=False, separators=(',', ':'))
    rollback_digest = hashlib.sha256(rollback_raw).hexdigest()
    rollback_json = json.dumps(rollback_document, ensure_ascii=False, separators=(',', ':'))
    db = os.environ.get('DATABASE_URL') or os.environ.get('ISMS_DB', 'isms_dev')
    sql = f"""
SET ROLE schema_owner;
BEGIN;
INSERT INTO catalog.agent_definitions
  (version, platform, definition, definition_hash, active)
VALUES
  (1, 'macos', {sql_literal(rollback_json)}::jsonb,
   decode({sql_literal(rollback_digest)}, 'hex'), false),
  (2, 'macos', {sql_literal(definition_json)}::jsonb,
   decode({sql_literal(digest)}, 'hex'), true)
ON CONFLICT (version, platform) DO UPDATE SET
  definition = EXCLUDED.definition,
  definition_hash = EXCLUDED.definition_hash,
  active = EXCLUDED.active;
UPDATE catalog.agent_definitions
   SET active = (version = 2 AND platform = 'macos');
COMMIT;
"""
    result = subprocess.run(
        ['psql', '-v', 'ON_ERROR_STOP=1', '-q', '-d', db, '-f', '-'],
        input=sql, text=True,
    )
    if result.returncode != 0:
        return result.returncode
    print(f'[agent-definition] macos v1 rollback ← {ROLLBACK_DEFINITION.relative_to(ROOT)} sha256={rollback_digest[:12]}…')
    print(f'[agent-definition] macos v2 active ← {DEFINITION.relative_to(ROOT)} sha256={digest[:12]}…')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
