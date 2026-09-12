# -*- coding: utf-8 -*-
"""Build the Phase 0 input fixture.

**Does not use build_risk_map.py.** If the generator and the verifier share code,
a round trip only confirms self-consistency, not interoperability.
This writes directly with openpyxl, using the same 4-sheet layout as the real template and
the real template's column names (BigCategory / MidCategory / SmallFrame / ActionPlan).

No real customer data is used. What is written here is everything.

  python3 phase0/make_fixture.py <output.xlsx>
"""
from __future__ import annotations

import sys

import openpyxl

TEMPLATE_HEADERS = ['RiskItem', 'BigCategory', 'MidCategory', 'SmallFrame', 'Summary',
                    'ProbBefore', 'ImpactBefore', 'ActionPlan', 'ProbAfter', 'ImpactAfter']

# Deliberately included:
#   - all 3 perspective frames
#   - values with leading/trailing whitespace (should be removed by normalization)
#   - values containing full-width spaces and NBSP
#   - action plans containing line breaks
#   - rows where multiple risks hang off the same measure (exercises the cross-tab join)
#   - departments, themes, and measures use fictional sample names (no values from real registers/catalogs)
ROWS = [
    ['サンプル部門D（Phase1）', 'サンプルテーマD2', 'サンプル施策D2', 'スピード',
     '手作業の転記で誤りが入り、集計が遅れる',
     3, 4, '転記を自動化し、週次で差分を確かめる', 2, 2],
    ['サンプル部門D（Phase1）', 'サンプルテーマD2', 'サンプル施策D2', '精度',
     '分類の付け方が担当者ごとに違い、比較ができない',
     4, 3, '分類ルールを文書にし\n四半期ごとに見直す', 2, 3],
    ['サンプル部門D（Phase1）', 'サンプルテーマD1', 'サンプル施策D1', '管理可能性',
     '  共有フォルダの権限を把握できていない  ',
     2, 5, '共有設定を月次で一覧にして確かめる', 1, 5],
    ['サンプル部門C（Phase3）', 'サンプルテーマC', 'サンプル施策C', '精度',
     '古い雛形が使われ、記載が現状と合わない',
     3, 4, '雛形に改訂日を付け、年次で見直す', 1, 2],
    ['サンプル部門A（Phase1）', 'サンプルテーマA', 'サンプル施策A', '管理可能性',
     '退職者のアカウントが残り、社内データへ到達できる',
     4, 5, '退職時のチェックリストと月次のアカウント棚卸', 2, 4],
    ['サンプル部門B（Phase2）', 'サンプルテーマB', 'サンプル施策B', 'スピード',
     '暗号化されていない端末を把握できない',
     3, 5, '端末の状態を集め、未対応を月次で確かめる', 2, 3],
]

MASTER_HEADERS = ['RiskItem', 'Big', 'Mid', 'Frame', 'Summary', 'Action']
MASTER_ROWS = [
    ['サンプル部門D（Phase1）', 'サンプルテーマD2', 'サンプル施策D2', 'スピード',
     '手作業の転記で誤りが入り、集計が遅れる',
     '転記を自動化し、週次で差分を確かめる'],
    ['サンプル部門C（Phase3）', 'サンプルテーマC', 'サンプル施策C', '精度',
     '古い雛形が使われ、記載が現状と合わない',
     '雛形に改訂日を付け、年次で見直す'],
]


def main():
    if len(sys.argv) < 2:
        raise SystemExit('使い方: make_fixture.py <出力.xlsx>')
    out = sys.argv[1]
    wb = openpyxl.Workbook()

    ws = wb.active
    ws.title = 'カルテ_リスクマップ'
    ws.append(TEMPLATE_HEADERS)
    for r in ROWS:
        ws.append(r)

    # The 2 AUTO sheets are placed as empty shells, as "derivatives that also exist on the input side".
    # They are not part of the round-trip comparison (rule: "out of scope" in NORMALIZATION.md).
    wb.create_sheet('リスクマップ_AUTO').append(['この入力では未生成'])
    wb.create_sheet('ヒートマップ_AUTO').append(['この入力では未生成'])

    ms = wb.create_sheet('リスクマップマスタ')
    ms.append(MASTER_HEADERS)
    for r in MASTER_ROWS:
        ms.append(r)

    wb.save(out)
    print(f'生成: {out}（カルテ {len(ROWS)} 行 / マスタ {len(MASTER_ROWS)} 行）')


if __name__ == '__main__':
    main()
