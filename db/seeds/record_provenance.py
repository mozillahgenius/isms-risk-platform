# -*- coding: utf-8 -*-
"""Measure and record in catalog.seed_provenance "where the canonical source of the rules is".

  python3 db/seeds/record_provenance.py [--scripts-dir <dir>]

The UI's source display reads only this table. Embedding fixed strings in the UI would
keep the UI looking the same even when upstream changes (that would be decoration, not a source display).

--scripts-dir (or env var LEGAL_SCRIPTS_DIR) is the same as in load_csv.py.
Default is db/seeds/snapshots (a fictional sample catalog).

Recorded (one row per target, idempotent):
  dom                    … this repository's db/seeds/0001_dom_2026_1.sql
  controls               … <scripts-dir>/control_check/control_requirements_master.csv
  risk_scenario_templates… <scripts-dir>/risk_map/risk_map_master.csv

A commit is recorded "only when that file matches HEAD".
Writing a commit while the working tree is dirty would point to a state that doesn't actually exist.
If it doesn't match, NULL is stored and the UI shows "uncommitted changes".
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
    """Run git in repo and return stdout. None if git is missing / not a repo / fails."""
    try:
        out = subprocess.run(
            ['git', '-C', repo, *args],
            capture_output=True, text=True, check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    return out.stdout.strip()


def repo_slug(repo: str) -> str:
    """Return owner/name. Without a remote, return the directory name in parentheses (no URL is written)."""
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
    """Return HEAD's SHA if rel_path's content matches HEAD, else None.

    The check uses a **direct blob hash comparison**, not `git status`.
    status returns empty for .gitignore'd untracked files and for files marked `assume-unchanged` / `skip-worktree`,
    so it can report "match" even when the file actually differs from HEAD.
    Comparing blobs leaves no such loophole.
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
    # Read the same variable as load_csv.py (reading a different one would record a file other than the one loaded).
    ap.add_argument('--scripts-dir', default=os.environ.get('LEGAL_SCRIPTS_DIR', DEFAULT_SCRIPTS))
    args = ap.parse_args()

    scripts_dir = os.path.abspath(args.scripts_dir)
    # Determine the commit at the top level of the Git repository containing the file (for the bundled sample, this repository).
    upstream_repo = (git(scripts_dir, 'rev-parse', '--show-toplevel')
                     or os.path.normpath(os.path.join(scripts_dir, '..')))

    targets = [
        {
            'target': 'dom',
            'repo': ROOT,
            'file': os.path.join(ROOT, 'db', 'seeds', '0001_dom_2026_1.sql'),
            'loader': 'db/seeds/0001_dom_2026_1.sql',
            # Count the rows this seed file defines **that belong to the current DOM**.
            # Writing the dom_versions row count (= number of versions) would inflate it just because old versions remain,
            # and it would no longer represent "what came in from this file".
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
            # IPO-KARTE comes from the upstream CSV. ISO Annex A is the standard catalog in 0009_relationships.sql,
            # so don't mix it into this count.
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
        # Without a current DOM, the INSERT ... SELECT below inserts no rows.
        # Unless we fail early, we can't notice that "no rows were inserted".
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
        # row_count uses the value measured in the DB, not what the loader claims.
        # Writing the claimed value could record "everything loaded" even if loading failed midway.
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

    # Verify not that 3 rows "exist" but that **all 3 were written in this run**.
    # Simply counting the total would pass with 3 stale rows left from a previous run,
    # looking successful even if not a single row was updated this time.
    # now() is the transaction start time, so rows written in this run share the same loaded_at.
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
