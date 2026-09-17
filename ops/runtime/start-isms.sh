#!/usr/bin/env bash
set -euo pipefail

set -a
source /opt/isms-platform/target-env/isms.env
source /opt/isms-platform/target-env/isms-db-roles.env
set +a

# Management owns the agent enrollment endpoints.  The reverse proxy still
# protects the approval UI with GWS/OAuth; the public start/redeem endpoints
# are additionally bounded by the signed device flow and DB rate limits.
export ISMS_AGENT_LOGIN_ENROLLMENT_ENABLED="${ISMS_AGENT_LOGIN_ENROLLMENT_ENABLED:-true}"
export ISMS_AGENT_ENROLLMENT_ORIGIN="${ISMS_AGENT_ENROLLMENT_ORIGIN:-https://management.example.invalid}"
export ISMS_AGENT_ARTIFACT_DIR="${ISMS_AGENT_ARTIFACT_DIR:-/opt/isms-platform/releases/isms/current/agent-artifacts}"

case "${ISMS_WEB_DATABASE_URL:-}" in *app_ro*) ;; *) echo "read DB role is not app_ro" >&2; exit 1;; esac
case "${ISMS_WRITE_DATABASE_URL:-}" in *app_rw*) ;; *) echo "write DB role is not app_rw" >&2; exit 1;; esac
case "${ISMS_AGENT_DATABASE_URL:-}" in *app_rw*) ;; *) echo "agent DB role is not app_rw" >&2; exit 1;; esac
case "${ISMS_PROXY_DATABASE_URL:-}" in *management_web*) ;; *) echo "proxy DB role is not management_web" >&2; exit 1;; esac
proxy_identity_secret="${ISMS_DEVICE_CONTROL_PROXY_SECRET:-}"
if [ "${#proxy_identity_secret}" -lt 16 ]; then
  echo "trusted proxy identity secret is missing" >&2
  exit 1
fi
unset proxy_identity_secret

export PORT=13110
cd /opt/isms-platform/releases/isms/current/web
exec node_modules/.bin/next start -H 127.0.0.1 -p "${PORT}"
