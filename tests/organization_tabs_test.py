# -*- coding: utf-8 -*-
"""組織管理を 4 タブへ割ったときの整合の検査。

1 画面だったものを メンバー / 部門 / 利用システム / 組織情報 に割った。
割った後に一番静かに壊れるのは「保存したら別のタブへ飛ばされる」で、
型検査もビルドも lint も通ってしまう（どれも文字列の中身は見ない）。

ここで固定するのは 3 つ。

1. 各サーバーアクションの戻り先（redirect / parseOrRedirect）が 1 つのタブに揃っていること
2. あるタブの画面が呼ぶアクションは、そのタブへ戻るアクションだけであること
3. `/organization?...` の直書きが残っていないこと（割る前の戻り先）

2 が要るのは、フォームを別のタブへ移したときに 1 だけでは気づけないため。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, 'web', 'src', 'app', 'organization')

# タブの key → その画面のファイル
PAGES = {
    'members': os.path.join(APP, 'page.tsx'),
    'departments': os.path.join(APP, 'departments', 'page.tsx'),
    'systems': os.path.join(APP, 'systems', 'page.tsx'),
    'profile': os.path.join(APP, 'profile', 'page.tsx'),
}

FAILED = []


def action_tabs(actions_src):
    """アクション名 → そのアクションが戻すタブの集合。"""
    tabs = {}
    parts = re.split(r'(?m)^export async function (\w+)\(form: FormData\) \{', actions_src)
    for i in range(1, len(parts), 2):
        name, body = parts[i], parts[i + 1]
        body = body.split('\nexport ')[0]
        found = set(re.findall(r"orgHref\('(\w+)'", body))
        found |= set(re.findall(r"parseOrRedirect\('(\w+)'", body))
        tabs[name] = found
    return tabs


def check(actions_src, pages_src):
    failures = []
    tabs = action_tabs(actions_src)
    if not tabs:
        return ['アクションを 1 つも読み取れなかった（書式が変わった可能性）']

    # 1. 1 アクション 1 タブ
    for name, found in sorted(tabs.items()):
        if len(found) == 0:
            failures.append(f'{name}: 戻り先のタブが無い')
        elif len(found) > 1:
            failures.append(f'{name}: 戻り先が複数のタブに割れている（{sorted(found)}）')

    # 3. 割る前の直書きが残っていないか
    for literal in re.findall(r"'/organization\?[^']*'", actions_src):
        failures.append(f'割る前の戻り先が残っている: {literal}')
    for literal in re.findall(r"`/organization\?[^`]*`", actions_src):
        failures.append(f'割る前の戻り先が残っている: {literal}')

    # 2. 画面が呼ぶアクションと、その画面のタブが一致するか
    for tab, src in pages_src.items():
        used = set(re.findall(r'<form\b[^>]*action=\{(\w+)\}', src))
        if not used:
            failures.append(f'{tab}: フォームが 1 つも見つからない')
        for name in sorted(used):
            if name not in tabs:
                failures.append(f'{tab}: 未知のアクション {name}')
                continue
            if tabs[name] != {tab}:
                failures.append(
                    f'{tab} の画面が {name} を呼んでいるが、戻り先は {sorted(tabs[name])}'
                )
        # フォームは今のモードを持って出す（持たないと保存のたびにモードが落ちる）
        forms = len(re.findall(r'<form\b[^>]*action=\{\w+\}', src))
        fields = src.count('<ModeField mode={mode} />')
        if forms != fields:
            failures.append(f'{tab}: フォーム {forms} 件に対して ModeField が {fields} 件')
    return failures


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


actions_src = read(os.path.join(APP, 'actions.ts'))
pages_src = {tab: read(path) for tab, path in PAGES.items()}

FAILED += check(actions_src, pages_src)

# 逆向き検証: 壊した入力で、この検査が実際に落ちることを見る。
# 落ちないなら「検査が有る」と数えない（規範｜逆向き検証）。
REVERSE = [
    ('戻り先を別のタブへ差し替える',
     actions_src.replace("redirect(orgHref('systems', form, { saved: '1' }))",
                         "redirect(orgHref('members', form, { saved: '1' }))", 1),
     pages_src),
    ('割る前の戻り先を書き戻す',
     actions_src.replace("redirect(orgHref('profile', form, { saved: '1' }))",
                         "redirect('/organization?saved=1')", 1),
     pages_src),
    ('フォームからモードの持ち回りを外す',
     actions_src,
     {**pages_src, 'members': pages_src['members'].replace('<ModeField mode={mode} />', '', 1)}),
]
for label, bad_actions, bad_pages in REVERSE:
    if bad_actions == actions_src and bad_pages == pages_src:
        FAILED.append(f'逆向き検証の入力が壊せていない: {label}')
        continue
    if not check(bad_actions, bad_pages):
        FAILED.append(f'逆向き検証: 壊しても落ちなかった: {label}')

if FAILED:
    print('FAIL')
    for line in FAILED:
        print(' -', line)
    sys.exit(1)
print(f'PASS ({len(PAGES)} タブ / {len(action_tabs(actions_src))} アクション / 逆向き {len(REVERSE)} 件)')
