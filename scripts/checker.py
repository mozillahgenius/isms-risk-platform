# -*- coding: utf-8 -*-
"""標準チェックを実行する（checker）。

  python3 scripts/checker.py --token <セッショントークン> [--db isms_dev]
  python3 scripts/checker.py --token <...> --skip-verify   # 検証済みの結果を使わず実行だけ（既定は検証する）

## 何をするか

1. **検証フェーズ（隔離した DB で行う）**
   チェックごとに、
     a. 何もしない状態で query_sql を流し、違反が 0 件であること（＝前提が成立している）
     b. negative_fixture を流してから query_sql を流し、違反が出ること（＝検査が落ちる）
   の両方を確かめる。**a と b の両方が成り立って初めて「その検査は機能している」**と数える。
   b だけを見ると、元から落ちている検査を「機能している」と誤認する。

2. **実行フェーズ（対象の DB）**
   テナント文脈を確立し、**読み取り専用ロール（app_ro）**で query_sql を流して違反数を数える。
   カタログの SQL は書き換えられる余地があるので、書ける接続では実行しない。

3. **記録**
   app_rw で app.check_runs へ記録する。検証できていないチェックは pass にできない
   （migration 0021 の制約が拒否する）。ここは行儀ではなく DB が止める。

## fixture を対象 DB で流さない理由

negative_fixture は「わざと違反を作る」SQL。ロールバックする前提でも、対象の DB で
流せば、トリガ・監査ログ・連番など**巻き戻らない副作用**に触れる。
検証は使い捨ての DB を作ってそこで行い、対象の DB では読むだけにする。
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


# ---------------------------------------------------------------- psql の薄い包み

def psql(dsn: str, sql: str, *, tuples_only=True) -> tuple[int, str, str]:
    """SQL を流して (returncode, stdout, stderr) を返す。例外にしないのは、
    「落ちること」も検査の結果として扱いたいため。"""
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
    """ローカルの unix socket 前提。TCP で繋ぐ環境は ISMS_CHECKER_DSN_TEMPLATE で上書きする。"""
    tmpl = os.environ.get('ISMS_CHECKER_DSN_TEMPLATE')
    if tmpl:
        return tmpl.format(db=db, user=user)
    return f'postgres:///{db}?user={user}'


# ---------------------------------------------------------------- チェックの取得

def load_checks(db: str) -> list[dict]:
    """catalog.checks を読む。読み取りだけなので app_ro で足りる。"""
    out = psql_must(
        dsn_for(db, 'app_ro'),
        "SELECT json_agg(row_to_json(c) ORDER BY c.key) FROM ("
        "  SELECT key, title_ja, severity, query_sql, expect, negative_fixture,"
        "         coverage_required"
        "    FROM catalog.checks) c",
        'チェックの読み出し')
    return json.loads(out) if out and out != 'null' else []


def digest_of(db: str, key: str) -> str:
    """チェックの中身の指紋。**計算は DB の catalog.check_digest() に任せる。**

    ここで同じ式をもう一度書くと、いつか片方だけ変わる。
    ずれた側は「一致しない」ではなく「黙って通る」方向に倒れることがあるので、
    計算元は 1 つにする。記録時のトリガもこの関数を使って照合する（migration 0022）。
    """
    return psql_must(dsn_for(db, 'app_ro'),
                     f"SELECT catalog.check_digest({sql_literal(key)})",
                     f'{key} の指紋の取得')


# 文字列リテラルとコメントを落としてから構造を見るための下ごしらえ。
_STRIP = re.compile(
    r"'(?:[^']|'')*'"          # 単一引用符の文字列（'' のエスケープ込み）
    r"|\$\$.*?\$\$"            # ドル引用符（タグ無し）
    r"|\$[A-Za-z_][A-Za-z0-9_]*\$.*?\$[A-Za-z_][A-Za-z0-9_]*\$"  # タグ付き
    r'|"(?:[^"]|"")*"'         # 識別子の引用
    r'|--[^\n]*'               # 行コメント
    r'|/\*.*?\*/',             # ブロックコメント
    re.S,
)


# トランザクションの境界を動かす語。1 文であっても、これが本体だと
# 外側の BEGIN … ROLLBACK を壊せる（fixture が巻き戻らなくなる）。
# abort は rollback の別名。別名を落とすと拒否に穴があく。
_TX_WORDS = ('begin', 'commit', 'rollback', 'abort', 'start', 'savepoint', 'release',
             'end', 'prepare', 'set', 'reset', 'discard', 'listen', 'unlisten', 'notify')


def assert_single_statement(sql: str, kind: str, key: str, *, must_start_with: tuple[str, ...] = ()) -> None:
    """カタログの SQL が **1 文**であることを確かめる。

    query_sql / negative_fixture は DB から来る。そのまま psql へ渡すので、
    `;` で文を継ぎ足せると、数える対象を差し替えたり、想定外の副作用を起こしたりできる。
    実行ロールを絞っても「読める範囲を読む」「重い問い合わせで詰まらせる」は残るので、
    **形の側で 1 文に固定する**。
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
        # 読み取りだけ。app_ro で実行するが、形の側でも読み取りに固定する。
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


# ---------------------------------------------------------------- 違反数の数え方

# 件数を拾うための目印。カタログの SQL は 1 文に固定しているが、
# それでも「最後の数値行」を件数と決めつけない。目印付きの行だけを見る。
COUNT_MARK = '__ISMS_CHECK_COUNT__'


def parse_count(out: str) -> tuple[bool, int, str]:
    hits = [l.strip()[len(COUNT_MARK):] for l in out.splitlines()
            if l.strip().startswith(COUNT_MARK)]
    if len(hits) != 1 or not hits[0].isdigit():
        return False, -1, f'件数を読み取れませんでした（目印付きの行が {len(hits)} 件）'
    return True, int(hits[0]), ''


def count_violations(dsn: str, token: str, query_sql: str) -> tuple[bool, int, str]:
    """テナント文脈を確立して query_sql を流し、違反行数を返す。

    文脈は同一トランザクションでしか効かない（set_config の第3引数 true）ので、
    BEGIN → set_tenant_context → 数える、を 1 つの -c にまとめて渡す。
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


# ---------------------------------------------------------------- 検証フェーズ

def build_verify_db(db: str) -> tuple[str, str]:
    """使い捨ての検証用 DB を作り直し、テナントを 1 つ用意してトークンを返す。"""
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
    """適用済み migration の一覧と指紋。検証用 DB と対象 DB が同じ土台かを見る。

    検証はカタログの定義だけでなく、DDL・RLS・関数の上で成り立っている。
    対象 DB の migration が違えば、確かめたのは別の土台の上での話になる。
    """
    # public.schema_migrations は migrate.sh が管理する台帳で、app_ro には配っていない
    # （業務ロールが見るものではない）。検証フェーズはそもそも createdb / dropdb ができる
    # 権限で動くので、ここは既定の接続で読む。
    # 対象がリモートのときに、同名のローカル DB を指紋化してしまわないよう、
    # 接続の作り方は他と同じ経路（DSN テンプレート）を通す。
    # ここは業務ロールでは読めない台帳なので、テンプレートの {user} には admin を渡す。
    admin_user = os.environ.get('ISMS_CHECKER_ADMIN_USER', '')
    tmpl = os.environ.get('ISMS_CHECKER_ADMIN_DSN_TEMPLATE')
    if tmpl:
        # {user} を書いていても書いていなくても通るように、両方渡す。
        dsn = tmpl.format(db=db, user=admin_user)
    elif admin_user:
        dsn = dsn_for(db, admin_user)
    elif os.environ.get('ISMS_CHECKER_DSN_TEMPLATE'):
        # 接続の作り方が上書きされているのに管理者の指定が無い。
        # ローカルの同名 DB を見に行くと別物を指紋化するので、読めなかった扱いにする。
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
    """(検証できたか, 理由) を返す。

    前提（違反 0 件）と、fixture 後に違反が出ることの両方を見る。
    """
    ok, before, err = count_violations(dsn_for(db, 'app_ro'), token, check['query_sql'])
    if not ok:
        return False, f'query_sql が実行できません: {err.splitlines()[0] if err else ""}'
    if before != 0:
        return False, f'fixture を入れる前から違反が {before} 件ある（この検査は元から落ちている）'

    # fixture と query_sql を同じトランザクションで流し、必ず巻き戻す。
    # 別セッションだと未コミットの fixture が見えないため、ここだけ app_rw で読む。
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


# ---------------------------------------------------------------- 記録

def record(db: str, token: str, receipt_id: str, check: dict, result: str, violations: int,
           verified: bool, digest: str | None, error_detail: str | None) -> None:
    # coverage_ratio は「見られた母集団の割合」。この core チェックは対象の表を丸ごと
    # 走査するので、問い合わせが通った時点で 1.000。通らなかった（error）ときは
    # 測れていないので NULL のままにする（0 と書くと「見たが 0%」に読める）。
    #
    # 'inconclusive' は coverage_ratio が必須（0008 の制約）。合否を決められない理由は
    # 母集団の不足とは限らず、ここでは「落ちることを確かめていない」ことなので、
    # 理由は error_detail に書き、coverage は実際に見た範囲を書く。
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
    """失敗を finding にし、復旧時は retest_passed へ進める。

    `closed` へは進めない。人の確認を要するワークフローを DB の状態遷移で
    保ち、同じ検査を繰り返しても同一の未解決 finding を増殖させない。
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


# ---------------------------------------------------------------- 本体

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

    # 検証用 DB は毎回 dropdb して作り直す。対象と同じ名前だと対象を消す。
    if args.verify_db == args.db:
        print(f'[checker] 検証用 DB と対象 DB が同じです（{args.db}）。'
              '検証用 DB は作り直すので、別の名前にしてください', file=sys.stderr)
        return 2

    checks = load_checks(args.db)
    # カタログの SQL は DB から来る。実行する前に形を確かめる（1 文であること等）。
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
        # 土台が同じか。違えば、確かめたのは別の DB の上での話になる。
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
            # 落ちることを確かめられていない検査は「合格」と言えない。
            # DB の制約でも止まるが、ここで先に正しい結果にしておく。
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
