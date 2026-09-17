#!/usr/bin/env python3
"""Register and verify the one-way backoffice -> ISMS HR identity link.

The backoffice database is read-only for this script.  ``--apply`` writes only
the ISMS identity/account projection and never changes the backoffice schema
or rows.  The immutable reference is bo.workforce_members.id, not worker_ref.
"""
from __future__ import annotations

import argparse
import os
import subprocess
from dataclasses import dataclass
from typing import Any


DEFAULT_BACKOFFICE_DB = "postgres://127.0.0.1:55432/ssi"


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def psql(dsn: str, sql: str, read_only: bool = True) -> list[list[str]]:
    statement = sql.strip().rstrip(';').strip()
    wrapped = f"BEGIN {'READ ONLY' if read_only else ''};\n{statement};\nCOMMIT;"
    result = subprocess.run(
        ["psql", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-q", "-d", dsn, "-c", wrapped],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"psql failed: {detail}")
    return [line.split("\t") for line in result.stdout.splitlines() if line]


@dataclass(frozen=True)
class WorkforceMember:
    id: str
    email: str
    display_name: str
    worker_ref: str


def lookup_workforce_member(dsn: str, email: str) -> list[WorkforceMember]:
    rows = psql(
        dsn,
        f"""
SELECT w.id::text, coalesce(u.email::text, ''),
       coalesce(nullif(u.display_name, ''), nullif(a.label, ''), ''),
       w.worker_ref
  FROM bo.workforce_members w
  JOIN bo.actors a ON a.id = w.actor_id AND a.org_id = w.org_id
  JOIN ib.app_users u ON u.id = a.user_id
 WHERE lower(u.email::text) = lower({sql_literal(email)})
   AND (w.active_to IS NULL OR w.active_to >= current_date)
 ORDER BY w.created_at, w.id
""",
    )
    return [WorkforceMember(*row) for row in rows if len(row) == 4]


def read_isms_state(
    dsn: str, tenant_id: str, email: str, tenant_token: str
) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    context = f"SELECT app.set_tenant_context({sql_literal(tenant_token)});"
    identities = psql(
        dsn,
        f"""
{context}
SELECT id::text, coalesce(hr_employee_id, ''), coalesce(primary_email::text, ''), subject_type
  FROM app.identities
 WHERE tenant_id = {sql_literal(tenant_id)}::uuid
""",
    )
    accounts = psql(
        dsn,
        f"""
{context}
SELECT id::text, coalesce(identity_id::text, ''), coalesce(email::text, '')
  FROM app.accounts
 WHERE tenant_id = {sql_literal(tenant_id)}::uuid
   AND connector = 'google_workspace'
   AND lower(email::text) = lower({sql_literal(email)})
""",
    )
    identity_rows = [
        {"id": row[0], "hr_employee_id": row[1], "email": row[2], "subject_type": row[3]}
        for row in identities if len(row) == 4
    ]
    account_rows = [
        {"id": row[0], "identity_id": row[1], "email": row[2]}
        for row in accounts if len(row) == 3
    ]
    return identity_rows, account_rows


def read_device_state(
    dsn: str, tenant_id: str, device_id: str, tenant_token: str
) -> list[dict[str, str]]:
    rows = psql(
        dsn,
        f"""
SELECT app.set_tenant_context({sql_literal(tenant_token)});
SELECT id::text, source, coalesce(assigned_identity_id::text, '')
  FROM app.devices
 WHERE tenant_id = {sql_literal(tenant_id)}::uuid
   AND id = {sql_literal(device_id)}::uuid
""",
    )
    return [
        {"id": row[0], "source": row[1], "assigned_identity_id": row[2]}
        for row in rows if len(row) == 3
    ]


def validate_link(
    workforce: list[dict[str, Any]],
    identities: list[dict[str, Any]],
    accounts: list[dict[str, Any]],
    email: str,
    devices: list[dict[str, Any]] | None = None,
) -> None:
    errors: list[str] = []
    if len(workforce) != 1:
        errors.append(f"backoffice workforce member count={len(workforce)} (expected 1)")
    if len(accounts) != 1:
        errors.append(f"ISMS account count={len(accounts)} (expected 1)")
    if len(workforce) == 1:
        hr_id = str(workforce[0]["id"])
        matching = [row for row in identities if row.get("hr_employee_id") == hr_id]
        if len(matching) != 1:
            errors.append(f"ISMS identity for hr_employee_id={hr_id} count={len(matching)}")
        elif matching[0].get("subject_type") != "employee":
            errors.append("ISMS identity subject_type is not employee")
        elif str(matching[0].get("email", "")).lower() != email.lower():
            errors.append("ISMS identity email does not match backoffice user")
        if len(accounts) == 1 and len(matching) == 1 and accounts[0].get("identity_id") != matching[0].get("id"):
            errors.append("ISMS account.identity_id does not point to the HR-linked identity")
        if devices is not None and len(matching) == 1:
            if len(devices) != 1:
                errors.append(f"ISMS device count={len(devices)} (expected 1)")
            elif devices[0].get("assigned_identity_id") != matching[0].get("id"):
                errors.append("ISMS device.assigned_identity_id does not point to the HR-linked identity")
    if errors:
        raise ValueError("HR identity link check failed: " + "; ".join(errors))


def run_self_test() -> None:
    hr_id = "11111111-1111-1111-1111-111111111111"
    identity_id = "22222222-2222-2222-2222-222222222222"
    workforce = [{"id": hr_id}]
    identity = [{"id": identity_id, "hr_employee_id": hr_id, "email": "owner@example.com", "subject_type": "employee"}]
    account = [{"id": "33333333-3333-3333-3333-333333333333", "identity_id": identity_id}]
    device = [{"id": "44444444-4444-4444-4444-444444444444", "source": "agent", "assigned_identity_id": identity_id}]
    validate_link(workforce, identity, account, "owner@example.com", device)
    invalid = [{**identity[0], "hr_employee_id": "99999999-9999-9999-9999-999999999999"}]
    try:
        validate_link(workforce, invalid, account, "owner@example.com")
    except ValueError as error:
        expected = "ISMS identity for hr_employee_id=11111111-1111-1111-1111-111111111111 count=0"
        if expected not in str(error):
            raise AssertionError(f"reverse check failed for an unexpected reason: {error}")
        print("[hr-identity-link] reverse check PASS: nonexistent HR id fails")
        return
    raise AssertionError("nonexistent HR id was accepted")


def run_reverse_test(
    member: WorkforceMember,
    identities: list[dict[str, str]],
    accounts: list[dict[str, str]],
    devices: list[dict[str, str]],
) -> None:
    validate_link([member.__dict__], identities, accounts, member.email, devices)
    invalid_member = WorkforceMember(
        id="11111111-1111-1111-1111-111111111111",
        email=member.email,
        display_name=member.display_name,
        worker_ref=member.worker_ref,
    )
    try:
        validate_link(
            [invalid_member.__dict__], identities, accounts, member.email, devices
        )
    except ValueError as error:
        expected = f"ISMS identity for hr_employee_id={invalid_member.id} count=0"
        if expected not in str(error):
            raise AssertionError(f"reverse check failed for an unexpected reason: {error}")
        print(f"[hr-identity-link] real-db reverse check PASS: {error}")
        return
    raise AssertionError("nonexistent HR id was accepted by the real-db check")


def preflight_projection(member: WorkforceMember, identities: list[dict[str, str]], accounts: list[dict[str, str]]) -> None:
    if len(accounts) != 1:
        raise ValueError(f"ISMS account count={len(accounts)} (expected 1)")
    by_hr = [row for row in identities if row.get("hr_employee_id") == member.id]
    by_email = [row for row in identities if str(row.get("email", "")).lower() == member.email.lower()]
    if len(by_hr) > 1:
        raise ValueError(f"multiple ISMS identities use hr_employee_id={member.id}")
    if by_hr and (by_hr[0].get("subject_type") != "employee" or str(by_hr[0].get("email", "")).lower() != member.email.lower()):
        raise ValueError("existing HR-linked identity conflicts with the backoffice person")
    if any(row.get("hr_employee_id") != member.id for row in by_email):
        raise ValueError("an existing ISMS identity uses the backoffice email with a different HR id")
    if accounts[0].get("identity_id") and (not by_hr or accounts[0].get("identity_id") != by_hr[0].get("id")):
        raise ValueError("the backoffice email account is already assigned to another ISMS identity")


def preflight_device(device: list[dict[str, str]], identities: list[dict[str, str]], member: WorkforceMember) -> None:
    if len(device) != 1:
        raise ValueError("ISMS device must resolve to exactly one agent device")
    if device[0].get("source") != "agent":
        raise ValueError("the assigned device must be an agent device")
    by_hr = [row for row in identities if row.get("hr_employee_id") == member.id]
    assigned = device[0].get("assigned_identity_id", "")
    if assigned and (not by_hr or assigned != by_hr[0].get("id")):
        raise ValueError("the assigned device is already linked to another ISMS identity")


def apply_projection(dsn: str, tenant_id: str, member: WorkforceMember, device_id: str) -> None:
    sql = f"""
SELECT app.project_hr_identity(
  {sql_literal(tenant_id)}::uuid,
  {sql_literal(member.email)},
  {sql_literal(member.display_name)},
  {sql_literal(member.id)},
  {sql_literal(device_id)}::uuid
);
"""
    psql(dsn, sql, read_only=False)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--reverse-test", action="store_true")
    parser.add_argument("--email", help="backoffice/ISMS person email")
    parser.add_argument("--tenant-id")
    parser.add_argument("--device-id", help="enrolled ISMS agent device UUID")
    parser.add_argument("--backoffice-db", default=os.environ.get("BACKOFFICE_DATABASE_URL", DEFAULT_BACKOFFICE_DB))
    parser.add_argument("--isms-db", default=os.environ.get("DATABASE_URL") or os.environ.get("ISMS_DB", "isms_dev"))
    parser.add_argument("--tenant-token", default=os.environ.get("ISMS_WEB_TENANT_TOKEN"),
                        help="tenant session token used for read-only ISMS verification")
    parser.add_argument("--provisioner-dsn", default=os.environ.get("ISMS_PROVISIONER_DATABASE_URL"),
                        help="provisioner connection used only for --apply")
    parser.add_argument("--apply", action="store_true", help="write only the ISMS projection")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        return 0
    if not args.email or not args.tenant_id:
        parser.error("--email and --tenant-id are required unless --self-test is used")
    if args.apply and not args.device_id:
        parser.error("--device-id is required with --apply")
    if args.apply and args.reverse_test:
        parser.error("--apply and --reverse-test cannot be used together")
    if not args.tenant_token:
        parser.error("--tenant-token or ISMS_WEB_TENANT_TOKEN is required for ISMS verification")
    if args.apply and not args.provisioner_dsn:
        parser.error("--provisioner-dsn or ISMS_PROVISIONER_DATABASE_URL is required with --apply")

    workforce = lookup_workforce_member(args.backoffice_db, args.email)
    if len(workforce) != 1:
        raise SystemExit(f"backoffice workforce member must resolve to exactly one row; got {len(workforce)}")
    member = workforce[0]
    identities, accounts = read_isms_state(args.isms_db, args.tenant_id, args.email, args.tenant_token)
    preflight_projection(member, identities, accounts)
    devices = (
        read_device_state(args.isms_db, args.tenant_id, args.device_id, args.tenant_token)
        if args.device_id else None
    )
    if args.reverse_test:
        if devices is None:
            raise SystemExit("--reverse-test requires --device-id")
        run_reverse_test(member, identities, accounts, devices)
        return 0
    if devices is not None:
        preflight_device(devices, identities, member)
    if not args.apply:
        print(f"[hr-identity-link] dry-run: backoffice workforce_member_id={member.id} worker_ref={member.worker_ref}")
        print(f"[hr-identity-link] dry-run: ISMS tenant={args.tenant_id} email={member.email} device={args.device_id or '(未指定)'} (no writes)")
        return 0

    apply_projection(args.provisioner_dsn, args.tenant_id, member, args.device_id)
    identities, accounts = read_isms_state(args.isms_db, args.tenant_id, args.email, args.tenant_token)
    devices = read_device_state(args.isms_db, args.tenant_id, args.device_id, args.tenant_token)
    validate_link([member.__dict__], identities, accounts, args.email, devices)
    print(f"[hr-identity-link] applied and verified: workforce_member_id={member.id} device_id={args.device_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
