# -*- coding: utf-8 -*-
"""Consistency check for splitting organization management into 4 tabs.

What used to be one screen was split into Members / Departments / Systems in use / Organization info.
The quietest breakage after a split is "saving sends you to a different tab",
and it passes type checking, build, and lint (none of them look at string contents).

Three things are pinned here.

1. Each server action's return target (redirect / parseOrRedirect) resolves to exactly one tab
2. The actions a tab's screen calls are only actions that return to that tab
3. No hard-coded `/organization?...` remains (the pre-split return target)

2 is needed because 1 alone cannot catch a form that was moved to another tab.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, 'web', 'src', 'app', 'organization')

# tab key -> file of that screen
PAGES = {
    'members': os.path.join(APP, 'page.tsx'),
    'departments': os.path.join(APP, 'departments', 'page.tsx'),
    'systems': os.path.join(APP, 'systems', 'page.tsx'),
    'profile': os.path.join(APP, 'profile', 'page.tsx'),
}

FAILED = []


def action_tabs(actions_src):
    """Action name -> set of tabs that action returns to."""
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

    # 1. one action, one tab
    for name, found in sorted(tabs.items()):
        if len(found) == 0:
            failures.append(f'{name}: 戻り先のタブが無い')
        elif len(found) > 1:
            failures.append(f'{name}: 戻り先が複数のタブに割れている（{sorted(found)}）')

    # 3. whether pre-split hard-coded targets remain
    for literal in re.findall(r"'/organization\?[^']*'", actions_src):
        failures.append(f'割る前の戻り先が残っている: {literal}')
    for literal in re.findall(r"`/organization\?[^`]*`", actions_src):
        failures.append(f'割る前の戻り先が残っている: {literal}')

    # 2. whether the actions a screen calls match that screen's tab
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
        # forms carry the current mode (without it the mode is dropped on every save)
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

# Reverse verification: confirm with broken input that this check actually fails.
# If it does not fail, do not count it as "a check exists" (norm: reverse verification).
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
