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


# 機ごとの違いは env で受ける。既定値は Mac（従来の挙動）のまま。
#
# 以前は Mac のパスとラベルがハードコードされていて、RUNTIME では動かなかった。
# その結果 RUNTIME ではローテーションが一度も回らず、2026-09-08 09:23 JST に
# セッションが切れて全画面が停止した。機をまたぐ運用スクリプトは
# 実行環境を引数か env で受ける。
DB = os.environ.get("ISMS_SESSION_DSN") or os.environ.get("ISMS_DB", "isms_dev")
PSQL = os.environ.get("ROTATE_PSQL", "/opt/homebrew/opt/postgresql@17/bin/psql")
ENV_PATH = Path(os.environ.get(
    "ISMS_SESSION_ENV_PATH",
    "/opt/isms-platform/web/.env.local",
))
# 再起動の方法。launchctl（Mac）か systemctl --user（RUNTIME）。
RESTART_MODE = os.environ.get("ISMS_SESSION_RESTART", "launchctl")
WEB_LABEL = os.environ.get("ISMS_SESSION_SERVICE", "com.example-org.isms-platform.web")
LOCAL_URL = os.environ.get("ISMS_SESSION_HEALTH_URL", "http://127.0.0.1:3110/settings")
SESSION_TTL = os.environ.get("ISMS_SESSION_TTL", "24 hours")
# 書き換える env のキー。メール送信ワーカー用トークンも同じ仕組みで回せるように
# しておく（別スクリプトを増やさない）。
ENV_KEY = os.environ.get("ISMS_SESSION_ENV_KEY", "ISMS_WEB_TENANT_TOKEN")
# テナントと利用者は、いま使っているトークンのセッション行から引き継ぐ。
# ハードコードすると機ごとに別の値を持つことになり、片方が古くなる。
# テナント・利用者の引き継ぎに使う接続（app_rw）。セッション発行の auth_svc とは別。
LOOKUP_DSN = os.environ.get("ISMS_SESSION_LOOKUP_DSN", DB)
LOOKUP_ROLE = os.environ.get("ISMS_SESSION_LOOKUP_ROLE", "app_rw")
TENANT_ID = os.environ.get("ISMS_SESSION_TENANT_ID", "")
USER_ID = os.environ.get("ISMS_SESSION_USER_ID", "")


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def run_psql_as(dsn: str, role: str, sql: str) -> str:
    """任意の接続先・ロールで psql を回す。"""
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
    """いま使っているトークンのセッション行から、テナントと利用者を引き継ぐ。

    期限切れでも行は残っているので引ける。env で明示されていればそちらを優先する。
    どちらも取れないときは、当てずっぽうで新しいセッションを作らずに止める。
    """
    if TENANT_ID and USER_ID:
        return TENANT_ID, USER_ID
    # **app.sessions を直接読まない。** 0005 で app.sessions は定義者専用と決めて
    # あり、app_rw / app_ro / auth_svc のいずれにも表の権限が無い
    # （RUNTIME で permission denied for table sessions を実測）。
    # 代わりに、いま持っているトークンで文脈を張って、その文脈から
    # テナントと利用者を読む。両方とも SECURITY DEFINER 関数で公開されている。
    # トークンが既に切れているとここで invalid session になるので、その場合は
    # env で明示してもらう（下のメッセージ）。
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
                # 「テナントセッション」を含む文言はすべて失敗とみなす。
                # 2026-09-08 に実際に出たのは
                # 「テナントセッションまたは信頼済みの利用者識別が必要です」で、
                # 従来の3つのマーカーはどれも一致せず、ヘルスチェックを
                # 素通りしていた（＝切れていても合格と判定していた）。
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
    # 順序を崩さない。**新規発行 → env 書き換え → 再起動 → ヘルス合格 → 旧を revoke。**
    # 途中で失敗しても旧トークンが生きたまま残り、画面は止まらない。
    # revoke を前に出すと、失敗したときに戻れる先が無くなる。
    old_content, old_token = read_env()
    tenant_id, user_id = resolve_identity(old_token)
    new_token = issue_token(tenant_id, user_id)
    write_env(old_content, new_token)
    try:
        restart_web()
        if RESTART_MODE != "none":
            wait_until_healthy()
    except Exception as exc:  # noqa: BLE001 - 失敗しても画面を止めない
        # **旧トークンへ戻す。** 新しいトークンを書いたまま落ちると、
        # 画面は「テナントセッションが必要です」のまま復旧しない。
        # 旧トークンはまだ revoke していないので、戻せば生き返る。
        print(f"ローテーションに失敗したため旧トークンへ戻します: {exc}", file=sys.stderr)
        write_env(read_env()[0], old_token)
        try:
            restart_web()
        except Exception as restore_exc:  # noqa: BLE001
            print(f"旧トークンでの再起動にも失敗: {restore_exc}", file=sys.stderr)
            return 70
        # 使わなかった新トークンは残さない。
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
