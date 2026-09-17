#!/usr/bin/env bash
# ISMS の定期処理が失敗したことを Codzilla へ知らせる（RUNTIME）。
#
# なぜメールで通知しないか: 通知したい失敗の1つが「メールが送れないこと」で、
# メールで知らせると循環する。実際 2026-09-08 に、送信も画面も
# **HTTP 200 のまま**壊れて 6 時間気づかれなかった。
#
# 経路は Vaultwarden の失敗通知と同じ `POST /api/infra-events`。
# あちらの実装（~/Projects/vaultwarden-infra/scripts/notify-failure.sh）に合わせてある。
# サーバ側は event と unit の対を許可リストで固定し、本文からコマンドを実行しない。
#
# systemd の OnFailure= から `%n`（失敗した unit 名）付きで呼ばれる。
set -euo pipefail
umask 077

unit="${1:-}"
case "$unit" in
  isms-mail-outbox.service)          event=isms.mail_outbox_failed ;;
  isms-web-session-rotate.service)   event=isms.web_session_rotate_failed ;;
  isms-mail-session-rotate.service)  event=isms.mail_session_rotate_failed ;;
  *) printf 'unsupported ISMS failure unit: %s\n' "$unit" >&2; exit 2 ;;
esac

TOKEN_FILE="${CODZILLA_INFRA_EVENTS_TOKEN_FILE:-/srv/vaultwarden/secrets/codzilla-infra-monitor.token}"
CODZILLA_URL="${CODZILLA_INFRA_EVENTS_URL:-http://127.0.0.1:18787/api/infra-events}"

occurred_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# **本文に秘密や可変の詳細を入れない。** どこを見ればよいかだけ書く。
summary="RUNTIMEの${unit}が失敗しました。systemctl --user status ${unit} と journal を確認してください。"

# トークンは所有者のみ読める通常ファイルであることを確かめてから読む。
if [ ! -f "$TOKEN_FILE" ] || [ -L "$TOKEN_FILE" ]; then
  printf 'infra-monitor token is missing or not a regular file: %s\n' "$TOKEN_FILE" >&2
  exit 1
fi
# stat -c '%a' は "600" のような**8進表記の文字列**を返す。bash の算術は
# 既定で10進として読むので、8# を付けないと 600(十進) & 0077 = 24 になり、
# 0600 の正しいファイルを「危険」と誤判定する（実機で踏んだ）。
token_mode="$(stat -c '%a' "$TOKEN_FILE")"
if [ "$(stat -c '%u' "$TOKEN_FILE")" != "$(id -u)" ] || (( (8#$token_mode & 0077) != 0 )); then
  printf 'infra-monitor token has unsafe ownership or mode\n' >&2
  exit 1
fi
token="$(tr -d '\r\n' < "$TOKEN_FILE")"
if [ -z "$token" ] || [ "${#token}" -gt 512 ]; then
  printf 'infra-monitor token is empty or too long\n' >&2
  exit 1
fi

payload="$(python3 -c '
import json, sys
event, unit, occurred_at, summary = sys.argv[1:5]
print(json.dumps({"event": event, "unit": unit, "occurred_at": occurred_at, "summary": summary}))
' "$event" "$unit" "$occurred_at" "$summary")"

# トークンは argv に置かない（ps に出る）。curl の設定ファイル経由で渡す。
curl_config="$(mktemp "${TMPDIR:-/tmp}/isms-alert-curl.XXXXXX")"
chmod 600 "$curl_config"
trap 'rm -f "$curl_config"' EXIT
printf 'header = "authorization: Bearer %s"\n' "$token" > "$curl_config"

status="$(curl --silent --show-error --max-time 15 \
  --config "$curl_config" \
  --header 'content-type: application/json' \
  --data "$payload" \
  --output /dev/null --write-out '%{http_code}' \
  "$CODZILLA_URL" || echo 000)"

if [ "$status" = "202" ] || [ "$status" = "200" ]; then
  printf 'notified Codzilla: %s (%s)\n' "$event" "$status"
else
  printf 'Codzilla notification failed: HTTP %s\n' "$status" >&2
  exit 1
fi
