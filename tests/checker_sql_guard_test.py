# -*- coding: utf-8 -*-
"""Checks on the shape of catalog SQL (rejected before the checker runs it).

catalog.checks query_sql / negative_fixture **come from the DB**.
Without fixing their shape before handing them to psql, one could append statements with `;`
to "swap what is counted" or "cause unexpected side effects".
This verifies that the guard actually works.
"""
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location('checker', os.path.join(ROOT, 'scripts', 'checker.py'))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

FAILED = []


def must_reject(name, sql, must=('select', 'with')):
    try:
        checker.assert_single_statement(sql, 'query_sql', 'TEST', must_start_with=must)
    except SystemExit:
        return
    FAILED.append(f'弾くべきものを通した: {name}')


def must_accept(name, sql, must=('select', 'with')):
    try:
        checker.assert_single_statement(sql, 'query_sql', 'TEST', must_start_with=must)
    except SystemExit as e:
        FAILED.append(f'通すべきものを弾いた: {name}（{e}）')


must_reject('複数文で数え直しを差し込む', "SELECT 1 WHERE false; SELECT 999")
must_reject('複数文で副作用を起こす', "SELECT 1; DROP TABLE app.policies")
must_reject('読み取り以外で始まる', "DELETE FROM app.policies")
must_reject('コメントで隠した継ぎ足し', "SELECT 1 /* x */ ; SELECT 2")
must_reject('空', "")
# Even a single statement, if it moves the transaction boundary, keeps the fixture from rolling back
must_reject('COMMIT でトランザクションを閉じる', "COMMIT", must=())
must_reject('ROLLBACK で閉じる', "ROLLBACK", must=())
must_reject('BEGIN で入れ子にする', "BEGIN", must=())
must_reject('SET で設定を変える', "SET row_security = off", must=())
must_reject('末尾セミコロン付きの COMMIT', "COMMIT;", must=())
must_reject('ABORT（ROLLBACK の別名）', "ABORT", must=())
must_reject('NOTIFY（トランザクション外へ漏れる）', "NOTIFY ch", must=())

must_accept('末尾のセミコロン', "SELECT 1;")
must_accept('文字列の中のセミコロン', "SELECT 'a;b' WHERE false")
must_accept('WITH で始まる', "WITH x AS (SELECT 1) SELECT * FROM x")
must_accept('行コメント内のセミコロン', "SELECT 1 -- ; これは文ではない\n")
must_accept('ドル引用符の中のセミコロン', "SELECT $$a;b$$ WHERE false")

# Only the marked count is picked up
ok, n, _ = checker.parse_count(f'{checker.COUNT_MARK}3')
if not ok or n != 3:
    FAILED.append('目印付きの件数を読めない')
ok, _, _ = checker.parse_count('999')
if ok:
    FAILED.append('目印の無い数値行を件数として拾ってしまう')
ok, _, _ = checker.parse_count(f'{checker.COUNT_MARK}1\n{checker.COUNT_MARK}2')
if ok:
    FAILED.append('目印付きが 2 行あるのに 1 つに決めてしまう')

if FAILED:
    for f in FAILED:
        print(f'  FAIL {f}')
    sys.exit(1)
print('  PASS カタログ SQL の形の検査')
