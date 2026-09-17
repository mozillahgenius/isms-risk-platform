# -*- coding: utf-8 -*-
"""catalog.seed_provenance に「ルールの正本がどこか」を実測して記録する。

  python3 db/seeds/record_provenance.py [--scripts-dir <dir>]

画面の出所表示はこの表だけを読む。固定文字列を画面へ埋め込むと、
上流が動いても画面は同じ顔をしたままになる（それは出所表示ではなく飾りになる）。

記録するもの（対象ごとに 1 行・冪等）:
  dom                    … このリポジトリの db/seeds/0001_dom_2026_1.sql
  controls               … <scripts-dir>/control_check/control_requirements_master.csv
  risk_scenario_templates… <scripts-dir>/risk_map/risk_map_master.csv

commit は「そのファイルが HEAD と一致しているときだけ」記録する。
作業ツリーが汚れたまま commit を書くと、実際には存在しない状態を指すため。
一致しなければ NULL にして、画面側は「未コミットの変更あり」と出す。
"""
from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_SCRIPTS = os.path.join(ROOT, 'db', 'seeds', 'snapshots')


def db_url() -> str:
    return os.environ.get('DATABASE_URL') or f"postgres:///{os.environ.get('ISMS_DB', 'isms_dev')}"


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def git(repo: str, *args: str) -> str | None:
    """repo で git を実行して stdout を返す。git が無い / repo でない / 失敗なら None。"""
    try:
        out = subprocess.run(
            ['git', '-C', repo, *args],
            capture_output=True, text=True, check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    return out.stdout.strip()


def repo_slug(repo: str) -> str:
    """owner/name を返す。remote が無ければディレクトリ名を括弧付きで返す（URL は書かない）。"""
    url = git(repo, 'config', '--get', 'remote.origin.url')
    if url:
        s = url.rstrip('/')
        if s.endswith('.git'):
            s = s[:-4]
        if ':' in s or '/' in s:
            parts = s.replace(':', '/').split('/')
            if len(parts) >= 2:
                return f'{parts[-2]}/{parts[-1]}'
    return f'(local) {os.path.basename(os.path.abspath(repo))}'


def commit_if_clean(repo: str, rel_path: str, abs_path: str) -> str | None:
    """rel_path の中身が HEAD と一致していれば HEAD の SHA を返す。違えば None。

    判定は `git status` ではなく **blob ハッシュの直接比較**で行う。
    status は .gitignore された未追跡ファイル、`assume-unchanged` / `skip-worktree`
    を指定されたファイルで空を返すため、実際には HEAD と違うのに「一致」と誤判定し得る。
    blob を突き合わせれば、その抜け道が無い。
    """
    head = git(repo, 'rev-parse', 'HEAD')
    if not head:
        return None
    head_blob = git(repo, 'rev-parse', f'HEAD:{rel_path}')
    file_blob = git(repo, 'hash-object', abs_path)
    if not head_blob or not file_blob or head_blob != file_blob:
        return None
    return head


def rel_to(repo: str, path: str) -> str:
    return os.path.relpath(os.path.abspath(path), os.path.abspath(repo))


def sql_literal(v: str | None) -> str:
    if v is None:
        return 'NULL'
    return "'" + v.replace("'", "''") + "'"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--scripts-dir', default=os.environ.get('CATALOG_SCRIPTS_DIR', DEFAULT_SCRIPTS))
    args = ap.parse_args()

    scripts_dir = os.path.abspath(args.scripts_dir)
    upstream_repo = (git(scripts_dir, 'rev-parse', '--show-toplevel')
                     or os.path.normpath(os.path.join(scripts_dir, '..')))

    targets = [
        {
            'target': 'dom',
            'repo': ROOT,
            'file': os.path.join(ROOT, 'db', 'seeds', '0001_dom_2026_1.sql'),
            'loader': 'db/seeds/0001_dom_2026_1.sql',
            # この seed ファイルが定義する行のうち、**現行 DOM に属するもの**を数える。
            # dom_versions の行数（＝版の数）を書くと、旧版が残っているだけで数が増え、
            # 「このファイルから何が入ったか」を表さなくなる。
            'count_sql': (
                'SELECT (SELECT count(*) FROM catalog.roles_default)'
                '     + (SELECT count(*) FROM catalog.asset_classes_default)'
                '     + (SELECT count(*) FROM catalog.calendar_events_default)'
                '     + (SELECT count(*) FROM catalog.policies_default p'
                '          JOIN catalog.dom_versions d ON d.id = p.dom_version_id AND d.is_current)'
                '     + (SELECT count(*) FROM catalog.risk_criteria_default r'
                '          JOIN catalog.dom_versions d ON d.id = r.dom_version_id AND d.is_current)'
            ),
        },
        {
            'target': 'controls',
            'repo': upstream_repo,
            'file': os.path.join(scripts_dir, 'control_check', 'control_requirements_master.csv'),
            'loader': 'db/seeds/load_csv.py',
            # IPO-KARTE は上流 CSV 由来。ISO Annex A は 0009_relationships.sql の
            # 標準カタログなので、ここで混ぜて数えない。
            'count_sql': "SELECT count(*) FROM catalog.controls WHERE framework_key = 'IPO-KARTE' AND retired_at IS NULL",
        },
        {
            'target': 'risk_scenario_templates',
            'repo': upstream_repo,
            'file': os.path.join(scripts_dir, 'risk_map', 'risk_map_master.csv'),
            'loader': 'db/seeds/load_csv.py',
            'count_sql': 'SELECT count(*) FROM catalog.risk_scenario_templates WHERE retired_at IS NULL',
        },
    ]

    stmts = [
        'SET ROLE schema_owner;',
        # 現行 DOM が無いと、下の INSERT ... SELECT は 1 行も入らない。
        # 先に落としておかないと「1 行も入らなかった」ことに気づけない。
        "DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM catalog.dom_versions WHERE is_current) THEN"
        "  RAISE EXCEPTION '現行 DOM がありません。先に db/seeds/0001_dom_2026_1.sql を流してください';"
        " END IF; END $$;",
    ]
    for t in targets:
        path = t['file']
        if not os.path.isfile(path):
            print(f"[provenance] 見つかりません: {path}", file=sys.stderr)
            return 1
        rel = rel_to(t["repo"], path)
        row = {
            'target': t['target'],
            'source_repo': repo_slug(t['repo']),
            'source_commit': commit_if_clean(t['repo'], rel, path),
            'source_path': rel,
            'source_sha256': sha256_of(path),
            'loader': t['loader'],
        }
        # row_count は投入した側の申告ではなく DB の実測を使う。
        # 申告値を書くと、投入が途中で落ちても「全部入った」と記録され得る。
        stmts.append(
            "INSERT INTO catalog.seed_provenance"
            " (target, source_repo, source_commit, source_path, source_sha256,"
            "  dom_version_id, row_count, loader, loaded_at)"
            " SELECT {target}, {repo}, {commit}, {path}, {sha},"
            "        d.id, ({cnt}), {loader}, now()"
            "   FROM catalog.dom_versions d WHERE d.is_current"
            " ON CONFLICT (target) DO UPDATE SET"
            "   source_repo = EXCLUDED.source_repo,"
            "   source_commit = EXCLUDED.source_commit,"
            "   source_path = EXCLUDED.source_path,"
            "   source_sha256 = EXCLUDED.source_sha256,"
            "   dom_version_id = EXCLUDED.dom_version_id,"
            "   row_count = EXCLUDED.row_count,"
            "   loader = EXCLUDED.loader,"
            "   loaded_at = EXCLUDED.loaded_at;".format(
                target=sql_literal(row['target']),
                repo=sql_literal(row['source_repo']),
                commit=sql_literal(row['source_commit']),
                path=sql_literal(row['source_path']),
                sha=sql_literal(row['source_sha256']),
                cnt=t['count_sql'],
                loader=sql_literal(row['loader']),
            )
        )
        print(f"[provenance] {row['target']}: {row['source_repo']} {rel} "
              f"commit={row['source_commit'] or '(未コミットの変更あり)'} sha={row['source_sha256'][:12]}…")

    # 3 行「在る」ことではなく、**この実行で 3 行とも書けた**ことを確かめる。
    # 単に総数を数えると、前回の古い行が 3 行残っているだけで通ってしまい、
    # 今回 1 行も更新できていなくても成功に見える。
    # now() はトランザクション開始時刻なので、この実行で書いた行は loaded_at が揃う。
    stmts.append(
        "DO $$ BEGIN"
        "  IF (SELECT count(*) FROM catalog.seed_provenance p"
        "        JOIN catalog.dom_versions d ON d.id = p.dom_version_id AND d.is_current"
        "       WHERE p.loaded_at = now()) <> 3 THEN"
        "    RAISE EXCEPTION 'この実行で更新できた出所が 3 件ありません（現在 %件）',"
        "      (SELECT count(*) FROM catalog.seed_provenance WHERE loaded_at = now());"
        "  END IF;"
        " END $$;"
    )

    p = subprocess.run(
        ['psql', '-v', 'ON_ERROR_STOP=1', '-q', '-d', db_url(), '-c', '\n'.join(stmts)],
        text=True,
    )
    return p.returncode


if __name__ == '__main__':
    raise SystemExit(main())
