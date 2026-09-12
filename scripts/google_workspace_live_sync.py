#!/usr/bin/env python3
"""One live collection run of the Google Workspace DWD reader.

The private key is only referenced via an argument at run time and is never stored in the DB, stdout or logs.
Only GET is used against the external API, reusing the normalization and evidence SQL of the existing connector_sync.py.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote
from typing import Any

import requests
from google.auth.transport.requests import Request
from google.oauth2 import service_account

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import validate_manifests as manifest_validator  # noqa: E402

from connector_sync import (  # noqa: E402
    ReplayError,
    array_literal,
    iso,
    integration_id as replay_integration_id,
    json_literal,
    nested,
    phase2_manifest,
    psql,
    resource_error_sql,
    resource_run_sql,
    resource_stats,
    response_records,
    sql_literal,
    write_events,
    write_files,
    write_group_members,
    write_groups,
    write_oauth,
    write_permissions,
    write_users,
)


class LiveSyncError(ReplayError):
    pass


def live_manifest() -> dict[str, Any]:
    return manifest_validator.validate_manifest(ROOT / "connectors" / "google_workspace" / "v4.yaml")


def safe_error(status: int, body: Any) -> str:
    reason = None
    if isinstance(body, dict):
        error = body.get("error")
        if isinstance(error, dict):
            errors = error.get("errors")
            if isinstance(errors, list) and errors and isinstance(errors[0], dict):
                reason = errors[0].get("reason")
            reason = reason or error.get("status")
    return f"HTTP {status}" + (f" ({reason})" if reason else "")


class GoogleReader:
    def __init__(self, key_path: Path, subject: str, scopes: list[str]) -> None:
        self.credentials = service_account.Credentials.from_service_account_file(
            str(key_path), scopes=scopes, subject=subject
        )
        self._local = threading.local()

    def get(self, url: str, params: dict[str, Any]) -> tuple[int, dict[str, Any] | None, str | None]:
        for attempt in range(6):
            if not self.credentials.valid or self.credentials.expired:
                self.credentials.refresh(Request())
            session = getattr(self._local, "session", None)
            if session is None:
                session = requests.Session()
                self._local.session = session
            response = session.get(
                url,
                params=params,
                headers={"Authorization": f"Bearer {self.credentials.token}"},
                timeout=30,
            )
            try:
                body = response.json()
            except ValueError:
                body = None
            if response.status_code == 200:
                if not isinstance(body, dict):
                    raise LiveSyncError(f"API応答がobjectではありません: {url}")
                return 200, body, None
            if response.status_code in {408, 429, 500, 502, 503, 504} and attempt < 5:
                retry_after = response.headers.get("Retry-After")
                delay = float(retry_after) if retry_after and retry_after.isdigit() else 2**attempt
                time.sleep(min(delay, 60))
                continue
            return response.status_code, body, safe_error(response.status_code, body)
        raise LiveSyncError(f"再試行上限に達しました: {url}")


def page_responses(
    reader: GoogleReader,
    url: str,
    params: dict[str, Any],
    *,
    page_size_key: str,
    page_size: int,
    skip_statuses: set[int] | None = None,
    external_id: str | None = None,
) -> list[dict[str, Any]]:
    responses: list[dict[str, Any]] = []
    page_token: str | None = None
    while True:
        query = dict(params)
        query[page_size_key] = page_size
        if page_token:
            query["pageToken"] = page_token
        status, body, detail = reader.get(url, query)
        if status != 200:
            if skip_statuses and status in skip_statuses:
                return responses
            row: dict[str, Any] = {"status": status, "error": detail or f"HTTP {status}"}
            if external_id:
                row["for_external_id"] = external_id
            responses.append(row)
            return responses
        responses.append({"status": 200, "body": body})
        page_token = body.get("nextPageToken") if body else None
        if not page_token:
            return responses


def records(responses: list[dict[str, Any]], resource: str) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for response in responses:
        if response.get("status") == 200:
            result.extend(response_records(resource, response))
    return result


def collect_live(reader: GoogleReader, subject: str, report_days: int, public_only: bool) -> dict[str, Any]:
    base_admin = "https://admin.googleapis.com/admin"
    base_drive = "https://www.googleapis.com/drive/v3"
    def progress(label: str) -> None:
        print(f"[google-workspace-live-sync] {label}", file=sys.stderr, flush=True)

    progress("users:start")
    users = page_responses(
        reader,
        f"{base_admin}/directory/v1/users",
        {
            "customer": "my_customer",
            "projection": "full",
            "fields": "nextPageToken,users(id,primaryEmail,isAdmin,isEnrolledIn2Sv,suspended,lastLoginTime)",
        },
        page_size_key="maxResults",
        page_size=500,
    )
    progress("users:done")
    progress("groups:start")
    groups = page_responses(
        reader,
        f"{base_admin}/directory/v1/groups",
        {"customer": "my_customer", "fields": "nextPageToken,groups(id,name,email)"},
        page_size_key="maxResults",
        page_size=200,
    )
    progress("groups:done")

    def members_for_group(group: dict[str, Any]) -> list[dict[str, Any]]:
        group_id = str(group.get("id", ""))
        return page_responses(
            reader,
            f"{base_admin}/directory/v1/groups/{quote(group_id, safe='')}/members",
            {"fields": "nextPageToken,members(id,type)"},
            page_size_key="maxResults",
            page_size=200,
            skip_statuses={404},
            external_id=group_id,
        )

    group_members: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=8) as executor:
        for responses in executor.map(members_for_group, records(groups, "groups")):
            group_members.extend(responses)
    progress("group_members:done")

    def tokens_for_user(user: dict[str, Any]) -> list[dict[str, Any]]:
        user_id = str(user.get("id", ""))
        status, body, detail = reader.get(
            f"{base_admin}/directory/v1/users/{quote(user_id, safe='')}/tokens",
            {"fields": "items(clientId,displayText,scopes)"},
        )
        if status == 404:
            return []
        if status != 200:
            return [{
                "status": status,
                "error": detail or f"HTTP {status}",
                "for_external_id": user_id,
            }]
        return [{"status": 200, "body": body or {}}]

    oauth_tokens: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=8) as executor:
        for responses in executor.map(tokens_for_user, records(users, "users")):
            oauth_tokens.extend(responses)
    progress("oauth_tokens:done")

    drive_query = "trashed = false"
    if public_only:
        drive_query += " and ('anyone' in readers or 'anyone' in writers)"
    drive_files = page_responses(
        reader,
        f"{base_drive}/files",
        {
            "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true",
            "corpora": "allDrives",
            "q": drive_query,
            "fields": "nextPageToken,files(id,name,mimeType,driveId,parents,modifiedTime,permissions(id,type,role,domain,emailAddress,allowFileDiscovery,expirationTime))",
        },
        page_size_key="pageSize",
        page_size=1000,
    )
    progress("drive_files:done")

    drive_permissions: list[dict[str, Any]] = []
    for response in drive_files:
        if response.get("status") != 200:
            drive_permissions.append({
                "status": response.get("status"),
                "error": response.get("error"),
            })
            continue
        for file_item in response_records("drive_files", response):
            drive_permissions.append({
                "status": 200,
                "for_external_id": file_item.get("id"),
                "body": {"permissions": file_item.get("permissions") or []},
            })
    if not drive_permissions:
        drive_permissions.append({"status": 200, "body": {"permissions": []}})
    progress("drive_permissions:done")

    report_params: dict[str, Any] = {
        "maxResults": 1000,
        "fields": "nextPageToken,items(id,actor,events)",
    }
    report_start = datetime.now(timezone.utc) - timedelta(days=report_days)
    report_params["startTime"] = report_start.isoformat().replace("+00:00", "Z")
    reports = page_responses(
        reader,
        f"{base_admin}/reports/v1/activity/users/all/applications/login",
        report_params,
        page_size_key="maxResults",
        page_size=1000,
    )
    progress("admin_reports_login:done")

    return {
        "connector": "google_workspace",
    "manifest_version": 4,
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "subject": subject,
        "drive_scan": "public-only" if public_only else "all-files",
        "report_start": report_params["startTime"],
        "resources": {
            "users": {"responses": users},
            "groups": {"responses": groups},
            "group_members": {"responses": group_members},
            "oauth_tokens": {"responses": oauth_tokens},
            "drive_files": {"responses": drive_files},
            "drive_permissions": {"responses": drive_permissions},
            "admin_reports_login": {"responses": reports},
        },
    }


def live_integration_id(
    dsn: str, token: str, subject: str, manifest: dict[str, Any]
) -> str:
    secret_ref = f"local-gog-service-account:{subject}"
    approval = "NULL,NULL"
    if manifest["kind"] != "reader":
        approval = (
            "(SELECT u.id FROM app.users u WHERE u.tenant_id=app.current_tenant() "
            "AND u.email=" + sql_literal(subject) + " AND u.status='active' LIMIT 1),now()"
        )
    sql = (
        "BEGIN;SELECT app.set_tenant_context(" + sql_literal(token) + ");"
        "INSERT INTO app.integrations "
        "(tenant_id,connector,manifest_version,kind,secret_ref,status,approved_by,approved_at) "
        "SELECT app.current_tenant(),'google_workspace',"
        + str(manifest["version"])
        + ","
        + sql_literal(manifest["kind"])
        + ","
        + sql_literal(secret_ref)
        + ",'active',"
        + approval
        + " ON CONFLICT (tenant_id,connector) DO UPDATE SET "
        "manifest_version=EXCLUDED.manifest_version,kind=EXCLUDED.kind,secret_ref=EXCLUDED.secret_ref,"
        "status='active',updated_at=now() RETURNING id;COMMIT;"
    )
    rc, out, err = psql(dsn, sql, tuples=True)
    if rc != 0:
        raise LiveSyncError(f"integrationの準備に失敗しました: {err}")
    values = [line.strip() for line in out.splitlines() if line.strip()]
    if not values or len(values[-1]) < 20:
        raise LiveSyncError("integration idを取得できませんでした")
    return values[-1]


def write_live(db: str, token: str, subject: str, doc: dict[str, Any]) -> dict[str, Any]:
    manifest = live_manifest()
    dsn = f"postgres:///{db}?user=app_rw"
    integration = live_integration_id(dsn, token, subject, manifest)
    statements: list[str] = ["BEGIN;", "SELECT app.set_tenant_context(" + sql_literal(token) + ");"]
    summary: dict[str, Any] = {"resources": {}, "report_start": doc["report_start"]}
    manifest_names = {resource["name"] for resource in manifest["resources"]}
    for resource, spec in doc["resources"].items():
        if resource not in manifest_names:
            raise LiveSyncError(f"マニフェスト未定義のresourceです: {resource}")
        stats = resource_stats(resource, spec)
        fetched, collected, unreadable, gone, not_collected, coverage, collected_records = stats
        status = "success" if unreadable == gone == not_collected == 0 else "partial"
        detail = "; ".join(
            str(response["error"])
            for response in spec.get("responses", [])
            if response.get("error")
        ) or None
        if resource == "users":
            statements.extend(write_users(collected_records))
        elif resource == "groups":
            statements.extend(write_groups(collected_records))
        elif resource == "group_members":
            pairs = [
                (response.get("for_external_id"), item)
                for response in spec["responses"]
                if response.get("status") == 200
                for item in response_records(resource, response)
            ]
            statements.extend(write_group_members(pairs))
        elif resource == "oauth_tokens":
            pairs = [
                (response.get("for_external_id"), item)
                for response in spec["responses"]
                if response.get("status") == 200
                for item in response_records(resource, response)
            ]
            statements.extend(write_oauth(pairs))
        elif resource == "drive_files":
            statements.extend(write_files(collected_records))
        elif resource == "drive_permissions":
            pairs = [
                (response.get("for_external_id"), item)
                for response in spec["responses"]
                if response.get("status") == 200
                for item in response_records(resource, response)
            ]
            statements.extend(write_permissions(pairs))
        elif resource == "admin_reports_login":
            statements.extend(write_events(collected_records))
        statements.extend(resource_error_sql(resource, spec))
        statements.append(
            resource_run_sql(
                integration,
                resource,
                "full",
                stats,
                status,
                detail,
                collected_records,
                spec["responses"],
            )
        )
        summary["resources"][resource] = {
            "fetched": fetched,
            "collected": collected,
            "unreadable": unreadable,
            "gone": gone,
            "not_collected": not_collected,
            "coverage": round(coverage, 3),
            "status": status,
        }
    statements.append("SELECT app.rebuild_effective_grants(app.current_tenant());")
    cursor = {
        "last_full_sync": doc["captured_at"],
        "impersonated_user": subject,
        "admin_reports_login_start": doc["report_start"],
    }
    statements.append(
        "UPDATE app.integrations SET cursors=cursors || "
        + json_literal(cursor)
        + ",status='active',updated_at=now() WHERE tenant_id=app.current_tenant() AND id="
        + sql_literal(integration)
        + "::uuid;"
    )
    statements.append("COMMIT;")
    rc, _, err = psql(dsn, "\n".join(statements))
    if rc != 0:
        raise LiveSyncError(f"実収集結果の保存に失敗しました（トランザクションは未確定）: {err}")
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--subject", required=True)
    parser.add_argument("--token", default=None)
    parser.add_argument("--token-stdin", action="store_true")
    parser.add_argument("--db", default=os.environ.get("ISMS_DB", "isms_dev"))
    parser.add_argument("--report-days", type=int, default=30)
    parser.add_argument(
        "--public-only",
        action="store_true",
        help="Driveは検索公開資源だけを取得する（公開資源チェックの即時更新用）",
    )
    args = parser.parse_args()
    token = args.token
    if args.token_stdin:
        token = sys.stdin.read().strip()
    if not token or len(token) < 32:
        print("[google-workspace-live-sync] NG: tenant tokenがありません", file=sys.stderr)
        return 1
    if not args.key.is_file():
        print("[google-workspace-live-sync] NG: 鍵ファイルがありません", file=sys.stderr)
        return 1
    if args.report_days < 1 or args.report_days > 180:
        print("[google-workspace-live-sync] NG: report-daysは1〜180です", file=sys.stderr)
        return 1
    try:
        manifest = live_manifest()
        reader = GoogleReader(args.key, args.subject, manifest["auth"]["scopes"])
        reader.credentials.refresh(Request())
        summary = write_live(
            args.db,
            token,
            args.subject,
            collect_live(reader, args.subject, args.report_days, args.public_only),
        )
    except (LiveSyncError, OSError, ValueError) as exc:
        print(f"[google-workspace-live-sync] NG: {exc}", file=sys.stderr)
        return 1
    print("[google-workspace-live-sync] OK: 実APIの読み取り結果を記録しました")
    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
