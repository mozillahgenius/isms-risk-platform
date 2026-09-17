# -*- coding: utf-8 -*-
"""テナントを 1 つ作り、セッショントークンを発行する。

  python3 scripts/new_tenant.py --name "Example Organization" --domain example.invalid \
      --admin-email admin@example.invalid --admin-name "管理者"

作るもの: テナント / 管理者（CISO）/ 標準規程の展開（catalog に在る全数）/ セッション。

## 権限の分け方
- テナントの作成は **provisioner** ロールで `app.provision_tenant()` を呼ぶ。
  provisioner は表への権限を持たず、この関数を呼ぶことしかできない。
- セッションの発行は **auth_svc** ロールだけができる。
  app_rw に発行させると、業務用の接続が任意テナントのトークンを作れてしまう。

## トークンの扱い
標準出力へ 1 度だけ出す。**ファイルにもリポジトリにも書かない。**
DB にはハッシュしか残らないので、失くしたら作り直す（このスクリプトを再実行する）。
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
