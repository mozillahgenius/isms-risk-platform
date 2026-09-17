# -*- coding: utf-8 -*-
"""カタログの SQL の形の検査（checker が実行する前に弾く）。

catalog.checks の query_sql / negative_fixture は **DB から来る**。
psql へ渡す前に形を固定していないと、`;` で文を継ぎ足して
「数える対象を差し替える」「想定外の副作用を起こす」ができる。
ここはその番人が実際に働くことを確かめる。
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
# 1 文であっても、トランザクションの境界を動かされると fixture が巻き戻らなくなる
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

# 目印付きの件数だけを拾うこと
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
