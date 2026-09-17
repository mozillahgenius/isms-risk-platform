#!/usr/bin/env bash
# app.mail_outbox に溜まったメールを送る。systemd timer から呼ぶ。
#
# Web（management_web）は SMTP 資格情報を持たない。この 1 本だけが
# SMTP の鍵を読み、送信の実行を担う。DB へは専用ロール mail_worker で繋ぐ
# （app_rw では送信キューの状態を進められない。0059）。
set -euo pipefail

set -a
source /opt/isms-platform/target-env/isms.env
source /opt/isms-platform/target-env/isms-mail.env
set +a

# 送信先を間違えないための最低限の外形確認。空のまま timer が回り続けると、
# 「送ったつもりで 1 通も出ていない」に気づけない。
for name in ISMS_SMTP_HOST ISMS_SMTP_USER ISMS_SMTP_PASSWORD ISMS_SMTP_FROM \
            ISMS_MAIL_TENANT_TOKEN ISMS_MAIL_DATABASE_URL; do
  if [ -z "${!name:-}" ]; then
    echo "$name が未設定のため送信しません" >&2
    exit 1
  fi
done
# 送信キューを進められるのは mail_worker だけ（0059）。別ロールの DSN を
# 渡しても関数呼び出しで落ちるが、原因が分かる形で先に止める。
case "$ISMS_MAIL_DATABASE_URL" in
  *mail_worker*) ;;
  *) echo "mail DB ロールが mail_worker ではありません" >&2; exit 1;;
esac
case "${ISMS_SMTP_STARTTLS:-require}" in
  require|'') ;;
  *) echo "本番では STARTTLS を外さない（ISMS_SMTP_STARTTLS=${ISMS_SMTP_STARTTLS}）" >&2; exit 1;;
esac

cd /opt/isms-platform/releases/isms/current
# `secrets.token_urlsafe()` may produce a token beginning with `-`. Passing
# the value as a separate argparse argument then makes it look like an
# option and the worker exits with "expected one argument". Keep it attached
# to the option name so every valid session token is accepted.
exec python3 scripts/send_mail_outbox.py \
  "--token=$ISMS_MAIL_TENANT_TOKEN" \
  --dsn "$ISMS_MAIL_DATABASE_URL" \
  --apply
