#!/usr/bin/env python3
"""Wrapper for schedulers (cron / systemd timer / launchd) that launches the monthly real Google Workspace collection.

All per-deployment values are taken from environment variables (not embedded in code):

  ISMS_GW_TENANT_ID     UUID of the tenant to write collection results to (required)
  ISMS_GW_USER_ID       UUID of the user the session is issued for (required)
  ISMS_GW_SUBJECT       email of the admin impersonated via domain-wide delegation (required, e.g. admin@example.com)
  ISMS_GW_KEY_PATH      path to the service account key JSON (required; keep it outside the repository)
  ISMS_DB               target DB name or DSN (default isms_dev)
  ISMS_GW_PSQL          path to psql (default: psql on PATH)
  ISMS_GW_PYTHON        path to python (default: the python running this script)
  ISMS_GW_LOG_PATH      log output path (default ~/.local/state/isms-platform/google-workspace-monthly.log)
  ISMS_GW_REPORT_DAYS   number of days the audit report looks back (default 30)
"""

from __future__ import annotations

import os
import secrets
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
COLLECTOR = ROOT / "scripts" / "google_workspace_live_sync.py"

DB = os.environ.get("ISMS_DB", "isms_dev")
TENANT_ID = os.environ.get("ISMS_GW_TENANT_ID", "")
USER_ID = os.environ.get("ISMS_GW_USER_ID", "")
SUBJECT = os.environ.get("ISMS_GW_SUBJECT", "")
KEY_PATH = os.environ.get("ISMS_GW_KEY_PATH", "")
PSQL = os.environ.get("ISMS_GW_PSQL", "psql")
PYTHON = os.environ.get("ISMS_GW_PYTHON", sys.executable)
REPORT_DAYS = os.environ.get("ISMS_GW_REPORT_DAYS", "30")
LOG_PATH = Path(os.environ.get(
    "ISMS_GW_LOG_PATH",
    str(Path.home() / ".local" / "state" / "isms-platform" / "google-workspace-monthly.log"),
))


def write_log(message: str) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(message.rstrip() + "\n")


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def missing_settings() -> list[str]:
    required = {
        "ISMS_GW_TENANT_ID": TENANT_ID,
        "ISMS_GW_USER_ID": USER_ID,
        "ISMS_GW_SUBJECT": SUBJECT,
        "ISMS_GW_KEY_PATH": KEY_PATH,
    }
    return [name for name, value in required.items() if not value.strip()]


def issue_session_token() -> str:
    token = secrets.token_urlsafe(48)
    sql = (
        "SELECT app.create_session("
        + sql_literal(TENANT_ID)
        + "::uuid,"
        + sql_literal(USER_ID)
        + "::uuid,"
        + sql_literal(token)
        + ");"
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
    missing = missing_settings()
    if missing:
        write_log(f"started={started} wrapper_error=missing settings: {', '.join(missing)}")
        print(f"missing required settings: {', '.join(missing)}", file=sys.stderr)
        return 2
    try:
        token = issue_session_token()
        env = dict(os.environ, PYTHONUNBUFFERED="1")
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
                REPORT_DAYS,
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
