#!/usr/bin/env bash
# 送信ワーカー用テナントセッションを期限前に更新する（RUNTIME）。
#
# Web 用と同じ仕組み（scripts/rotate_web_session.py）を、書き換えるキーだけ
# 変えて使う。ワーカーは常駐サービスではないので再起動もヘルスチェックも無い
# （ISMS_SESSION_RESTART=none）。
#
# これを入れないと、Web 側と同じ「24時間で切れて、以後ずっと静かに失敗する」
# 状態がもう1本増える。timer が2分ごとに失敗し続けても誰も気づけない。
set -euo pipefail

ENV_FILE=/opt/isms-platform/target-env/isms-mail.env
RELEASE=/opt/isms-platform/releases/isms/current

for path in "$ENV_FILE" "$RELEASE/scripts/rotate_web_session.py"; do
  [ -e "$path" ] || { echo "$path がありません" >&2; exit 1; }
done

export PGPASSFILE=/opt/isms-platform/.pgpass
export ISMS_SESSION_DSN="postgresql://auth_svc@127.0.0.1:15432/isms_dev"
export ISMS_SESSION_LOOKUP_DSN="postgresql://app_rw@127.0.0.1:15432/isms_dev"
export ISMS_SESSION_LOOKUP_ROLE=app_rw
export ROTATE_PSQL=psql
export ISMS_SESSION_ENV_PATH="$ENV_FILE"
export ISMS_SESSION_ENV_KEY=ISMS_MAIL_TENANT_TOKEN
export ISMS_SESSION_RESTART=none
export ISMS_SESSION_TTL="24 hours"

exec python3 "$RELEASE/scripts/rotate_web_session.py"
