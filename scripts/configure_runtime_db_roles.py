#!/usr/bin/env python3
"""RUNTIMEのowner-only pgpassからManagement用role別DSNを生成する。"""

from __future__ import annotations

import argparse
import hashlib
import os
import signal
import stat
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import quote


def unescape_pgpass(value: str) -> str:
    result: list[str] = []
    escaped = False
    for char in value:
        if escaped:
            result.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        else:
            result.append(char)
    if escaped:
        result.append("\\")
    return "".join(result)


def split_pgpass(line: str) -> list[str]:
    fields: list[str] = []
    current: list[str] = []
    escaped = False
    for char in line.rstrip("\n"):
        if escaped:
            current.extend(("\\", char))
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == ":":
            fields.append(unescape_pgpass("".join(current)))
            current = []
        else:
            current.append(char)
    if escaped:
        current.append("\\")
    fields.append(unescape_pgpass("".join(current)))
    return fields


def passwords(
    path: Path, host: str, port: str, database: str, required_users: set[str]
) -> dict[str, str]:
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or path.is_symlink():
        raise ValueError("pgpass must be a regular non-symlink file")
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError("pgpass must be owned by the current user with mode 0600")
    found: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = split_pgpass(line)
        if len(fields) != 5:
            continue
        item_host, item_port, item_db, user, password = fields
        if (item_host, item_port, item_db) == (host, port, database) and user in required_users:
            found[user] = password
    if set(found) != required_users:
        expected = "/".join(sorted(required_users))
        raise ValueError(f"exact {expected} pgpass entries were not found")
    return found


def prepare_target_parent(target: Path) -> None:
    if target.parent.is_symlink():
        raise ValueError("target environment parent must not be a symlink")
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(target.parent, 0o700)
    parent_info = target.parent.stat()
    if not stat.S_ISDIR(parent_info.st_mode) or parent_info.st_uid != os.getuid() or stat.S_IMODE(parent_info.st_mode) != 0o700:
        raise ValueError("target environment parent must be current-user owned with mode 0700")


def write_secret_file(target: Path, body: str) -> None:
    prepare_target_parent(target)
    temp: Path | None = None
    interrupted = False
    watched_signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    previous_handlers: dict[signal.Signals, object] = {}

    def interrupt(signum: int, _frame: object) -> None:
        nonlocal interrupted
        if interrupted:
            return
        interrupted = True
        raise SystemExit(128 + signum)

    for watched in watched_signals:
        previous_handlers[watched] = signal.signal(watched, interrupt)
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=target.parent, delete=False) as handle:
            temp = Path(handle.name)
            handle.write(body)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, 0o600)
        os.replace(temp, target)
        temp = None
        os.chmod(target, 0o600)
    finally:
        if temp is not None:
            try:
                temp.unlink()
            except FileNotFoundError:
                pass
        for watched, previous in previous_handlers.items():
            signal.signal(watched, previous)


def escape_pgpass(value: str) -> str:
    return value.replace("\\", "\\\\").replace(":", "\\:")


def write_environment(
    target: Path, host: str, port: str, database: str, found: dict[str, str], proxy_secret: str
) -> None:
    read_dsn = f"postgresql://app_ro:{quote(found['app_ro'], safe='')}@{host}:{port}/{database}"
    write_dsn = f"postgresql://app_rw:{quote(found['app_rw'], safe='')}@{host}:{port}/{database}"
    proxy_password = hashlib.sha256(f"management-web:{proxy_secret}".encode()).hexdigest()
    proxy_dsn = f"postgresql://management_web:{proxy_password}@{host}:{port}/{database}"
    values = {
        "ISMS_WEB_DATABASE_URL": read_dsn,
        "ISMS_WRITE_DATABASE_URL": write_dsn,
        "ISMS_AGENT_DATABASE_URL": write_dsn,
        "ISMS_PROXY_DATABASE_URL": proxy_dsn,
    }
    body = "".join(f"{key}={value}\n" for key, value in values.items())
    write_secret_file(target, body)


def environment_secret(path: Path, key: str) -> str:
    if path.is_symlink() or not path.is_file():
        raise ValueError("proxy environment must be a regular non-symlink file")
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{key}="):
            value = line.split("=", 1)[1].strip()
            if len(value) >= 16:
                return value
    raise ValueError("trusted proxy secret is missing")


def provision_mail_worker_role(
    host: str, port: str, database: str, admin_user: str, admin_password: str,
    proxy_secret: str, mail_env: Path,
) -> None:
    """mail_worker のパスワードを配り直し、送信ワーカーの DSN を書き換える。

    management_web と同じで、パスワードは**保存せずに毎回導出する**
    （sha256("mail-worker:" + 既存の秘密)）。ラベルが違うので
    management_web とは別の値になり、秘密は1つのままで済む。
    こうしておくと、デプロイのたびに同じ値へ収束し、手で付けた
    パスワードが env と食い違って「昨日は送れたのに今日は送れない」に
    ならない（2026-09-08 は手で付けていた）。

    mail 用 env は SMTP 資格情報と送信ワーカー用トークンも持っているので、
    ファイルごと書き換えず **DSN の行だけ**差し替える。
    """
    password = hashlib.sha256(f"mail-worker:{proxy_secret}".encode()).hexdigest()
    sql = "ALTER ROLE mail_worker PASSWORD '" + password + "';\n"
    env = os.environ.copy()
    env["PGPASSWORD"] = admin_password
    subprocess.run(
        ["psql", "-v", "ON_ERROR_STOP=1", "-q", "-h", host, "-p", port,
         "-U", admin_user, "-d", database],
        input=sql,
        text=True,
        check=True,
        env=env,
    )
    dsn = f"postgresql://mail_worker:{quote(password, safe='')}@{host}:{port}/{database}"
    replace_env_value(mail_env, "ISMS_MAIL_DATABASE_URL", dsn)


def replace_env_value(target: Path, key: str, value: str) -> None:
    """env の1行だけを差し替える。他の行（SMTP 資格情報等）は触らない。"""
    if target.is_symlink() or not target.is_file():
        raise ValueError(f"{target} must be a regular non-symlink file")
    mode = stat.S_IMODE(target.stat().st_mode)
    lines = target.read_text(encoding="utf-8").splitlines()
    replaced = 0
    out = []
    for line in lines:
        if line.startswith(f"{key}="):
            out.append(f"{key}={value}")
            replaced += 1
        else:
            out.append(line)
    if replaced != 1:
        raise ValueError(f"{target} の {key} 行が {replaced} 件（1 件のはず）")
    temporary = target.with_name(target.name + ".tmp")
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, mode)
    os.replace(temporary, target)


def provision_proxy_role(
    host: str, port: str, database: str, admin_user: str, admin_password: str, proxy_secret: str
) -> None:
    password = hashlib.sha256(f"management-web:{proxy_secret}".encode()).hexdigest()
    sql = "ALTER ROLE management_web PASSWORD '" + password + "';\n"
    env = os.environ.copy()
    env["PGPASSWORD"] = admin_password
    subprocess.run(
        ["psql", "-v", "ON_ERROR_STOP=1", "-q", "-h", host, "-p", port,
         "-U", admin_user, "-d", database],
        input=sql,
        text=True,
        check=True,
        env=env,
    )


def write_pgpass(
    target: Path,
    host: str,
    port: str,
    source_database: str,
    database: str,
    found: dict[str, str],
    admin_user: str | None,
    admin_password: str | None,
) -> None:
    # run_isolated.sh が ISMS_TEST_DB="${DB}_<suffix>" で走らせる下位の試験の DB。ここに無い DB へは
    # 資格情報が無く、無人の配備で psql がパスワードの入力を待って止まる（2026-09-13、isms_records /
    # isms_registers の追加時に30分止まった）。run_isolated.sh に下位の試験を足したら、ここにも足す。
    fixture_databases = (
        database,
        f"{database}_management_workflows",
        f"{database}_0046_reverse",
        f"{database}_isms_records",
        f"{database}_isms_registers",
    )
    entries = [
        (host, port, fixture_database, role, found[role])
        for fixture_database in fixture_databases
        for role in ("app_ro", "app_rw", "auth_svc")
    ]
    if admin_user is not None and admin_password is not None:
        for admin_database in ("postgres", source_database, database):
            entry = (host, port, admin_database, admin_user, admin_password)
            if entry not in entries:
                entries.append(entry)
        for fixture_database in fixture_databases[1:]:
            entries.append((host, port, fixture_database, admin_user, admin_password))
    body = "".join(":".join(escape_pgpass(field) for field in entry) + "\n" for entry in entries)
    write_secret_file(target, body)


def self_test_replace_env_value() -> None:
    """1行だけ差し替わること・他の行と権限が変わらないこと・
    対象が無ければ落ちることを確かめる（通ることだけを見ない）。"""
    with tempfile.TemporaryDirectory() as directory:
        target = Path(directory) / "isms-mail.env"
        target.write_text(
            "# comment\n"
            "ISMS_MAIL_DATABASE_URL=postgresql://mail_worker:old@127.0.0.1:15432/isms_dev\n"
            'ISMS_SMTP_PASSWORD="keep me"\n',
            encoding="utf-8",
        )
        os.chmod(target, 0o600)
        replace_env_value(target, "ISMS_MAIL_DATABASE_URL", "postgresql://mail_worker:new@h:1/d")
        body = target.read_text(encoding="utf-8")
        assert "postgresql://mail_worker:new@h:1/d" in body
        assert "old" not in body
        assert 'ISMS_SMTP_PASSWORD="keep me"' in body, "他の行を壊している"
        assert "# comment" in body
        assert stat.S_IMODE(target.stat().st_mode) == 0o600, "権限が変わっている"
        try:
            replace_env_value(target, "ISMS_MISSING_KEY", "x")
        except ValueError:
            pass
        else:  # pragma: no cover - 落ちなければ検査が空振りしている
            raise AssertionError("存在しないキーでも落ちなかった")


def self_test() -> None:
    self_test_replace_env_value()
    assert split_pgpass(r"host:15432:db:user:p\:a\\ss") == ["host", "15432", "db", "user", "p:a\\ss"]
    assert escape_pgpass(r"p:a\ss") == r"p\:a\\ss"
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        pgpass = root / "pgpass"
        pgpass.write_text(
            "127.0.0.1:15432:isms_dev:app_ro:ro\\:pass\n"
            "127.0.0.1:15432:isms_dev:app_rw:rw\\:pass\n"
            "127.0.0.1:15432:isms_dev:auth_svc:auth\\:pass\n"
        )
        pgpass.chmod(0o600)
        found = passwords(
            pgpass,
            "127.0.0.1",
            "15432",
            "isms_dev",
            {"app_ro", "app_rw", "auth_svc"},
        )
        environment = root / "private" / "roles.env"
        write_environment(environment, "127.0.0.1", "15432", "isms_test", found, "p" * 32)
        assert "ISMS_WEB_DATABASE_URL=" in environment.read_text(encoding="utf-8")
        assert "ISMS_PROXY_DATABASE_URL=postgresql://management_web:" in environment.read_text(encoding="utf-8")
        target = root / "private" / "isolated.pgpass"
        write_pgpass(
            target,
            "127.0.0.1",
            "15432",
            "isms_dev",
            "isms_test",
            found,
            "postgres",
            r"admin:\pass",
        )
        rows = [split_pgpass(line) for line in target.read_text(encoding="utf-8").splitlines()]
        assert ["127.0.0.1", "15432", "isms_test", "app_ro", "ro:pass"] in rows
        assert ["127.0.0.1", "15432", "isms_test", "app_rw", "rw:pass"] in rows
        assert ["127.0.0.1", "15432", "isms_test", "auth_svc", "auth:pass"] in rows
        assert ["127.0.0.1", "15432", "isms_test_management_workflows", "auth_svc", "auth:pass"] in rows
        assert ["127.0.0.1", "15432", "postgres", "postgres", r"admin:\pass"] in rows
        assert ["127.0.0.1", "15432", "isms_dev", "postgres", r"admin:\pass"] in rows
        assert ["127.0.0.1", "15432", "isms_test_0046_reverse", "postgres", r"admin:\pass"] in rows
        # run_isolated.sh の下位の試験（isms_records / isms_registers）の DB にも資格情報がある（2026-09-13 に配備で止まった件）。
        for suffix in ("isms_records", "isms_registers"):
            assert ["127.0.0.1", "15432", f"isms_test_{suffix}", "app_rw", "rw:pass"] in rows, suffix
            assert ["127.0.0.1", "15432", f"isms_test_{suffix}", "postgres", r"admin:\pass"] in rows, suffix
        assert stat.S_IMODE(target.stat().st_mode) == 0o600
        two_role_pgpass = root / "pgpass-two-role"
        two_role_pgpass.write_text(
            "127.0.0.1:15432:isms_dev:app_ro:ro-pass\n"
            "127.0.0.1:15432:isms_dev:app_rw:rw-pass\n"
        )
        two_role_pgpass.chmod(0o600)
        two_role_found = passwords(
            two_role_pgpass,
            "127.0.0.1",
            "15432",
            "isms_dev",
            {"app_ro", "app_rw"},
        )
        two_role_environment = root / "private" / "two-role.env"
        write_environment(
            two_role_environment,
            "127.0.0.1",
            "15432",
            "isms_test",
            two_role_found,
            "p" * 32,
        )
        assert "ISMS_WRITE_DATABASE_URL=" in two_role_environment.read_text(encoding="utf-8")
    print("[configure-runtime-db-roles] self-test PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pgpass", type=Path, default=Path.home() / ".pgpass")
    parser.add_argument("--target", type=Path, default=Path.home() / "target-env" / "isms-db-roles.env")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default="15432")
    parser.add_argument("--database", default="isms_dev")
    parser.add_argument("--source-database", help="exact pgpass credential source database (defaults to --database)")
    parser.add_argument("--pgpass-target", type=Path, help="write an owner-only pgpass file instead of role DSNs")
    parser.add_argument("--admin-user", help="optional exact admin pgpass entry user")
    parser.add_argument("--admin-password-env", help="environment variable containing the admin pgpass password")
    parser.add_argument("--proxy-env-file", type=Path, default=Path("/opt/isms-platform/target-env/isms.env"))
    parser.add_argument(
        "--mail-env-file", type=Path,
        help="送信ワーカーの env（ISMS_MAIL_DATABASE_URL を持つ）。"
             "指定すると mail_worker のパスワードも配り直して DSN を更新する",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    source_database = args.source_database or args.database
    required_users = {"app_ro", "app_rw", "auth_svc"} if args.pgpass_target else {"app_ro", "app_rw"}
    found = passwords(args.pgpass, args.host, args.port, source_database, required_users)
    if args.pgpass_target:
        if bool(args.admin_user) != bool(args.admin_password_env):
            parser.error("--admin-user and --admin-password-env must be provided together")
        admin_password = None
        if args.admin_password_env:
            admin_password = os.environ.get(args.admin_password_env)
            if not admin_password:
                parser.error("admin password environment variable is empty or absent")
        write_pgpass(
            args.pgpass_target,
            args.host,
            args.port,
            source_database,
            args.database,
            found,
            args.admin_user,
            admin_password,
        )
        print("[configure-runtime-db-roles] wrote owner-only isolated pgpass")
    else:
        if not args.admin_user or not args.admin_password_env:
            parser.error("role environment generation requires admin credentials")
        admin_password = os.environ.get(args.admin_password_env)
        if not admin_password:
            parser.error("admin password environment variable is empty or absent")
        proxy_secret = environment_secret(args.proxy_env_file, "ISMS_DEVICE_CONTROL_PROXY_SECRET")
        provision_proxy_role(
            args.host, args.port, args.database, args.admin_user, admin_password, proxy_secret
        )
        write_environment(args.target, args.host, args.port, args.database, found, proxy_secret)
        print("[configure-runtime-db-roles] wrote owner-only role-separated environment")
        if args.mail_env_file:
            provision_mail_worker_role(
                args.host, args.port, args.database, args.admin_user, admin_password,
                proxy_secret, args.mail_env_file,
            )
            print("[configure-runtime-db-roles] refreshed the mail worker role and DSN")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
