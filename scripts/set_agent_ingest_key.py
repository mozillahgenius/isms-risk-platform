#!/usr/bin/env python3
"""Set the DB-side MAC key used by the trusted posture API boundary."""
from __future__ import annotations

import argparse
import os
import re
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
    parser.add_argument('--secret', default=os.environ.get('ISMS_AGENT_INGEST_SECRET'))
    parser.add_argument('--db', default=os.environ.get('ISMS_DB', 'isms_dev'))
    args = parser.parse_args()
    if not args.secret or not re.fullmatch(r'[0-9a-fA-F]{64}', args.secret):
        raise SystemExit('ISMS_AGENT_INGEST_SECRET must be exactly 64 hexadecimal characters')
    sql = f"SELECT app.set_agent_ingest_key(decode({sql_literal(args.secret)}, 'hex'))"
    result = subprocess.run(
        ['psql', '-At', '-v', 'ON_ERROR_STOP=1', '-q', '-d', dsn_for(args.db), '-c', sql],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f'agent ingest key setup failed: {result.stderr.strip()}')
    print('[agent-ingest-key] configured')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
