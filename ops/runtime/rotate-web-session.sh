#!/usr/bin/env bash
# Web 用テナントセッションを期限前に更新する（RUNTIME）。
#
# 画面の読み取りは全部このサーバ保持トークンに依存している。切れると
# 全ページが「テナントセッションまたは信頼済みの利用者識別が必要です」に
# なるが、**HTTP は 200 のまま**なので死活監視では気づけない。
# 2026-09-08 09:23 JST に実際に切れて、約6時間気づかれなかった。
#
# 既存の scripts/rotate_web_session.py を環境変数で振って使う（機ごとに
# スクリプトを分けない）。順序は発行→書換→再起動→ヘルス合格→旧revoke で、
# 途中で失敗したら旧トークンへ戻す。
set -euo pipefail

ENV_FILE=/opt/isms-platform/target-env/isms.env
RELEASE=/opt/isms-platform/releases/isms/current

for path in "$ENV_FILE" "$RELEASE/scripts/rotate_web_session.py"; do
  [ -e "$path" ] || { echo "$path がありません" >&2; exit 1; }
done

# セッションの発行・失効は auth_svc の役目（0006 の設計。app_rw にはやらせない）。
# パスワードは /opt/isms-platform/.pgpass から取る（値をここに書かない）。
export PGPASSFILE=/opt/isms-platform/.pgpass
export ISMS_SESSION_DSN="postgresql://auth_svc@127.0.0.1:15432/isms_dev"
# テナント・利用者の引き継ぎだけは app_rw で行う。app.sessions は 0005 で
# 定義者専用と決めてあり、auth_svc にも表の権限が無いため、
# 文脈関数（set_tenant_context → current_tenant / current_session_user）を通す。
export ISMS_SESSION_LOOKUP_DSN="postgresql://app_rw@127.0.0.1:15432/isms_dev"
export ISMS_SESSION_LOOKUP_ROLE=app_rw
export ROTATE_PSQL=psql
export ISMS_SESSION_ENV_PATH="$ENV_FILE"
export ISMS_SESSION_ENV_KEY=ISMS_WEB_TENANT_TOKEN
export ISMS_SESSION_RESTART=systemctl
export ISMS_SESSION_SERVICE=isms-runtime.service
export ISMS_SESSION_HEALTH_URL=http://127.0.0.1:13110/settings
# TTL は Mac 版と同じ24時間。timer は6時間ごとなので、1〜2回失敗しても間に合う。
export ISMS_SESSION_TTL="24 hours"

exec python3 "$RELEASE/scripts/rotate_web_session.py"
