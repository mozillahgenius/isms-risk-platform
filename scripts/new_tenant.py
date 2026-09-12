# -*- coding: utf-8 -*-
"""Create one tenant and issue a session token.

  python3 scripts/new_tenant.py --name "Example Inc." --domain example.com \
      --admin-email alice@example.com --admin-name "Alice Example"

Creates: tenant / admin (CISO) / deployment of standard policies (all of those in catalog) / session.

## Privilege separation
- Tenant creation calls `app.provision_tenant()` as the **provisioner** role.
  provisioner has no table privileges and can only call this function.
- Only the **auth_svc** role can issue sessions.
  If app_rw issued them, a business connection could create tokens for any tenant.

## Token handling
Printed once to stdout. **Never written to a file or the repository.**
The DB keeps only the hash, so if it is lost, create a new one (re-run this script).
"""
from __future__ import annotations

import argparse
import os
import secrets
import subprocess
import sys

DEFAULT_TTL = '12 hours'


def dsn_for(db: str, user: str) -> str:
    tmpl = os.environ.get('ISMS_CHECKER_DSN_TEMPLATE')
    if tmpl:
        return tmpl.format(db=db, user=user)
    return f'postgres:///{db}?user={user}'


def sql_literal(v: str) -> str:
    return "'" + v.replace("'", "''") + "'"


def psql_must(dsn: str, sql: str, what: str) -> str:
    p = subprocess.run(['psql', '-At', '-v', 'ON_ERROR_STOP=1', '-q', '-d', dsn, '-c', sql],
                       capture_output=True, text=True)
    if p.returncode != 0:
        print(f'[new_tenant] {what} が失敗しました:\n{p.stderr.strip()}', file=sys.stderr)
        raise SystemExit(1)
    return p.stdout.strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--name', required=True)
    ap.add_argument('--domain', required=True)
    ap.add_argument('--admin-email', required=True)
    ap.add_argument('--admin-name', required=True)
    ap.add_argument('--fiscal-start-month', type=int, default=4)
    ap.add_argument('--industry-preset', default='general')
    ap.add_argument('--ttl', default=DEFAULT_TTL, help="セッションの有効期限（既定 '12 hours'）")
    ap.add_argument('--db', default=os.environ.get('ISMS_DB', 'isms_dev'))
    args = ap.parse_args()

    row = psql_must(
        dsn_for(args.db, 'provisioner'),
        "SELECT tenant_id||' '||user_id||' '||policies_expanded FROM app.provision_tenant("
        f"{sql_literal(args.name)}, {sql_literal(args.domain)}, {sql_literal(args.admin_email)},"
        f" {sql_literal(args.admin_name)}, {args.fiscal_start_month}::smallint,"
        f" {sql_literal(args.industry_preset)})",
        'テナントの作成')
    tenant_id, user_id, expanded = row.split()

    token = secrets.token_urlsafe(48)
    psql_must(
        dsn_for(args.db, 'auth_svc'),
        f"SELECT app.create_session('{tenant_id}'::uuid, '{user_id}'::uuid,"
        f" {sql_literal(token)}, {sql_literal(args.ttl)}::interval)",
        'セッションの発行')

    print(f'tenant_id: {tenant_id}')
    print(f'user_id:   {user_id}')
    print(f'規程の展開: {expanded} 本')
    print('')
    print('セッショントークン（この 1 回だけ表示。DB にはハッシュしか残らない）:')
    print(token)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
