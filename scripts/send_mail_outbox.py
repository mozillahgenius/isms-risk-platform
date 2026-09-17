#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""app.mail_outbox に積まれたメールを SMTP で送る。

  python3 scripts/send_mail_outbox.py --token "$ISMS_WEB_TENANT_TOKEN" --apply

Web プロセス（management_web）は SMTP 資格情報を持たない。画面は
app.mail_outbox に行を足すだけで、実際の送信はこのスクリプトが別プロセス・
別資格情報で行う。ISMS の対象システム自身が社外への送信口を直接握らない形に
しておくため（誤送信を 1 クリックで起こせない・送信の記録が必ずキューに残る）。

## 既定は送らない
`--apply` を付けない限り、宛先・件名・本文の先頭だけを表示して終わる。
本番の timer は `--apply` を付けて呼ぶ。

## 環境変数（値はここにもリポジトリにも書かない）
  ISMS_SMTP_HOST      例 smtp.gmail.com
  ISMS_SMTP_PORT      既定 587（STARTTLS）。465 を指定すると SMTPS
  ISMS_SMTP_USER      SMTP 認証のユーザー
  ISMS_SMTP_PASSWORD  SMTP 認証のパスワード（アプリパスワード）
  ISMS_SMTP_FROM      差出人。例 "Example Organization ISMS <automation@example.com>"
  ISMS_SMTP_REPLY_TO  任意。返信先を差出人と分ける場合
  ISMS_DB             既定 isms_dev

## 失敗の扱い
送信に失敗した行は status='failed' と last_error を残し、次回以降は
`--retry-failed` を付けたときだけ拾い直す。黙って再送し続けて同じ相手へ
何通も届く事故を防ぐ。
"""
from __future__ import annotations

import argparse
import json
import os
import smtplib
import ssl
import subprocess
import sys
from email.message import EmailMessage
from email.utils import formataddr, parseaddr

MAX_BATCH = 50
# 回収した行の last_error に必ず付ける印。--retry-failed はこの印の付いた行を
# 拾わない（届いたかもしれないものを自動で送り直さないため）。
UNCONFIRMED_MARK = '[unconfirmed]'
# 回収の最短しきい値は app.reclaim_stale_mail() が DB 側で強制する（60 分）。
# 1 バッチは最大 MAX_BATCH 通 × SMTP タイムアウト 30 秒なので、実行中の
# ワーカーが掴んでいる行を「止まっている」と誤認しないだけの幅を取っている。


# 専用ロール。app_rw では送信キューの状態を進められない（0059）。
# 「送る権限」と「業務データを書く権限」を同じロールに持たせないための分離。
WORKER_ROLE = 'mail_worker'


def dsn_for(db: str) -> str:
    template = os.environ.get('ISMS_CHECKER_DSN_TEMPLATE')
    if template:
        return template.format(db=db, user=WORKER_ROLE)
    return f'postgres:///{db}?user={WORKER_ROLE}'


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def context_stmt(token: str) -> str:
    """テナント文脈を立てる。**行を返さない形で呼ぶ。**

    `SELECT app.set_tenant_context(...)` にすると、その戻り値（テナントの
    uuid）が結果集合として出力に混ざる。psql のレコード区切り（-R）は
    結果集合の末尾には付かないので、次の結果集合の 1 行目と改行 1 つで
    つながってしまい、解析側が uuid を取り違える（実測で踏んだ）。
    DO ブロックなら行を返さない。
    """
    return f'DO $ctx$ BEGIN PERFORM app.set_tenant_context({sql_literal(token)}); END $ctx$;'


def psql(dsn: str, statements: list[str], tuples_only: bool = True) -> str:
    args = ['psql', '-v', 'ON_ERROR_STOP=1', '-X', '-q', '-d', dsn]
    if tuples_only:
        args += ['-At']
    args += ['-c', ' '.join(statements)]
    done = subprocess.run(args, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(done.stderr.strip() or 'psql failed')
    return done.stdout


def psql_json(dsn: str, statements: list[str]) -> list[dict[str, object]]:
    """結果を JSON 1 値で受け取る。

    区切り文字（-F / -R）で列と行を切ると、本文や件名に同じ制御文字が入った
    ときに解析が破綻し、行を黙って捨てることになる（捨てられた行は status を
    進めたまま残り、二度と送られない）。JSON なら文字列の中の制御文字は
    エスケープされるので、区切りと中身が混ざらない。
    """
    raw = psql(dsn, statements).strip()
    if not raw:
        return []
    return json.loads(raw)


def claim_batch(dsn: str, token: str, retry_failed: bool, retry_unconfirmed: bool,
                limit: int) -> list[dict[str, str]]:
    """送る対象を取り出し、同時に status='sending' へ進める。

    取り出しと状態の更新は app.claim_mail_batch()（SECURITY DEFINER）が 1 文で行う。
    mail_worker ロールからしか呼べないので、Web 側の app_rw では送信済みの記録を
    でっち上げられない。取り合いは関数の中の FOR UPDATE SKIP LOCKED が解決する。
    """
    rows = psql_json(dsn, [
        'BEGIN;',
        context_stmt(token),
        f'SELECT app.claim_mail_batch({int(limit)},'
        f" {'true' if retry_failed else 'false'},"
        f" {'true' if retry_unconfirmed else 'false'});",
        'COMMIT;',
    ])
    return [{str(k): str(v) for k, v in row.items()} for row in rows]


def mark_sent(dsn: str, token: str, row: dict[str, str]) -> None:
    """実際に出たものだけを送信済みにする。質問票の状態も関数の中で進む。"""
    psql(dsn, [
        'BEGIN;',
        context_stmt(token),
        f"SELECT app.mark_mail_sent({sql_literal(row['id'])}::uuid);",
        'COMMIT;',
    ], tuples_only=False)


def try_mark_failed(dsn: str, token: str, row: dict[str, str], error: str) -> bool:
    """失敗として記録する。記録自体に失敗したら False を返して呼び出し元へ知らせる。

    ここを握りつぶすと、行が sending のまま残り、通常実行でも --retry-failed でも
    拾われない（＝黙って消える）。"""
    try:
        mark_failed(dsn, token, row, error)
        return True
    except Exception as exc:  # noqa: BLE001 - 記録できないこと自体を報告する
        print(
            f"失敗の記録にも失敗: id={row['id']} 宛先={row['to_email']} "
            f'({type(exc).__name__}: {exc})。sending のまま残る。'
            '--reclaim-stale で回収してください。',
            file=sys.stderr,
        )
        return False


def mark_failed(dsn: str, token: str, row: dict[str, str], error: str) -> None:
    psql(dsn, [
        'BEGIN;',
        context_stmt(token),
        f"SELECT app.mark_mail_failed({sql_literal(row['id'])}::uuid,"
        f' {sql_literal(error)});',
        'COMMIT;',
    ], tuples_only=False)


def build_message(row: dict[str, str], sender: str, reply_to: str | None) -> EmailMessage:
    message = EmailMessage()
    message['From'] = sender
    message['To'] = formataddr((row['to_name'], row['to_email'])) if row['to_name'] else row['to_email']
    message['Subject'] = row['subject']
    if reply_to:
        message['Reply-To'] = reply_to
    message.set_content(row['body_text'])
    return message


LOOPBACK_HOSTS = {'127.0.0.1', '::1', 'localhost'}


def connect(host: str, port: int, user: str, password: str) -> smtplib.SMTP:
    """SMTP へ繋ぐ。既定は必ず暗号化する。

    ISMS_SMTP_STARTTLS=off は **ループバック宛のときだけ** 許す。社内リレーが
    同じホストに居る構成と、受入テストのためのもの。外部の中継サーバーへ
    平文で流せてしまうと、質問票の中身がそのまま経路上に出る。
    """
    context = ssl.create_default_context()
    ca_file = os.environ.get('ISMS_SMTP_CA_FILE')
    if ca_file:
        context = ssl.create_default_context(cafile=ca_file)
    mode = os.environ.get('ISMS_SMTP_STARTTLS', 'require')
    if mode == 'off' and host not in LOOPBACK_HOSTS:
        raise RuntimeError('ISMS_SMTP_STARTTLS=off はループバック宛にしか使えません')
    if port == 465:
        client: smtplib.SMTP = smtplib.SMTP_SSL(host, port, timeout=30, context=context)
    else:
        client = smtplib.SMTP(host, port, timeout=30)
        client.ehlo()
        if mode != 'off':
            client.starttls(context=context)
            client.ehlo()
    client.login(user, password)
    return client


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--token', required=True, help='テナントセッショントークン')
    parser.add_argument('--db', default=os.environ.get('ISMS_DB', 'isms_dev'))
    parser.add_argument('--dsn', default=os.environ.get('ISMS_MAIL_DATABASE_URL'),
                        help='接続先を明示する（既定はローカルソケットへ mail_worker で接続）。'
                             'mail_worker 以外のロールでは送信キューを進められない')
    parser.add_argument('--apply', action='store_true', help='実際に送信する。付けなければ内容を出すだけ')
    parser.add_argument('--retry-failed', action='store_true', help='失敗済みの行も拾い直す')
    parser.add_argument('--retry-unconfirmed', action='store_true',
                        help='--reclaim-stale で回収した「送られたか分からない」行も再送する'
                             '（相手に二度届く可能性があるので、実物を確かめてから）')
    parser.add_argument('--reclaim-stale', type=int, metavar='MINUTES',
                        help='指定分より古い sending の行を failed へ落として回収する'
                             '（送信済みかもしれないので自動再送はしない。人が確かめて --retry-failed）')
    parser.add_argument('--limit', type=int, default=MAX_BATCH)
    args = parser.parse_args()

    limit = max(1, min(args.limit, MAX_BATCH))
    dsn = args.dsn or dsn_for(args.db)

    if args.reclaim_stale is not None:
        # 取り出した直後にプロセスが落ちると、行は sending のまま誰にも拾われない
        # （通常実行は queued、--retry-failed は failed しか見ない）。ここで
        # failed へ落として見えるようにする。**再送はしない。** 相手に届いた
        # 後で落ちた可能性があり、自動で送り直すと二重に届く。
        # しきい値の下限（60分）は app.reclaim_stale_mail() が強制する。
        try:
            moved = psql_json(dsn, [
                'BEGIN;',
                context_stmt(args.token),
                f'SELECT app.reclaim_stale_mail({int(args.reclaim_stale)});',
                'COMMIT;',
            ])
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        print(f'sending のまま止まっていた {len(moved)} 件を failed へ移しました。'
              f'{UNCONFIRMED_MARK} の印が付いており、--retry-failed では拾いません。'
              '実際に届いたかを確かめたうえで --retry-unconfirmed を付けて再送してください')
        return 0

    if not args.apply:
        # 取り出さずに覗くだけ。--apply 無しで status を進めてしまうと、
        # 確認したつもりが送信待ちを消すことになる。
        pending = psql_json(dsn, [
            'BEGIN;',
            context_stmt(args.token),
            "SELECT coalesce(json_agg(json_build_object("
            "  'id', id::text, 'status', status, 'to_email', to_email::text,"
            "  'subject', subject, 'last_error', last_error)"
            ' ORDER BY queued_at), \'[]\'::json) FROM ('
            '  SELECT * FROM app.mail_outbox'
            "   WHERE tenant_id=app.current_tenant() AND status IN ('queued','failed','sending')"
            f'   ORDER BY queued_at LIMIT {limit}) t;',
            'COMMIT;',
        ])
        print(f'[dry-run] 送信待ち・要確認 {len(pending)} 件（--apply で送信）')
        for record in pending:
            note = str(record.get('last_error') or '')
            print(f"  {record.get('id')}  {record.get('status')}  {record.get('to_email')}"
                  + (f'  {note}' if note else ''))
        print('  ※ sending のまま残っているものは --reclaim-stale <分> で回収できます')
        return 0

    host = os.environ.get('ISMS_SMTP_HOST', '')
    port = int(os.environ.get('ISMS_SMTP_PORT', '587'))
    user = os.environ.get('ISMS_SMTP_USER', '')
    password = os.environ.get('ISMS_SMTP_PASSWORD', '')
    sender = os.environ.get('ISMS_SMTP_FROM', '')
    reply_to = os.environ.get('ISMS_SMTP_REPLY_TO') or None
    missing = [name for name, value in (
        ('ISMS_SMTP_HOST', host), ('ISMS_SMTP_USER', user),
        ('ISMS_SMTP_PASSWORD', password), ('ISMS_SMTP_FROM', sender),
    ) if not value]
    if missing:
        print('SMTP 設定が足りません: ' + ', '.join(missing), file=sys.stderr)
        return 2
    if not parseaddr(sender)[1]:
        print('ISMS_SMTP_FROM がメールアドレスとして読めません', file=sys.stderr)
        return 2

    rows = claim_batch(dsn, args.token, args.retry_failed, args.retry_unconfirmed, limit)
    if not rows:
        print('送信待ちはありません')
        return 0

    sent = 0
    failed = 0
    # 「相手には届いたが、こちらの記録に書けなかった」もの。failed に落とさない。
    # 落とすと --retry-failed で同じ相手へ二度届く。人が実物を確かめて決める。
    unrecorded: list[str] = []
    client: smtplib.SMTP | None = None
    try:
        client = connect(host, port, user, password)
    except Exception as exc:  # noqa: BLE001 - 接続・認証の失敗。1 通も送っていない
        for row in rows:
            if not try_mark_failed(dsn, args.token, row, f'{type(exc).__name__}: {exc}'):
                unrecorded.append(row['id'])
        print(f'SMTP へ接続できませんでした: {type(exc).__name__}: {exc}', file=sys.stderr)
        print(f'送信 0 件 / 失敗 {len(rows)} 件')
        return 1

    try:
        for row in rows:
            try:
                client.send_message(build_message(row, sender, reply_to))
            except Exception as exc:  # noqa: BLE001 - 1 通の失敗で残りを止めない
                if try_mark_failed(dsn, args.token, row, f'{type(exc).__name__}: {exc}'):
                    failed += 1
                else:
                    unrecorded.append(row['id'])
                continue
            try:
                mark_sent(dsn, args.token, row)
            except Exception as exc:  # noqa: BLE001 - 送信は済んでいる
                unrecorded.append(row['id'])
                print(
                    f"送信済みだが記録に失敗: id={row['id']} 宛先={row['to_email']} "
                    f'({type(exc).__name__}: {exc})。'
                    'この行は sending のまま残す。再送すると二重に届く。',
                    file=sys.stderr,
                )
                continue
            sent += 1
    finally:
        try:
            client.quit()
        except Exception:  # noqa: BLE001
            pass

    if unrecorded:
        print('記録できなかった送信: ' + ', '.join(unrecorded), file=sys.stderr)
    print(f'送信 {sent} 件 / 失敗 {failed} 件 / 記録漏れ {len(unrecorded)} 件')
    return 0 if failed == 0 and not unrecorded else 1


if __name__ == '__main__':
    raise SystemExit(main())
