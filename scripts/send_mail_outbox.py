#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Send mail queued in app.mail_outbox over SMTP.

  python3 scripts/send_mail_outbox.py --token "$ISMS_WEB_TENANT_TOKEN" --apply

The web process (management_web) holds no SMTP credentials. The UI only adds
rows to app.mail_outbox; the actual sending is done by this script in a
separate process with separate credentials. This keeps the ISMS target system
itself from directly holding an outbound channel (a mis-send cannot happen in
one click, and every send is always recorded in the queue).

## Does not send by default
Unless `--apply` is given, it only prints the recipient, subject and the start
of the body, then exits. The production timer calls it with `--apply`.

## Environment variables (values are written neither here nor in the repository)
  ISMS_SMTP_HOST      e.g. smtp.gmail.com
  ISMS_SMTP_PORT      default 587 (STARTTLS). 465 means SMTPS
  ISMS_SMTP_USER      SMTP auth user
  ISMS_SMTP_PASSWORD  SMTP auth password (app password)
  ISMS_SMTP_FROM      Sender. e.g. "Example ISMS <isms@example.com>"
  ISMS_SMTP_REPLY_TO  Optional. When the reply-to differs from the sender
  ISMS_DB             default isms_dev

## Failure handling
A row that fails to send keeps status='failed' and last_error, and later runs
pick it up again only with `--retry-failed`. This prevents silently retrying
forever and delivering many copies to the same recipient.
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
# Marker always attached to last_error of reclaimed rows. --retry-failed does not
# pick up rows carrying it (so mail that may have been delivered is never auto-resent).
UNCONFIRMED_MARK = '[unconfirmed]'
# The minimum reclaim threshold is enforced DB-side by app.reclaim_stale_mail() (60 minutes).
# One batch is at most MAX_BATCH mails x a 30-second SMTP timeout, so this leaves enough
# margin not to mistake rows held by a running worker for "stuck" ones.


# Dedicated role. app_rw cannot advance the send queue state (0059).
# Separation so that "permission to send" and "permission to write business data" are not held by one role.
WORKER_ROLE = 'mail_worker'


def dsn_for(db: str) -> str:
    template = os.environ.get('ISMS_CHECKER_DSN_TEMPLATE')
    if template:
        return template.format(db=db, user=WORKER_ROLE)
    return f'postgres:///{db}?user={WORKER_ROLE}'


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def context_stmt(token: str) -> str:
    """Establish the tenant context. **Call it in a form that returns no rows.**

    With `SELECT app.set_tenant_context(...)`, its return value (the tenant
    uuid) is mixed into the output as a result set. psql's record separator (-R)
    is not appended at the end of a result set, so it gets joined to the first
    row of the next result set by a single newline and the parser mistakes the
    uuid (hit in practice). A DO block returns no rows.
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
    """Receive the result as a single JSON value.

    Splitting columns and rows by separators (-F / -R) breaks parsing when the
    body or subject contains the same control characters, silently dropping rows
    (a dropped row stays with its status advanced and is never sent). With JSON,
    control characters inside strings are escaped, so separators and content never mix.
    """
    raw = psql(dsn, statements).strip()
    if not raw:
        return []
    return json.loads(raw)


def claim_batch(dsn: str, token: str, retry_failed: bool, retry_unconfirmed: bool,
                limit: int) -> list[dict[str, str]]:
    """Take the rows to send and advance them to status='sending' at the same time.

    Taking and updating state is done in one statement by app.claim_mail_batch()
    (SECURITY DEFINER). It can only be called from the mail_worker role, so the web
    side's app_rw cannot fabricate sent records. Contention is resolved by
    FOR UPDATE SKIP LOCKED inside the function.
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
    """Mark as sent only what actually went out. The questionnaire state also advances inside the function."""
    psql(dsn, [
        'BEGIN;',
        context_stmt(token),
        f"SELECT app.mark_mail_sent({sql_literal(row['id'])}::uuid);",
        'COMMIT;',
    ], tuples_only=False)


def try_mark_failed(dsn: str, token: str, row: dict[str, str], error: str) -> bool:
    """Record as failed. If recording itself fails, return False to tell the caller.

    Swallowing this would leave the row in sending, picked up neither by a normal run
    nor by --retry-failed (= it silently disappears)."""
    try:
        mark_failed(dsn, token, row, error)
        return True
    except Exception as exc:  # noqa: BLE001 - report the failure to record itself
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
    """Connect to SMTP. Always encrypted by default.

    ISMS_SMTP_STARTTLS=off is allowed **only for loopback destinations**. It is for
    setups where an internal relay runs on the same host, and for acceptance tests.
    If plaintext could be sent to an external relay, questionnaire contents would be
    exposed on the path as-is.
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
        # If the process dies right after claiming, the rows stay in sending and nobody
        # picks them up (a normal run only sees queued, --retry-failed only failed). Move
        # them to failed here so they become visible. **Do not resend.** The process may
        # have died after delivery, and an automatic resend would deliver twice.
        # The lower bound of the threshold (60 minutes) is enforced by app.reclaim_stale_mail().
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
        # Only peek, without claiming. Advancing status without --apply would
        # wipe out pending mail while you thought you were just checking.
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
    # Mail "delivered to the recipient but not recorded on our side". Not moved to failed:
    # doing so would deliver twice to the same recipient via --retry-failed. A human checks and decides.
    unrecorded: list[str] = []
    client: smtplib.SMTP | None = None
    try:
        client = connect(host, port, user, password)
    except Exception as exc:  # noqa: BLE001 - connection/auth failure. Nothing has been sent
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
            except Exception as exc:  # noqa: BLE001 - one failure does not stop the rest
                if try_mark_failed(dsn, args.token, row, f'{type(exc).__name__}: {exc}'):
                    failed += 1
                else:
                    unrecorded.append(row['id'])
                continue
            try:
                mark_sent(dsn, args.token, row)
            except Exception as exc:  # noqa: BLE001 - the send already happened
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
