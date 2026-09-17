# -*- coding: utf-8 -*-
"""2 つの xlsx のカルテ_リスクマップ を正規化して比較する。

  python3 phase0/diff_xlsx.py 入力.xlsx 出力.xlsx

差分が 1 件でもあれば exit 1。0 件なら exit 0 とダイジェストを表示する。
比較の規則は phase0/NORMALIZATION.md（norm/v1）。
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import karte  # noqa: E402


def main():
    if len(sys.argv) < 3:
        raise SystemExit('使い方: diff_xlsx.py 入力.xlsx 出力.xlsx')
    left, right = sys.argv[1], sys.argv[2]

    lrows = karte.read_karte(left)
    rrows = karte.read_karte(right)
    diffs = karte.compare(lrows, rrows)

    print(f'規則: {karte.NORM_VERSION}')
    print(f'入力: {left}  {len(lrows)} 行  {karte.digest(lrows)}')
    print(f'出力: {right}  {len(rrows)} 行  {karte.digest(rrows)}')

    if not diffs:
        print('差分: 0 件')
        return 0

    print(f'差分: {len(diffs)} 件')
    for kind, key, a, b in diffs[:50]:
        print(f'  - {kind}  key={key}')
        if a is not None or b is not None:
            print(f'      入力: {a!r}')
            print(f'      出力: {b!r}')
    if len(diffs) > 50:
        print(f'  … 他 {len(diffs) - 50} 件')
    return 1


if __name__ == '__main__':
    sys.exit(main())
