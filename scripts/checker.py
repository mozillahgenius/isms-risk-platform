# -*- coding: utf-8 -*-
"""Run the standard checks (checker).

  python3 scripts/checker.py --token <session token> [--db isms_dev]
  python3 scripts/checker.py --token <...> --skip-verify   # run only, without verified results (verification is the default)

## What it does

1. **Verification phase (in an isolated DB)**
   For each check, confirm both that
     a. running query_sql with nothing done yields 0 violations (= the precondition holds), and
     b. running negative_fixture and then query_sql yields violations (= the check fails).
   **Only when both a and b hold do we count "the check works".**
   Looking at b alone mistakes a check that was already failing for a working one.

2. **Execution phase (the target DB)**
   Establish the tenant context and run query_sql with the **read-only role (app_ro)** to count violations.
   Catalog SQL can be tampered with, so never run it over a connection that can write.

3. **Recording**
   Record into app.check_runs as app_rw. A check that has not been verified cannot be recorded as pass
   (the constraint in migration 0021 rejects it). This is enforced by the DB, not by convention.

## Why fixtures are not run on the target DB

negative_fixture is SQL that "deliberately creates a violation". Even if rolled back, running it on
the target DB touches **side effects that do not roll back** — triggers, audit logs, sequences.
Verification happens in a throwaway DB; the target DB is only read.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ---------------------------------------------------------------- thin psql wrapper

def psql(dsn: str, sql: str, *, tuples_only=True) -> tuple[int, str, str]:
    """Run SQL and return (returncode, stdout, stderr). It does not raise because
    "failing" is also a result we want to treat as a check outcome."""
    args = ['psql', '-v', 'ON_ERROR_STOP=1', '-q', '-d', dsn, '-c', sql]
    if tuples_only:
        args[1:1] = ['-At']
    p = subprocess.run(args, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def psql_must(dsn: str, sql: str, what: str) -> str:
    rc, out, err = psql(dsn, sql)
    if rc != 0:
        raise SystemExit(f'[checker] {what} が失敗しました:\n{err}')
    return out


def sql_literal(v: str) -> str:
    return "'" + v.replace("'", "''") + "'"


def dsn_for(db: str, user: str) -> str:
    """Assumes a local unix socket. Environments connecting over TCP override this with ISMS_CHECKER_DSN_TEMPLATE."""
    tmpl = os.environ.get('ISMS_CHECKER_DSN_TEMPLATE')
    if tmpl:
        return tmpl.format(db=db, user=user)
    return f'postgres:///{db}?user={user}'


# ---------------------------------------------------------------- loading checks

def load_checks(db: str) -> list[dict]:
    """Read catalog.checks. Read-only, so app_ro is enough."""
    out = psql_must(
        dsn_for(db, 'app_ro'),
        "SELECT json_agg(row_to_json(c) ORDER BY c.key) FROM ("
        "  SELECT key, title_ja, severity, query_sql, expect, negative_fixture,"
        "         coverage_required"
        "    FROM catalog.checks) c",
        'チェックの読み出し')
    return json.loads(out) if out and out != 'null' else []


def digest_of(db: str, key: str) -> str:
    """Fingerprint of a check's content. **The computation is left to catalog.check_digest() in the DB.**

    Writing the same formula again here means one copy will eventually change on its own.
    A drifted copy can fail toward "silently passes" rather than "does not match",
    so there is a single source of the computation. The recording trigger also uses this function (migration 0022).
    """
    return psql_must(dsn_for(db, 'app_ro'),
                     f"SELECT catalog.check_digest({sql_literal(key)})",
                     f'{key} の指紋の取得')


# Preparation for inspecting structure after stripping string literals and comments.
_STRIP = re.compile(
    r"'(?:[^']|'')*'"          # single-quoted string (including '' escapes)
    r"|\$\$.*?\$\$"            # dollar quoting (untagged)
    r"|\$[A-Za-z_][A-Za-z0-9_]*\$.*?\$[A-Za-z_][A-Za-z0-9_]*\$"  # tagged
    r'|"(?:[^"]|"")*"'         # quoted identifier
    r'|--[^\n]*'               # line comment
    r'|/\*.*?\*/',             # block comment
    re.S,
)


# Words that move transaction boundaries. Even as a single statement, if one of these is the body
# it can break the outer BEGIN … ROLLBACK (the fixture would no longer roll back).
# abort is an alias of rollback. Omitting aliases leaves a hole in the rejection.
_TX_WORDS = ('begin', 'commit', 'rollback', 'abort', 'start', 'savepoint', 'release',
             'end', 'prepare', 'set', 'reset', 'discard', 'listen', 'unlisten', 'notify')


def assert_single_statement(sql: str, kind: str, key: str, *, must_start_with: tuple[str, ...] = ()) -> None:
    """Confirm that catalog SQL is **a single statement**.

    query_sql / negative_fixture come from the DB and are passed to psql as-is, so if statements
    can be appended with `;`, one could swap what is counted or cause unexpected side effects.
    Restricting the executing role still leaves "read whatever is readable" and "clog it with heavy queries",
    so **the shape itself is pinned to a single statement**.
    """
    bare = _STRIP.sub(' ', sql)
    if ';' in bare.rstrip().rstrip(';'):
        raise SystemExit(f'[checker] {key}: {kind} に複数の文が含まれています（1 文だけにしてください）')
    head = bare.lstrip().split(None, 1)[0].lower().rstrip(';') if bare.strip() else ''
    if head in _TX_WORDS:
        raise SystemExit(
            f'[checker] {key}: {kind} がトランザクションの境界を動かそうとしています（{head}）')
    if must_start_with and head not in must_start_with:
        raise SystemExit(
            f'[checker] {key}: {kind} は {" / ".join(must_start_with)} で始まる 1 文にしてください（実際: {head!r}）')


def validate_checks(checks: list[dict]) -> None:
    for c in checks:
        # Read-only. It runs as app_ro, but the shape is also pinned to a read.
        assert_single_statement(c['query_sql'], 'query_sql', c['key'],
                                must_start_with=('select', 'with'))
        assert_single_statement(c['negative_fixture'], 'negative_fixture', c['key'])


def max_violations(check: dict) -> int:
    expect = check.get('expect') or {}
    if isinstance(expect, str):
        expect = json.loads(expect)
    v = expect.get('max_violations', 0)
    if not isinstance(v, int) or v < 0:
        raise SystemExit(f"[checker] {check['key']}: expect.max_violations が整数ではありません: {v!r}")
    return v


# ---------------------------------------------------------------- counting violations

# Marker for picking up the count. Catalog SQL is pinned to a single statement, but even so
# we do not assume "the last numeric line" is the count. Only marked lines are looked at.
COUNT_MARK = '__ISMS_CHECK_COUNT__'


def parse_count(out: str) -> tuple[bool, int, str]:
    hits = [l.strip()[len(COUNT_MARK):] for l in out.splitlines()
            if l.strip().startswith(COUNT_MARK)]
    if len(hits) != 1 or not hits[0].isdigit():
        return False, -1, f'件数を読み取れませんでした（目印付きの行が {len(hits)} 件）'
    return True, int(hits[0]), ''


def count_violations(dsn: str, token: str, query_sql: str) -> tuple[bool, int, str]:
    """Establish the tenant context, run query_sql, and return the number of violating rows.

    The context only applies within the same transaction (third argument of set_config is true),
    so BEGIN → set_tenant_context → count are passed together in a single -c.
    """
    sql = (
        "BEGIN;"
        f"SELECT app.set_tenant_context({sql_literal(token)});"
        f"SELECT '{COUNT_MARK}'||count(*) FROM ({query_sql}) AS v;"
        "COMMIT;"
    )
    rc, out, err = psql(dsn, sql)
    if rc != 0:
        return False, -1, err
    return parse_count(out)


# ---------------------------------------------------------------- verification phase

def build_verify_db(db: str) -> tuple[str, str]:
    """Recreate the throwaway verification DB, set up one tenant, and return its token."""
    subprocess.run(['dropdb', '--if-exists', db], check=True)
    subprocess.run(['createdb', db], check=True)
    env = dict(os.environ, ISMS_DB=db)
    env.pop('DATABASE_URL', None)
    r = subprocess.run([os.path.join(ROOT, 'scripts', 'migrate.sh'), 'up'],
                       capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise SystemExit(f'[checker] 検証用 DB の migration が失敗:\n{r.stderr}')
    for seed in ('0001_dom_2026_1.sql', '0002_checks_core.sql', '0004_phase2_checks.sql',
                 '0006_phase3_device_checks.sql'):
        rr = subprocess.run(['psql', '-v', 'ON_ERROR_STOP=1', '-q', '-d', db,
                             '-f', os.path.join(ROOT, 'db', 'seeds', seed)],
                            capture_output=True, text=True)
        if rr.returncode != 0:
            raise SystemExit(f'[checker] 検証用 DB の seed {seed} が失敗:\n{rr.stderr}')
    rr = subprocess.run(['python3', os.path.join(ROOT, 'db', 'seeds', '0003_connectors.py')],
                        capture_output=True, text=True,
                        env=dict(os.environ, ISMS_DB=db))
    if rr.returncode != 0:
        raise SystemExit(f'[checker] 検証用 DB の connector seed が失敗:\n{rr.stderr}')
    rr = subprocess.run(['python3', os.path.join(ROOT, 'db', 'seeds', '0005_agent_definition.py')],
                        capture_output=True, text=True,
                        env=dict(os.environ, ISMS_DB=db))
    if rr.returncode != 0:
        raise SystemExit(f'[checker] 検証用 DB の agent definition seed が失敗:\n{rr.stderr}')

    ids = psql_must(
        dsn_for(db, 'provisioner'),
        "SELECT tenant_id||' '||user_id FROM app.provision_tenant("
        "'検証用','verify.invalid','verify@verify.invalid','検証用')",
        '検証用テナントの作成')
    tenant_id, user_id = ids.split()
    token = secrets.token_urlsafe(48)
    psql_must(
        dsn_for(db, 'auth_svc'),
        f"SELECT app.create_session('{tenant_id}'::uuid, '{user_id}'::uuid, {sql_literal(token)})",
        '検証用セッションの発行')
    return token, tenant_id


def schema_fingerprint(db: str) -> str:
    """Fingerprint of the list of applied migrations. Tells whether the verification DB and target DB share the same base.

    Verification rests not only on the catalog definitions but on the DDL, RLS and functions.
    If the target DB's migrations differ, what was verified was on a different base.
    """
    # public.schema_migrations is the ledger managed by migrate.sh and is not granted to app_ro
    # (business roles are not meant to see it). The verification phase already runs with privileges
    # that can createdb / dropdb, so it is read over the default connection here.
    # So that a same-named local DB is not fingerprinted when the target is remote,
    # the connection is built through the same path as elsewhere (the DSN template).
    # This ledger cannot be read by business roles, so admin is passed as the template's {user}.
    admin_user = os.environ.get('ISMS_CHECKER_ADMIN_USER', '')
    tmpl = os.environ.get('ISMS_CHECKER_ADMIN_DSN_TEMPLATE')
    if tmpl:
        # Pass both so it works whether or not the template contains {user}.
        dsn = tmpl.format(db=db, user=admin_user)
    elif admin_user:
        dsn = dsn_for(db, admin_user)
    elif os.environ.get('ISMS_CHECKER_DSN_TEMPLATE'):
        # The connection template is overridden but no admin is specified.
        # Looking at a same-named local DB would fingerprint something else, so treat it as unreadable.
        return ''
    else:
        dsn = db
    rc, out, err = psql(dsn, "SELECT coalesce(md5(string_agg("
                            "version||':'||coalesce(checksum,''), ',' ORDER BY version)), '')"
                            "  FROM public.schema_migrations")
    if rc != 0:
        return ''
    return out.strip()


def verify_check(db: str, token: str, check: dict) -> tuple[bool, str]:
    """Return (verified?, reason).

    Checks both the precondition (0 violations) and that violations appear after the fixture.
    """
    ok, before, err = count_violations(dsn_for(db, 'app_ro'), token, check['query_sql'])
    if not ok:
        return False, f'query_sql が実行できません: {err.splitlines()[0] if err else ""}'
    if before != 0:
        return False, f'fixture を入れる前から違反が {before} 件ある（この検査は元から落ちている）'

    # Run the fixture and query_sql in the same transaction and always roll back.
    # A separate session cannot see the uncommitted fixture, so only this read uses app_rw.
    sql = (
        "BEGIN;"
        f"SELECT app.set_tenant_context({sql_literal(token)});"
        f"{check['negative_fixture']};"
        f"SELECT '{COUNT_MARK}'||count(*) FROM ({check['query_sql']}) AS v;"
        "ROLLBACK;"
    )
    rc, out, err = psql(dsn_for(db, 'app_rw'), sql)
    if rc != 0:
        return False, f'negative_fixture が流せません: {err.splitlines()[0] if err else ""}'
    okc, after, perr = parse_count(out)
    if not okc:
        return False, perr
    if after <= 0:
        return False, 'fixture を入れても違反が出ない（検査が働いていない）'
    return True, f'0 件 → {after} 件'


# ---------------------------------------------------------------- recording

def record(db: str, token: str, receipt_id: str, check: dict, result: str, violations: int,
           verified: bool, digest: str | None, error_detail: str | None) -> None:
    # coverage_ratio is "the fraction of the population that was seen". These core checks scan the
    # whole target table, so it is 1.000 once the query succeeds. When it did not succeed (error),
    # nothing was measured, so it stays NULL (writing 0 would read as "looked, 0%").
    #
    # 'inconclusive' requires coverage_ratio (constraint in 0008). The reason pass/fail cannot be decided
    # is not necessarily an insufficient population; here it is "failing was not confirmed",
    # so the reason goes in error_detail and coverage records the range actually seen.
    measured = violations >= 0
    cols = (
        "INSERT INTO app.check_runs "
        "(tenant_id, check_key, started_at, finished_at, result, row_count,"
        " coverage_ratio, threshold_used, negative_verified, verified_digest, error_detail, verification_receipt_id) "
        "SELECT app.current_tenant(), {key}, now(), now(), {result}, {rows},"
        " {coverage}, {threshold}, {verified}, {digest}, {err}, {receipt}::uuid"
    ).format(
        key=sql_literal(check['key']),
        result=sql_literal(result),
        rows='NULL' if not measured else str(violations),
        coverage=('0.000' if result == 'inconclusive'
                  else ('1.000' if measured else 'NULL')),
        threshold=str(check.get('coverage_required') or '1.00'),
        verified='true' if verified else 'false',
        digest=sql_literal(digest) if digest else 'NULL',
        err=sql_literal(error_detail) if error_detail else 'NULL',
        receipt=sql_literal(receipt_id),
    )
    sql = (
        "BEGIN;"
        f"SELECT app.set_tenant_context({sql_literal(token)});"
        f"{cols};"
        "COMMIT;"
    )
    rc, _, err = psql(dsn_for(db, 'app_rw'), sql)
    if rc != 0:
        raise SystemExit(f"[checker] {check['key']} の記録が失敗しました:\n{err}")


def sync_finding(db: str, token: str, check: dict, result: str, violations: int) -> None:
    """Turn a failure into a finding, and advance it to retest_passed on recovery.

    It never advances to `closed`. The workflow requiring human confirmation is kept in the DB's
    state transitions, and repeating the same check does not multiply the same open finding.
    """
    if result not in ('fail', 'pass'):
        return
    title = check.get('title_ja') or check['key']
    detail = f"{check['key']}: 違反 {violations} 件"
    if result == 'fail':
        sql = (
            "BEGIN;SELECT app.set_tenant_context(" + sql_literal(token) + ");"
            "WITH latest AS (SELECT id FROM app.check_runs WHERE tenant_id=app.current_tenant() "
            "AND check_key=" + sql_literal(check['key']) + " ORDER BY started_at DESC LIMIT 1), "
            "reopened AS (UPDATE app.findings SET status='detected',check_run_id=(SELECT id FROM latest),"
            "detail=" + sql_literal(detail) + ",updated_at=now() WHERE tenant_id=app.current_tenant() "
            "AND check_key=" + sql_literal(check['key']) + " AND status='retest_passed' RETURNING id) "
            "INSERT INTO app.findings (tenant_id,source,check_key,check_run_id,title,detail,severity,status,assigned_to) "
            "SELECT app.current_tenant(),'check'," + sql_literal(check['key']) + ",(SELECT id FROM latest)," +
            sql_literal(title) + "," + sql_literal(detail) + "," + sql_literal(check['severity']) + ",'detected',"
            "(SELECT m.user_id FROM app.memberships m WHERE m.tenant_id=app.current_tenant() "
            "AND m.role_key IN ('secretariat','ciso') AND m.revoked_at IS NULL "
            "ORDER BY CASE m.role_key WHEN 'secretariat' THEN 0 ELSE 1 END LIMIT 1) "
            "WHERE NOT EXISTS (SELECT 1 FROM app.findings f WHERE f.tenant_id=app.current_tenant() "
            "AND f.check_key=" + sql_literal(check['key']) + " AND f.status IN "
            "('detected','in_remediation','remediated','exception','risk_accepted'));COMMIT;"
        )
    else:
        sql = (
            "BEGIN;SELECT app.set_tenant_context(" + sql_literal(token) + ");"
            "UPDATE app.findings SET status='retest_passed',updated_at=now() WHERE tenant_id=app.current_tenant() "
            "AND check_key=" + sql_literal(check['key']) + " AND status IN ('detected','in_remediation','remediated');COMMIT;"
        )
    rc, _, err = psql(dsn_for(db, 'app_rw'), sql)
    if rc != 0:
        raise SystemExit(f"[checker] {check['key']} の finding 更新が失敗しました:\n{err}")


# ---------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--token', default=os.environ.get('ISMS_CHECKER_TOKEN'),
                    help='対象テナントのセッショントークン')
    ap.add_argument('--verification-receipt-id', default=os.environ.get('ISMS_VERIFICATION_RECEIPT_ID'),
                    help='⑦のPOST受付で返された実行許可ID（必須）')
    ap.add_argument('--db', default=os.environ.get('ISMS_DB', 'isms_dev'))
    ap.add_argument('--verify-db', default=os.environ.get('ISMS_CHECKER_VERIFY_DB', 'isms_checker_verify'))
    ap.add_argument('--skip-verify', action='store_true',
                    help='検証フェーズを飛ばす。飛ばした実行は pass として記録できない')
    ap.add_argument('--only', action='append', default=[],
                    help='指定したチェックキーだけを実行する（複数回指定可）')
    args = ap.parse_args()

    if not args.token:
        print('[checker] --token（または ISMS_CHECKER_TOKEN）が要ります', file=sys.stderr)
        return 2
    try:
        receipt_id = str(uuid.UUID(args.verification_receipt_id))
    except (AttributeError, ValueError, TypeError):
        print('[checker] --verification-receipt-id（または ISMS_VERIFICATION_RECEIPT_ID）が要ります',
              file=sys.stderr)
        return 2

    # The verification DB is dropped and recreated every time. If it has the same name as the target, the target gets deleted.
    if args.verify_db == args.db:
        print(f'[checker] 検証用 DB と対象 DB が同じです（{args.db}）。'
              '検証用 DB は作り直すので、別の名前にしてください', file=sys.stderr)
        return 2

    checks = load_checks(args.db)
    # Catalog SQL comes from the DB. Check its shape before running it (single statement, etc.).
    validate_checks(checks)
    if not checks:
        print('[checker] catalog.checks が空です。db/seeds/0002_checks_core.sql を流してください', file=sys.stderr)
        return 1
    if args.only:
        requested = set(args.only)
        known = {c['key'] for c in checks}
        unknown = sorted(requested - known)
        if unknown:
            print('[checker] 未知のチェックキー: ' + ', '.join(unknown), file=sys.stderr)
            return 2
        checks = [c for c in checks if c['key'] in requested]

    verified: dict[str, str] = {}
    if args.skip_verify:
        print('[checker] 検証フェーズを飛ばしました。この実行の結果は pass にできません')
    else:
        print(f'[checker] 検証フェーズ（使い捨て DB: {args.verify_db}）')
        vtoken, _ = build_verify_db(args.verify_db)
        vchecks = load_checks(args.verify_db)
        validate_checks(vchecks)
        by_key = {c['key']: c for c in vchecks}
        # Is the base the same? If not, what was verified was on a different DB.
        target_fp = schema_fingerprint(args.db)
        verify_fp = schema_fingerprint(args.verify_db)
        if not target_fp or not verify_fp:
            print('  ! 適用済み migration の一覧を読めませんでした。'
                  '土台が同じか確かめられないので検証は行いません')
            by_key = {}
        elif target_fp != verify_fp:
            print('  ! 対象 DB と検証用 DB で適用済み migration が違います。'
                  '検証は行いません（対象 DB を最新にしてから実行してください）')
            by_key = {}
        for c in checks:
            target = by_key.get(c['key'])
            if target is None or digest_of(args.verify_db, c['key']) != digest_of(args.db, c['key']):
                print(f"  - {c['key']}: 検証用 DB の定義と一致しません（検証しない）")
                continue
            ok, why = verify_check(args.verify_db, vtoken, target)
            mark = '確認' if ok else '未確認'
            print(f"  - {c['key']}: {mark}（{why}）")
            if ok:
                verified[c['key']] = digest_of(args.db, c['key'])
        subprocess.run(['dropdb', '--if-exists', args.verify_db], check=False)

    print(f'[checker] 実行フェーズ（対象 DB: {args.db}）')
    failed = 0
    for c in checks:
        ok, violations, err = count_violations(dsn_for(args.db, 'app_ro'), args.token, c['query_sql'])
        digest = verified.get(c['key'])
        if not ok:
            record(args.db, args.token, receipt_id, c, 'error', -1, False, None, err[:1000])
            print(f"  - {c['key']}: error（{err.splitlines()[0] if err else ''}）")
            failed += 1
            continue
        limit = max_violations(c)
        if violations > limit:
            result = 'fail'
        elif digest is None:
            # A check whose failure has not been confirmed cannot be called "passed".
            # The DB constraint would also stop it, but set the correct result here first.
            result = 'inconclusive'
        else:
            result = 'pass'
        detail = None if digest else '逆向き検証（落ちることの確認）が済んでいない'
        record(args.db, args.token, receipt_id, c, result, violations,
               digest is not None, digest,
               detail if result != 'fail' else None)
        sync_finding(args.db, args.token, c, result, violations)
        print(f"  - {c['key']}: {result}（違反 {violations} / 許容 {limit}）")
        if result != 'pass':
            failed += 1

    print(f'[checker] {len(checks) - failed} / {len(checks)} 本が pass')
    return 0 if failed == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
