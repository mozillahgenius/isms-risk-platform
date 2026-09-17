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

render_insert() {
  cat <<NGINX
    # Agent distribution/install page and token APIs are public only because the
    # one-time token is the capability. Human approval UI remains OAuth-protected.
    location ^~ /agent/install/ {
        proxy_pass http://$UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location ^~ /api/agent/v1/distribution/ {
        proxy_pass http://$UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

NGINX
}

if [[ "${1:-}" == "--self-test" && $# == 1 ]]; then
  insert="$(render_insert)"
  grep -Fq 'location ^~ /agent/install/ {' <<<"$insert"
  grep -Fq 'location ^~ /api/agent/v1/distribution/ {' <<<"$insert"
  printf 'management public distribution route self-test passed\n'
  exit 0
fi

if [[ $# != 0 ]]; then
  printf 'usage: %s [--self-test]\n' "$0" >&2
  exit 2
fi

stamp="$(date +%Y%m%d-%H%M%S)"
remote_backup="$REMOTE_BACKUP_DIR/management.example.invalid.bak-agent-distribution-$stamp"
published=0
trap rollback EXIT INT TERM HUP

ssh "$SSH_HOST" "sudo install -d -m 700 '$REMOTE_BACKUP_DIR'"
ssh "$SSH_HOST" "sudo cp -p '$REMOTE_CONF' '$remote_backup'"

ssh "$SSH_HOST" "sudo python3 - '$REMOTE_CONF' '$UPSTREAM'" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
upstream = sys.argv[2]
text = path.read_text()
needle = "    # All other paths\n"
markers = (
    "location ^~ /agent/install/ {",
    "location ^~ /api/agent/v1/distribution/ {",
)
if any(marker in text for marker in markers):
    raise SystemExit("management agent distribution locations already exist")
if text.count(needle) != 1:
    raise SystemExit("expected exactly one all-other-paths marker")
block = f"""    # Agent distribution/install page and token APIs are public only because the
    # one-time token is the capability. Human approval UI remains OAuth-protected.
    location ^~ /agent/install/ {{
        proxy_pass http://{upstream};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }}

    location ^~ /api/agent/v1/distribution/ {{
        proxy_pass http://{upstream};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }}

"""
path.write_text(text.replace(needle, block + needle, 1))
PY
published=1
ssh "$SSH_HOST" "sudo nginx -t"
ssh "$SSH_HOST" "sudo systemctl reload nginx"

published=0
trap - EXIT INT TERM HUP
printf '[OK] Management public agent distribution routes deployed\n'
printf 'backup: %s\n' "$remote_backup"
