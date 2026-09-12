#!/usr/bin/env python3
"""Rotate the dedicated web tenant session and restart the local web service.

The public SSO gateway protects the HTTP entrypoint, while the Next.js process
uses a server-only tenant session token for RLS.  That token is intentionally
short-lived, so this wrapper rotates it before expiry and verifies the local
settings page before revoking the previous token.
"""

from __future__ import annotations

import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen


# Per-machine differences come in via env. Do not embed host names or paths in code.
# Operational scripts that span machines take their execution environment via arguments or env.
ROOT = Path(__file__).resolve().parent.parent
DB = os.environ.get("ISMS_SESSION_DSN") or os.environ.get("ISMS_DB", "isms_dev")
PSQL = os.environ.get("ROTATE_PSQL", "psql")
ENV_PATH = Path(os.environ.get(
    "ISMS_SESSION_ENV_PATH",
    str(ROOT / "web" / ".env.local"),
))
# How to restart: none (no restart), systemctl (systemctl --user), launchctl (macOS).
RESTART_MODE = os.environ.get("ISMS_SESSION_RESTART", "none")
WEB_LABEL = os.environ.get("ISMS_SESSION_SERVICE", "isms-platform-web")
LOCAL_URL = os.environ.get("ISMS_SESSION_HEALTH_URL", "http://127.0.0.1:3110/settings")
SESSION_TTL = os.environ.get("ISMS_SESSION_TTL", "24 hours")
# The env key to rewrite. Configurable so the mail-send worker token can be rotated by the same
# mechanism (rather than adding another script).
ENV_KEY = os.environ.get("ISMS_SESSION_ENV_KEY", "ISMS_WEB_TENANT_TOKEN")
# Tenant and user are carried over from the session row of the token currently in use.
# Hardcoding them would mean each machine holds its own values, and one would go stale.
# Connection (app_rw) used to carry over tenant/user. Separate from auth_svc, which issues sessions.
LOOKUP_DSN = os.environ.get("ISMS_SESSION_LOOKUP_DSN", DB)
LOOKUP_ROLE = os.environ.get("ISMS_SESSION_LOOKUP_ROLE", "app_rw")
TENANT_ID = os.environ.get("ISMS_SESSION_TENANT_ID", "")
USER_ID = os.environ.get("ISMS_SESSION_USER_ID", "")


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def run_psql_as(dsn: str, role: str, sql: str) -> str:
    """Run psql against an arbitrary connection target and role."""
    env = dict(os.environ, PGUSER=role)
    result = subprocess.run(
        [PSQL, "-v", "ON_ERROR_STOP=1", "-Atq", "-d", dsn, "-f", "-"],
        input=sql,
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "psql returned a non-zero status"
        raise RuntimeError(detail)
    return result.stdout.strip()


def run_psql(sql: str) -> str:
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
        detail = result.stderr.strip() or "psql returned a non-zero status"
        raise RuntimeError(detail)
    return result.stdout.strip()


def resolve_identity(current_token: str) -> tuple[str, str]:
    """Carry over tenant and user from the session row of the token currently in use.

    The row remains even after expiry, so it can still be looked up. Explicit env values take precedence.
    If neither is available, stop rather than guessing and creating a new session.
    """
    if TENANT_ID and USER_ID:
        return TENANT_ID, USER_ID
    # **Do not read app.sessions directly.** 0005 made app.sessions definer-only,
    # and none of app_rw / app_ro / auth_svc have table privileges on it
    # (reading it directly gives permission denied for table sessions).
    # Instead, set up a context with the token we hold and read
    # tenant and user from that context. Both are exposed via SECURITY DEFINER functions.
    # If the token has already expired this fails with invalid session, in which case
    # they must be given explicitly via env (message below).
    row = run_psql_as(
        LOOKUP_DSN,
        LOOKUP_ROLE,
        "BEGIN;"
        " SELECT app.set_tenant_context(" + sql_literal(current_token) + ");"
        " SELECT app.current_tenant()::text || ' ' || app.current_session_user()::text;"
        "COMMIT;",
    ).splitlines()[-1].strip()
    parts = row.split()
    if len(parts) != 2:
        raise RuntimeError(
            "現行トークンからテナント・利用者を特定できません。"
            "ISMS_SESSION_TENANT_ID と ISMS_SESSION_USER_ID を指定してください"
        )
    return parts[0], parts[1]


def issue_token(tenant_id: str, user_id: str) -> str:
    token = secrets.token_urlsafe(48)
    run_psql(
        "SELECT app.create_session("
        + sql_literal(tenant_id)
        + "::uuid,"
        + sql_literal(user_id)
        + "::uuid,"
        + sql_literal(token)
        + ","
        + sql_literal(SESSION_TTL)
        + "::interval);"
    )
    return token


def revoke_token(token: str) -> None:
    run_psql("SELECT app.revoke_session(" + sql_literal(token) + ");")


def read_env() -> tuple[str, str]:
    content = ENV_PATH.read_text(encoding="utf-8")
    matches = re.findall(r"^" + re.escape(ENV_KEY) + r"=(\S+)$", content, flags=re.MULTILINE)
    if len(matches) != 1:
        raise RuntimeError(f"{ENV_PATH} の {ENV_KEY} が一意に見つかりません")
    return content, matches[0]


def write_env(content: str, token: str) -> None:
    replacement = ENV_KEY + "=" + token
    updated, count = re.subn(
        r"^" + re.escape(ENV_KEY) + r"=\S+$",
        replacement,
        content,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise RuntimeError(f"{ENV_PATH} の {ENV_KEY} 行を更新できません")

    mode = stat.S_IMODE(ENV_PATH.stat().st_mode)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=ENV_PATH.parent,
            prefix=ENV_PATH.name + ".",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary = handle.name
            handle.write(updated)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, ENV_PATH)
    finally:
        if temporary and Path(temporary).exists():
            Path(temporary).unlink()


def restart_web() -> None:
    if RESTART_MODE == "none":
        return
    if RESTART_MODE == "systemctl":
        command = ["systemctl", "--user", "restart", WEB_LABEL]
    else:
        command = ["/bin/launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{WEB_LABEL}"]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.strip() or f"{command[0]} returned a non-zero status"
        raise RuntimeError(detail)


def wait_until_healthy(timeout: float = 60.0) -> None:
    deadline = time.monotonic() + timeout
    last_error = "service did not become ready"
    while time.monotonic() < deadline:
        try:
            request = Request(LOCAL_URL, headers={"Cache-Control": "no-cache"})
            with urlopen(request, timeout=3) as response:
                body = response.read().decode("utf-8", errors="replace")
                # Treat any message containing the "tenant session" marker as a failure.
                # What actually appeared on 2026-09-08 was
                # "a tenant session or trusted user identification is required" (in Japanese);
                # none of the previous three markers matched it, so the health check
                # let it through (= it passed even when the session had expired).
                failure_markers = (
                    "テナントセッション",
                    "テナント文脈が無い",
                    "テナント設定の読み取りに失敗した",
                )
                if (
                    response.status == 200
                    and "ISMS側の設定を登録" in body
                    and not any(marker in body for marker in failure_markers)
                ):
                    return
                last_error = f"settings returned HTTP {response.status} or a tenant failure banner"
        except (OSError, URLError) as exc:
            last_error = str(exc)
        time.sleep(2)
    raise RuntimeError(last_error)


def main() -> int:
    # Do not change the order. **Issue new -> rewrite env -> restart -> health passes -> revoke old.**
    # If anything fails midway, the old token stays alive and the screens keep working.
    # Revoking earlier would leave nothing to fall back to on failure.
    old_content, old_token = read_env()
    tenant_id, user_id = resolve_identity(old_token)
    new_token = issue_token(tenant_id, user_id)
    write_env(old_content, new_token)
    try:
        restart_web()
        if RESTART_MODE != "none":
            wait_until_healthy()
    except Exception as exc:  # noqa: BLE001 - do not take the screens down on failure
        # **Restore the old token.** Crashing with the new token written would leave
        # the screens stuck at "tenant session required".
        # The old token has not been revoked yet, so restoring it brings things back.
        print(f"ローテーションに失敗したため旧トークンへ戻します: {exc}", file=sys.stderr)
        write_env(read_env()[0], old_token)
        try:
            restart_web()
        except Exception as restore_exc:  # noqa: BLE001
            print(f"旧トークンでの再起動にも失敗: {restore_exc}", file=sys.stderr)
            return 70
        # Do not leave the unused new token behind.
        try:
            revoke_token(new_token)
        except Exception:  # noqa: BLE001
            pass
        return 1
    if RESTART_MODE == "none":
        print(f"{ENV_KEY} rotated (no service to restart)")
    else:
        print(f"{ENV_KEY} rotated and health check passed")
    revoke_token(old_token)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
