#!/usr/bin/env bash
set -euo pipefail

SSH_HOST="${SSH_HOST:-sakura-fx}"
REMOTE_CONF="${REMOTE_CONF:-/etc/nginx/sites-enabled/management.example.invalid}"
REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-/home/ubuntu/isms-management-nginx-backups}"
UPSTREAM="${UPSTREAM:-100.107.40.5:3110}"

remote_backup=""
published=0

rollback() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ "$published" == "1" && -n "$remote_backup" ]]; then
    ssh "$SSH_HOST" "sudo install -m 644 '$remote_backup' '$REMOTE_CONF' && sudo nginx -t && sudo systemctl reload nginx" \
      || printf '[NG] automatic rollback failed; restore %s to %s\n' "$remote_backup" "$REMOTE_CONF" >&2
  fi
  exit "$status"
}

if [[ "${1:-}" == "--self-test" && $# == 1 ]]; then
  script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  python3 - "$script_path" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
for marker in (
    "location = /oauth2/auth {",
    "auth_request /oauth2/auth;",
    "error_page 401 = @management_oauth2_start;",
    "location @management_oauth2_start {",
    "proxy_set_header X-Forwarded-Email $management_email;",
):
    if marker not in text:
        raise SystemExit(f"missing marker: {marker}")
print("management nginx auth self-test passed")
PY
  exit 0
fi

if [[ $# != 0 ]]; then
  printf 'usage: %s [--self-test]\n' "$0" >&2
  exit 2
fi

stamp="$(date +%Y%m%d-%H%M%S)"
remote_backup="$REMOTE_BACKUP_DIR/management.example.invalid.bak-oauth-auth-$stamp"
trap rollback EXIT INT TERM HUP

ssh "$SSH_HOST" "sudo install -d -m 700 '$REMOTE_BACKUP_DIR'"
ssh "$SSH_HOST" "sudo cp -p '$REMOTE_CONF' '$remote_backup'"

ssh "$SSH_HOST" "sudo python3 - '$REMOTE_CONF' '$UPSTREAM'" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
upstream = sys.argv[2]
text = path.read_text()

if "location = /oauth2/auth {" in text or "auth_request /oauth2/auth;" in text:
    raise SystemExit("management nginx auth flow is already installed")

secret_match = re.search(
    r"(?m)^\s*proxy_set_header x-ib-device-control-proxy-secret [^;]+;\s*$",
    text,
)
if not secret_match:
    raise SystemExit("trusted proxy secret header is missing from the existing config")
secret_line = secret_match.group(0).strip()

marker = "    # All other paths\n"
position = text.rfind(marker)
if position < 0:
    raise SystemExit("expected all-other-paths marker is missing")

tail = text[position:]
if not tail.rstrip().endswith("}"):
    raise SystemExit("unexpected nginx config tail")

replacement = f"""    # Let nginx ask oauth2-proxy whether the browser has a valid GWS session.
    location = /oauth2/auth {{
        proxy_pass http://127.0.0.1:4185/oauth2/auth;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Original-URI $request_uri;
        proxy_set_header Cookie $http_cookie;
        proxy_set_header Content-Length "";
        proxy_pass_request_body off;
    }}

    # Human Management pages go to Google when the browser is not signed in.
    location / {{
        auth_request /oauth2/auth;
        error_page 401 = @management_oauth2_start;
        auth_request_set $management_email $upstream_http_x_auth_request_email;
        proxy_set_header X-Forwarded-Email $management_email;
        {secret_line}
        proxy_pass http://{upstream};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }}

    location @management_oauth2_start {{
        return 302 /oauth2/start?rd=$scheme://$http_host$request_uri;
    }}
}}
"""
path.write_text(text[:position] + replacement)
PY
published=1
ssh "$SSH_HOST" "sudo nginx -t"
ssh "$SSH_HOST" "sudo systemctl reload nginx"

published=0
trap - EXIT INT TERM HUP
printf '[OK] Management nginx auth flow deployed\n'
printf 'backup: %s\n' "$remote_backup"
