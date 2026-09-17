# -*- coding: utf-8 -*-
"""Phase 0 の入力 fixture を作る。

**build_risk_map.py は使わない。** 生成器と検証器が同じコードだと、
往復で確かめられるのは自己整合性だけで、相互運用性の検証にならない。
ここは openpyxl で直接書き、実テンプレートと同じ 4 シート構成・
実テンプレート側の列名（BigCategory / MidCategory / SmallFrame / ActionPlan）にする。

データは顧客の実データを使わない。ここに書いてあるものが全て。

  python3 phase0/make_fixture.py <出力.xlsx>
"""
from __future__ import annotations

import sys

import openpyxl

TEMPLATE_HEADERS = ['RiskItem', 'BigCategory', 'MidCategory', 'SmallFrame', 'Summary',
                    'ProbBefore', 'ImpactBefore', 'ActionPlan', 'ProbAfter', 'ImpactAfter']

# 意図的に含めたもの:
#   - 3 つの観点フレーム全て
#   - 前後に空白を含む値（正規化で消えること）
#   - 全角空白・NBSP を含む値
#   - 改行を含む対応策
#   - 同じ施策に複数のリスクがぶら下がる行（クロス集計の連結を通す）
ROWS = [
    ['経理・税務（Phase1）', 'クラウド会計ソフト活用', '仕訳入力・チェック', 'スピード',
     '操作ミスで誤ったデータ入力により月次損益が不正確になる',
     3, 4, '週次で簡易レビューと自動仕訳機能の活用', 2, 2],
    ['経理・税務（Phase1）', 'クラウド会計ソフト活用', '仕訳入力・チェック', '精度',
     '勘定科目の付け方が担当者ごとに揺れ、期間比較ができなくなる',
     4, 3, '科目定義書の整備と\n四半期ごとの棚卸', 2, 3],
    ['経理・税務（Phase1）', 'キャッシュフローの監視', '日次残高チェック', '管理可能性',
     '  残高把握の遅れで資金ショートを検知できない  ',
     2, 5, '自動リマインダを設定して日次レビュー実施', 1, 5],
    ['法務（Phase3）', '契約書の標準化', '契約テンプレート管理', '精度',
     'テンプレート未更新で最新法令を反映できず契約無効や紛争のリスク',
     3, 4, '法令チェックリスト作成と年次改訂プロセス、法務レビュー必須化', 1, 2],
    ['人事・労務（Phase1）', '入退社手続きの整備', '権限付与・剥奪フロー', '管理可能性',
     '退職者のアカウントが残存し、情報資産へ到達できる状態が続く',
     4, 5, '入退社チェックリストと月次のアカウント棚卸', 2, 4],
    ['情報システム（Phase2）', '端末管理の強化', '端末ポスチャの可視化', 'スピード',
     '暗号化未設定の端末を把握できず、紛失時の影響を評価できない',
     3, 5, 'エージェント配布と未達一覧の月次確認', 2, 3],
]

MASTER_HEADERS = ['RiskItem', 'Big', 'Mid', 'Frame', 'Summary', 'Action']
MASTER_ROWS = [
    ['経理・税務（Phase1）', 'クラウド会計ソフト活用', '仕訳入力・チェック', 'スピード',
     '操作ミスで誤ったデータ入力により月次損益が不正確になる',
     '週次で簡易レビューと自動仕訳機能の活用'],
    ['法務（Phase3）', '契約書の標準化', '契約テンプレート管理', '精度',
     'テンプレート未更新で最新法令を反映できず契約無効や紛争のリスク',
     '法令チェックリスト作成と年次改訂プロセス'],
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

    # AUTO 2 シートは「入力側にも存在する派生物」として器だけ置く。
    # 往復の比較対象にはしない（規則は NORMALIZATION.md の「対象外」）。
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
