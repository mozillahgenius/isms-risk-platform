#!/usr/bin/env python3
"""月次のGoogle Workspace実収集を起動するLaunchAgent用ラッパー。"""

from __future__ import annotations

import os
import secrets
import subprocess
from datetime import datetime, timezone
from pathlib import Path


DB = os.environ.get("ISMS_DB", "isms_dev")
TENANT_ID = os.environ.get("ISMS_TENANT_ID", "")
USER_ID = os.environ.get("ISMS_ADMIN_USER_ID", "")
SUBJECT = os.environ.get("ISMS_GWS_SUBJECT", "admin@example.invalid")
KEY_PATH = os.environ.get("GOOGLE_WORKSPACE_SERVICE_ACCOUNT_KEY", "/etc/isms-platform/google-workspace-service-account.json")
PSQL = os.environ.get("ISMS_PSQL_BIN", "psql")
PYTHON = os.environ.get("ISMS_PYTHON_BIN", "python3")
ROOT = Path(__file__).resolve().parent.parent
COLLECTOR = ROOT / "scripts" / "google_workspace_live_sync.py"
LOG_PATH = Path(os.environ.get("ISMS_MONTHLY_LOG_PATH", "/var/log/isms-platform/google-workspace-monthly.log"))


def write_log(message: str) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(message.rstrip() + "\n")


def issue_session_token() -> str:
    if not TENANT_ID or not USER_ID:
        raise RuntimeError("ISMS_TENANT_ID と ISMS_ADMIN_USER_ID を設定してください")
    token = secrets.token_urlsafe(48)
    sql = (
        "SELECT app.create_session('"
        + TENANT_ID
        + "'::uuid,'"
        + USER_ID
        + "'::uuid,'"
        + token
        + "');"
    )
    env = dict(os.environ, PGUSER="auth_svc")
    result = subprocess.run(
        [PSQL, "-v", "ON_ERROR_STOP=1", "-Atq", "-d", DB, "-f", "-"],
        input=sql,
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("DBセッションの発行に失敗しました")
    return token


def main() -> int:
    started = datetime.now(timezone.utc).isoformat()
    try:
        token = issue_session_token()
        env = dict(
            os.environ,
            PATH="/opt/homebrew/bin:/opt/homebrew/opt/postgresql@17/bin:/usr/bin:/bin",
            PYTHONUNBUFFERED="1",
        )
        result = subprocess.run(
            [
                PYTHON,
                str(COLLECTOR),
                "--key",
                KEY_PATH,
                "--subject",
                SUBJECT,
                "--token-stdin",
                "--db",
                DB,
                "--report-days",
                "30",
                "--public-only",
            ],
            input=token,
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        write_log(f"started={started} collector_rc={result.returncode}")
        if result.stdout:
            write_log(result.stdout)
        if result.stderr:
            write_log(result.stderr)
        return result.returncode
    except (OSError, RuntimeError) as exc:
        write_log(f"started={started} wrapper_error={exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
