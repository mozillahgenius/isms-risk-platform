#!/usr/bin/env python3
"""記録済みレスポンスを Google Workspace の正規化グラフへ再生する。

実 API は呼ばない。fixture の sidecar SHA-256 を先に照合し、改変された応答は
DB に一行も書かずに終了する。実 API 実装をこのスクリプトへ混ぜないことで、
Phase 2 の同期・正規化・逆向き検証を無通信で再現できるようにする。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import validate_manifests as manifest_validator  # noqa: E402


class ReplayError(RuntimeError):
    pass


def sql_literal(value: Any) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "true" if value else "false"
    return "'" + str(value).replace("'", "''") + "'"


def json_literal(value: Any) -> str:
    return sql_literal(json.dumps(value, ensure_ascii=False, sort_keys=True)) + "::jsonb"


def array_literal(values: list[str]) -> str:
    if not values:
        return "ARRAY[]::text[]"
    return "ARRAY[" + ",".join(sql_literal(v) for v in values) + "]::text[]"


def psql(dsn: str, sql: str, *, tuples: bool = False) -> tuple[int, str, str]:
    args = ["psql", "-v", "ON_ERROR_STOP=1", "-q", "-d", dsn]
    if tuples:
        args.insert(1, "-At")
    returncode = subprocess.run(args, input=sql, text=True,
                                capture_output=True)
    return returncode.returncode, returncode.stdout.strip(), returncode.stderr.strip()


def dsn_for(db: str) -> str:
    template = os.environ.get("ISMS_CHECKER_DSN_TEMPLATE")
    if template:
        return template.format(db=db, user="app_rw")
    return f"postgres:///{db}?user=app_rw"


def verify_fixture(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise ReplayError(f"fixture がありません: {path}")
    sidecar = Path(str(path) + ".sha256")
    if not sidecar.is_file():
        raise ReplayError(f"fixture の SHA-256 sidecar がありません: {sidecar}")
    expected = sidecar.read_text(encoding="utf-8").split()[0]
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if expected != actual:
        raise ReplayError(
            f"fixture の SHA-256 が一致しません（期待 {expected} / 実測 {actual}）"
        )
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ReplayError(f"fixture JSON が壊れています: {exc}") from exc
    if not isinstance(doc, dict) or doc.get("schema_version") != 1:
        raise ReplayError("fixture schema_version=1 が必要です")
    if not isinstance(doc.get("resources"), dict):
        raise ReplayError("fixture resources が object ではありません")
    return doc


def iso(value: str | None) -> str | None:
    if not value:
        return None
    text = value.replace("Z", "+00:00")
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).isoformat()


def nested(value: Any, path: str) -> Any:
    for part in path.split("."):
        if isinstance(value, dict):
            value = value.get(part)
        else:
            return None
    return value


def response_records(resource: str, response: dict[str, Any]) -> list[dict[str, Any]]:
    body = response.get("body") or {}
    keys = {
        "users": "users",
        "groups": "groups",
        "group_members": "members",
        "oauth_tokens": "items",
        "drive_files": "files",
        "drive_permissions": "permissions",
        "admin_reports_login": "items",
    }
    records = body.get(keys.get(resource, "items"), [])
    if not isinstance(records, list):
        raise ReplayError(f"{resource}: body のレコード配列がありません")
    return [r for r in records if isinstance(r, dict)]


def resource_stats(resource: str, spec: dict[str, Any]) -> tuple[int, int, int, int, int, float, list[dict[str, Any]]]:
    fetched = collected = unreadable = gone = not_collected = 0
    collected_records: list[dict[str, Any]] = []
    responses = spec.get("responses")
    if not isinstance(responses, list) or not responses:
        raise ReplayError(f"{resource}: responses が空です")
    for response in responses:
        if not isinstance(response, dict):
            raise ReplayError(f"{resource}: response は object である必要があります")
        status = response.get("status")
        if status == 200:
            records = response_records(resource, response)
            collected_records.extend(records)
            fetched += len(records)
            collected += len(records)
        elif status == 403:
            fetched += 1
            unreadable += 1
        elif status == 404:
            gone += 1
        elif status in (408, 429, 500, 502, 503, 504):
            fetched += 1
            not_collected += 1
        else:
            raise ReplayError(f"{resource}: 許可していない status={status!r}")
    denominator = collected + unreadable + not_collected
    coverage = collected / denominator if denominator else 1.0
    return fetched, collected, unreadable, gone, not_collected, coverage, collected_records


def phase2_manifest() -> dict[str, Any]:
    path = ROOT / "connectors" / "google_workspace" / "v3.yaml"
    try:
        return manifest_validator.validate_manifest(path)
    except manifest_validator.Problem as exc:
        raise ReplayError(f"マニフェスト検証に失敗しました: {exc}") from exc


def resource_run_sql(integration_id: str, resource: str, mode: str,
                     stats: tuple[int, int, int, int, int, float, list[dict[str, Any]]],
                     status: str, detail: str | None, response_rows: list[dict[str, Any]],
                     responses: list[dict[str, Any]]) -> str:
    fetched, collected, unreadable, gone, not_collected, coverage, _ = stats
    run = (
        "WITH run AS (INSERT INTO app.integration_runs "
        "(tenant_id,integration_id,resource_name,mode,started_at,finished_at,"
        "fetched,collected,unreadable,gone,not_collected,coverage_ratio,status,error_detail) "
        "SELECT app.current_tenant()," + sql_literal(integration_id) + "::uuid," +
        sql_literal(resource) + "," + sql_literal(mode) + ",now(),now()," +
        f"{fetched},{collected},{unreadable},{gone},{not_collected},{coverage:.3f}," +
        sql_literal(status) + "," + sql_literal(detail) + " RETURNING id) "
        "INSERT INTO app.integration_resource_runs "
        "(tenant_id,integration_run_id,resource_name,external_id,collection_state,"
        "http_status,record_count,error_detail) VALUES "
    )
    values: list[str] = []
    for record in response_rows:
        external_id = record.get("id") or record.get("external_id") or record.get("clientId")
        if resource == "admin_reports_login":
            external_id = nested(record, "id.uniqueQualifier")
        values.append(
            "(app.current_tenant(),(SELECT id FROM run)," + sql_literal(resource) + "," +
            sql_literal(external_id) + ",'collected',200,1,NULL)"
        )
    for response in responses:
        status_code = response.get("status")
        if status_code == 200:
            continue
        state = {
            403: "unreadable",
            404: "gone",
            408: "not_collected",
            429: "not_collected",
            500: "not_collected",
            502: "not_collected",
            503: "not_collected",
            504: "not_collected",
        }.get(status_code)
        if state is None:
            continue
        values.append(
            "(app.current_tenant(),(SELECT id FROM run)," + sql_literal(resource) + "," +
            sql_literal(response.get("external_id") or response.get("for_external_id")) + "," +
            sql_literal(state) + "," + sql_literal(status_code) + ",0," +
            sql_literal(response.get("error")) + ")"
        )
    if not values:
        values.append(
            "(app.current_tenant(),(SELECT id FROM run)," + sql_literal(resource) +
            ",NULL,'not_collected',NULL,0," + sql_literal(detail) + ")"
        )
    return run + ",".join(values) + ";"


def write_users(records: list[dict[str, Any]]) -> list[str]:
    statements: list[str] = []
    for item in records:
        statements.append(
            "INSERT INTO app.accounts "
            "(tenant_id,connector,external_id,email,is_admin,mfa_enrolled,suspended,last_login_at,attributes) "
            "VALUES (app.current_tenant(),'google_workspace'," +
            sql_literal(item.get("id")) + "," + sql_literal(item.get("primaryEmail")) + "," +
            sql_literal(item.get("isAdmin")) + "," + sql_literal(item.get("isEnrolledIn2Sv")) + "," +
            sql_literal(item.get("suspended")) + "," + sql_literal(iso(item.get("lastLoginTime"))) + "," +
            json_literal(item) + ") ON CONFLICT (tenant_id,connector,external_id) DO UPDATE SET "
            "email=EXCLUDED.email,is_admin=EXCLUDED.is_admin,mfa_enrolled=EXCLUDED.mfa_enrolled,"
            "suspended=EXCLUDED.suspended,last_login_at=EXCLUDED.last_login_at,"
            "attributes=EXCLUDED.attributes,last_seen_at=now(),updated_at=now();"
        )
    return statements


def write_groups(records: list[dict[str, Any]]) -> list[str]:
    statements: list[str] = []
    for item in records:
        statements.append(
            "INSERT INTO app.groups (tenant_id,connector,external_id,name,email) VALUES "
            "(app.current_tenant(),'google_workspace'," + sql_literal(item.get("id")) + "," +
            sql_literal(item.get("name")) + "," + sql_literal(item.get("email")) + ") "
            "ON CONFLICT (tenant_id,connector,external_id) DO UPDATE SET "
            "name=EXCLUDED.name,email=EXCLUDED.email,updated_at=now();"
        )
    return statements


def write_group_members(records: list[tuple[str | None, dict[str, Any]]]) -> list[str]:
    statements: list[str] = []
    for group_external_id, item in records:
        if item.get("type", "USER").upper() != "USER":
            continue
        statements.append(
            "INSERT INTO app.memberships_graph (tenant_id,account_id,group_id) "
            "SELECT app.current_tenant(),a.id,g.id FROM app.accounts a JOIN app.groups g "
            "ON g.tenant_id=app.current_tenant() AND g.connector='google_workspace' AND g.external_id=" +
            sql_literal(group_external_id) + " WHERE a.tenant_id=app.current_tenant() AND "
            "a.connector='google_workspace' AND a.external_id=" + sql_literal(item.get("id")) +
            " ON CONFLICT DO NOTHING;"
        )
    return statements


def write_oauth(records: list[tuple[str | None, dict[str, Any]]]) -> list[str]:
    statements: list[str] = []
    for account_external_id, item in records:
        scopes = item.get("scopes") or []
        high_risk_scopes = {
            "https://www.googleapis.com/auth/drive",
            "https://www.googleapis.com/auth/drive.readonly",
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/gmail.modify",
        }
        risk_scopes = [s for s in scopes if s in high_risk_scopes or "admin." in s]
        statements.append(
            "INSERT INTO app.oauth_apps (tenant_id,connector,external_id,name,scopes,risk_scopes) "
            "VALUES (app.current_tenant(),'google_workspace'," + sql_literal(item.get("clientId")) + "," +
            sql_literal(item.get("displayText")) + "," + array_literal(scopes) + "," + array_literal(risk_scopes) +
            ") ON CONFLICT (tenant_id,connector,external_id) DO UPDATE SET name=EXCLUDED.name,"
            "scopes=EXCLUDED.scopes,risk_scopes=EXCLUDED.risk_scopes,updated_at=now();"
        )
        statements.append(
            "DELETE FROM app.app_grants ag USING app.accounts a,app.oauth_apps oa WHERE "
            "ag.tenant_id=app.current_tenant() AND ag.account_id=a.id AND ag.oauth_app_id=oa.id "
            "AND a.external_id=" + sql_literal(account_external_id) + " AND oa.external_id=" +
            sql_literal(item.get("clientId")) + ";"
        )
        statements.append(
            "INSERT INTO app.app_grants (tenant_id,account_id,oauth_app_id,granted_at) "
            "SELECT app.current_tenant(),a.id,oa.id,now() FROM app.accounts a,app.oauth_apps oa "
            "WHERE a.tenant_id=app.current_tenant() AND oa.tenant_id=app.current_tenant() "
            "AND a.external_id=" + sql_literal(account_external_id) + " AND oa.external_id=" +
            sql_literal(item.get("clientId")) + " ON CONFLICT DO NOTHING;"
        )
    statements.append(
        "UPDATE app.oauth_apps oa SET grant_count=(SELECT count(*) FROM app.app_grants ag "
        "WHERE ag.tenant_id=oa.tenant_id AND ag.oauth_app_id=oa.id) "
        "WHERE oa.tenant_id=app.current_tenant();"
    )
    return statements


def write_files(records: list[dict[str, Any]]) -> list[str]:
    statements: list[str] = []
    for item in records:
        statements.append(
            "INSERT INTO app.resources (tenant_id,connector,external_id,kind,name,parent_id,drive_id,"
            "inherit_permissions,collection_state,last_modified_at,attributes) SELECT app.current_tenant(),"
            "'google_workspace'," + sql_literal(item.get("id")) + "," + sql_literal(item.get("mimeType")) + ","+
            sql_literal(item.get("name")) + ",NULL," + sql_literal(item.get("driveId")) +
            ",true,'collected'," + sql_literal(iso(item.get("modifiedTime"))) + "," +
            json_literal(item) +
            " ON CONFLICT (tenant_id,connector,external_id) DO UPDATE SET kind=EXCLUDED.kind,name=EXCLUDED.name,"
            "parent_id=EXCLUDED.parent_id,drive_id=EXCLUDED.drive_id,collection_state='collected',"
            "last_modified_at=EXCLUDED.last_modified_at,attributes=EXCLUDED.attributes,updated_at=now();"
        )
    for item in records:
        parents = item.get("parents") or []
        if parents:
            statements.append(
                "UPDATE app.resources child SET parent_id=parent.id FROM app.resources parent WHERE "
                "child.tenant_id=app.current_tenant() AND parent.tenant_id=app.current_tenant() AND "
                "child.connector='google_workspace' AND parent.connector='google_workspace' AND "
                "child.external_id=" + sql_literal(item.get("id")) + " AND parent.external_id=" +
                sql_literal(parents[0]) + ";"
            )
    return statements


def permission_subject(item: dict[str, Any]) -> tuple[str, str | None, str | None, str | None]:
    kind = str(item.get("type") or "").lower()
    email = item.get("emailAddress")
    domain = item.get("domain")
    discoverable = bool(item.get("allowFileDiscovery"))
    if kind == "anyone":
        return ("public" if discoverable else "anyone", None, None, None)
    if kind == "domain":
        return ("external_domain", None, None, domain)
    if kind == "group":
        return ("group", email, None, None)
    if kind == "user":
        return ("account", email, None, None)
    raise ReplayError(f"drive permission の type が不明です: {kind!r}")


def write_permissions(records: list[tuple[str | None, dict[str, Any]]]) -> list[str]:
    statements: list[str] = []
    resources_seen: set[str | None] = set()
    for resource_external_id, item in records:
        if resource_external_id in resources_seen:
            continue
        resources_seen.add(resource_external_id)
        statements.append(
            "DELETE FROM app.grants g USING app.resources r WHERE g.tenant_id=app.current_tenant() "
            "AND r.tenant_id=app.current_tenant() AND g.resource_id=r.id AND r.connector='google_workspace' "
            "AND r.external_id=" + sql_literal(resource_external_id) + ";"
        )
    for resource_external_id, item in records:
        subject, account_email, group_email, domain = permission_subject(item)
        account_id = (
            "(SELECT a.id FROM app.accounts a WHERE a.tenant_id=app.current_tenant() "
            "AND a.email=" + sql_literal(account_email) + " LIMIT 1)"
            if account_email and subject == "account" else "NULL"
        )
        group_id = (
            "(SELECT g.id FROM app.groups g WHERE g.tenant_id=app.current_tenant() "
            "AND g.email=" + sql_literal(group_email) + " LIMIT 1)"
            if group_email and subject == "group" else "NULL"
        )
        statements.append(
            "INSERT INTO app.grants (tenant_id,resource_id,subject_kind,subject_account_id,subject_group_id,"
            "subject_domain,role,expires_at) SELECT app.current_tenant(),r.id," + sql_literal(subject) + ","+
            account_id + "," + group_id + "," + sql_literal(domain) + "," + sql_literal(item.get("role")) + ","+
            sql_literal(iso(item.get("expirationTime"))) + " FROM app.resources r WHERE r.tenant_id=app.current_tenant() "
            "AND r.connector='google_workspace' AND r.external_id=" + sql_literal(resource_external_id) + ";"
        )
    return statements


def write_events(records: list[dict[str, Any]]) -> list[str]:
    statements: list[str] = []
    for item in records:
        event_id = nested(item, "id.uniqueQualifier")
        occurred_at = nested(item, "id.time")
        events = item.get("events") or []
        event_type = events[0].get("name") if events and isinstance(events[0], dict) else "unknown"
        actor = nested(item, "actor.email")
        statements.append(
            "INSERT INTO app.raw_events (tenant_id,connector,resource_name,external_id,occurred_at,event_type,"
            "actor_email,attributes,collection_state) VALUES (app.current_tenant(),'google_workspace',"
            "'admin_reports_login'," + sql_literal(event_id) + "," + sql_literal(iso(occurred_at)) + ","+
            sql_literal(event_type) + "," + sql_literal(actor) + "," + json_literal(item) + ",'collected') "
            "ON CONFLICT (tenant_id,connector,external_id) DO NOTHING;"
        )
    return statements


def resource_error_sql(resource: str, spec: dict[str, Any]) -> list[str]:
    statements: list[str] = []
    for response in spec.get("responses", []):
        status = response.get("status")
        if status not in (403, 404):
            continue
        external_id = response.get("external_id") or response.get("for_external_id")
        state = "unreadable" if status == 403 else "gone"
        if resource == "drive_files" and external_id:
            statements.append(
                "UPDATE app.resources SET collection_state=" + sql_literal(state) + ",updated_at=now() "
                "WHERE tenant_id=app.current_tenant() AND connector='google_workspace' AND external_id=" +
                sql_literal(external_id) + ";"
            )
        if resource == "drive_permissions" and external_id and status == 404:
            statements.append(
                "UPDATE app.resources SET collection_state='gone',updated_at=now() WHERE tenant_id=app.current_tenant() "
                "AND connector='google_workspace' AND external_id=" + sql_literal(external_id) + ";"
            )
    return statements


def integration_id(dsn: str, token: str, connector: str, version: int) -> str:
    sql = (
        "BEGIN;SELECT app.set_tenant_context(" + sql_literal(token) + ");"
        "INSERT INTO app.integrations (tenant_id,connector,manifest_version,kind,secret_ref) "
        "SELECT app.current_tenant()," + sql_literal(connector) + "," + str(version) + ",'reader',"
        "'replay-fixture' ON CONFLICT (tenant_id,connector) DO UPDATE SET manifest_version=EXCLUDED.manifest_version,"
        "kind='reader',status='active',updated_at=now() RETURNING id;COMMIT;"
    )
    rc, out, err = psql(dsn, sql, tuples=True)
    if rc != 0:
        raise ReplayError(f"integration の準備に失敗しました: {err}")
    values = [line.strip() for line in out.splitlines() if line.strip()]
    if not values or len(values[-1]) < 20:
        raise ReplayError(f"integration id を取得できませんでした: {out}")
    return values[-1]


def replay(db: str, token: str, fixture_path: Path) -> dict[str, Any]:
    doc = verify_fixture(fixture_path)
    manifest = phase2_manifest()
    if doc.get("connector") != manifest["connector"]:
        raise ReplayError("fixture の connector がマニフェストと一致しません")
    if doc.get("manifest_version") != manifest["version"]:
        raise ReplayError("fixture の manifest_version がマニフェストと一致しません")
    dsn = dsn_for(db)
    integration = integration_id(dsn, token, manifest["connector"], manifest["version"])
    statements: list[str] = ["BEGIN;", "SELECT app.set_tenant_context(" + sql_literal(token) + ");"]
    summary: dict[str, Any] = {"integration_id": integration, "resources": {}}
    for resource, spec in doc["resources"].items():
        if resource not in {r["name"] for r in manifest["resources"]}:
            raise ReplayError(f"fixture にマニフェスト未定義の resource があります: {resource}")
        stats = resource_stats(resource, spec)
        fetched, collected, unreadable, gone, not_collected, coverage, records = stats
        status = "success" if unreadable == gone == not_collected == 0 else "partial"
        errors = [r.get("error") for r in spec.get("responses", []) if r.get("status") != 200 and r.get("error")]
        detail = "; ".join(errors) or None
        if resource == "users":
            statements.extend(write_users(records))
        elif resource == "groups":
            statements.extend(write_groups(records))
        elif resource == "group_members":
            pairs = [(response.get("for_external_id"), item)
                     for response in spec.get("responses", [])
                     if response.get("status") == 200
                     for item in response_records(resource, response)]
            statements.extend(write_group_members(pairs))
        elif resource == "oauth_tokens":
            pairs = [(response.get("for_external_id"), item)
                     for response in spec.get("responses", [])
                     if response.get("status") == 200
                     for item in response_records(resource, response)]
            statements.extend(write_oauth(pairs))
        elif resource == "drive_files":
            statements.extend(write_files(records))
        elif resource == "drive_permissions":
            pairs = [(response.get("for_external_id"), x) for response in spec.get("responses", [])
                     if response.get("status") == 200 for x in response_records(resource, response)]
            statements.extend(write_permissions(pairs))
        elif resource == "admin_reports_login":
            statements.extend(write_events(records))
        statements.extend(resource_error_sql(resource, spec))
        statements.append(resource_run_sql(
            integration, resource, "full", stats, status, detail, records,
            spec.get("responses", [])))
        summary["resources"][resource] = {
            "fetched": fetched, "collected": collected, "unreadable": unreadable,
            "gone": gone, "not_collected": not_collected, "coverage": round(coverage, 3),
            "status": status,
        }
    statements.append("SELECT app.rebuild_effective_grants(app.current_tenant());")
    statements.append(
        "UPDATE app.integrations SET cursors=cursors || " +
        json_literal({"replay-basic": doc.get("captured_at")}) + ",updated_at=now() "
        "WHERE tenant_id=app.current_tenant() AND id=" + sql_literal(integration) + "::uuid;"
    )
    statements.append("COMMIT;")
    rc, _, err = psql(dsn, "\n".join(statements))
    if rc != 0:
        raise ReplayError(f"同期の再生に失敗しました（ロールバック済み）: {err}")
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--token", required=True)
    parser.add_argument("--db", default=os.environ.get("ISMS_DB", "isms_dev"))
    parser.add_argument("--fixture", type=Path, default=ROOT / "fixtures/google_workspace/replay-basic.json")
    args = parser.parse_args()
    try:
        summary = replay(args.db, args.token, args.fixture)
    except ReplayError as exc:
        print(f"[connector-sync] NG: {exc}", file=sys.stderr)
        return 1
    print("[connector-sync] OK: 記録済みレスポンスを再生しました")
    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
