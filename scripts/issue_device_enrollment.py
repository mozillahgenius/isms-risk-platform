#!/usr/bin/env python3
"""Issue one short-lived device enrollment token.

Only the hash is stored by the database function. The plaintext token is
printed once for the operator to pass to isms-agent enroll.
"""
from __future__ import annotations

import argparse
import os
import secrets
import subprocess


def dsn_for(db: str) -> str:
    template = os.environ.get('ISMS_AGENT_PROVISIONER_DSN_TEMPLATE')
    if template:
        return template.format(db=db, user='provisioner')
    return f'postgres:///{db}?user=provisioner'


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--tenant-id', required=True)
    parser.add_argument('--ttl', default='24 hours')
    parser.add_argument('--db', default=os.environ.get('ISMS_DB', 'isms_dev'))
    args = parser.parse_args()

    token = secrets.token_urlsafe(48)
    sql = (
        'SELECT app.issue_device_enrollment_token('
        f"{sql_literal(args.tenant_id)}::uuid, {sql_literal(token)}, "
        f"{sql_literal(args.ttl)}::interval)"
    )
    result = subprocess.run(
        ['psql', '-At', '-v', 'ON_ERROR_STOP=1', '-q', '-d', dsn_for(args.db), '-c', sql],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f'enrollment token issuance failed: {result.stderr.strip()}')
    print(token)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
