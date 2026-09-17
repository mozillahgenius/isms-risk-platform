# -*- coding: utf-8 -*-
"""connectors/**/v*.yaml を catalog.connector_manifests へ投影する。

  python3 db/seeds/0003_connectors.py

正本は Git のマニフェスト。DB はその投影で、**この投入経路しか無い**。

投入の前に必ず検証を通す（scripts/validate_manifests.py）。検証を経ない直接投入を
残すと、検証は「投入とは別に走らせるもの」になり、いずれ走らせ忘れる。
ここで再実行するのは二度手間ではなく、**検証を通っていないものが DB に入らない**
ことを投入経路そのもので保証するため。

冪等。同じ (connector, version) は中身で上書きする。ただし
**一度使われた版の中身が変わったら分かるように**、出所（SHA-256）を記録する。
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'scripts'))

import validate_manifests as vm  # noqa: E402

# 出所の記録は既存の実装を使い回す（同じ規則で commit / SHA を出す）。
sys.path.insert(0, os.path.join(ROOT, 'db', 'seeds'))
import record_provenance as rp  # noqa: E402


def db_url() -> str:
    return os.environ.get('DATABASE_URL') or f"postgres:///{os.environ.get('ISMS_DB', 'isms_dev')}"


def sql_literal(v) -> str:
    if v is None:
        return 'NULL'
    return "'" + str(v).replace("'", "''") + "'"


def main() -> int:
    paths = vm.find_manifests([])
    if not paths:
        print('[connectors] connectors/ にマニフェストがありません', file=sys.stderr)
        return 1

    # 1. 検証。1 件でも落ちたら**何も投入しない**（半分だけ入った状態を作らない）。
    docs = []
    for path in paths:
        try:
            docs.append((path, vm.validate_manifest(path)))
        except vm.Problem as e:
            print(f'[connectors] 検証で落ちました {path}: {e}', file=sys.stderr)
            return 1

    keys = [(d['connector'], d['version']) for _, d in docs]
    if len(set(keys)) != len(keys):
        print('[connectors] (connector, version) が重複しています', file=sys.stderr)
        return 1

    # 2. 投入。1 トランザクションで全部入れる。
    stmts = ['SET ROLE schema_owner;', 'BEGIN;',
             "SELECT pg_advisory_xact_lock(hashtext('isms:seed:connectors'));"]
    for path, doc in docs:
        stmts.append(
            'INSERT INTO catalog.connector_manifests (connector, version, kind, manifest)'
            f' VALUES ({sql_literal(doc["connector"])}, {doc["version"]},'
            f' {sql_literal(doc["kind"])}, {sql_literal(json.dumps(doc, ensure_ascii=False, sort_keys=True))}::jsonb)'
            ' ON CONFLICT (connector, version) DO UPDATE SET'
            '   kind = EXCLUDED.kind, manifest = EXCLUDED.manifest;'
        )

    # 3. 出所。**マニフェストは複数ファイルなので、1 ファイルの SHA では表せない。**
    #    各ファイルの「相対パス + SHA-256」を並べて、その全体の SHA-256 を記録する
    #    （1 ファイルだけ選ぶと、他が変わっても記録が動かない）。
    manifest_dir = os.path.join(ROOT, 'connectors')
    lines = []
    for path in paths:
        rel = os.path.relpath(os.path.abspath(str(path)), ROOT)
        lines.append(f'{rel} {rp.sha256_of(str(path))}')
    digest_src = '\n'.join(sorted(lines)) + '\n'
    import hashlib
    digest = hashlib.sha256(digest_src.encode('utf-8')).hexdigest()

    # commit は「connectors/ 配下が HEAD と一致しているときだけ」記録する。
    # 1 ファイルでも作業ツリーが汚れていれば NULL（存在しない状態を指さない）。
    commit = rp.git(ROOT, 'rev-parse', 'HEAD')
    for path in paths:
        rel = os.path.relpath(os.path.abspath(str(path)), ROOT)
        if rp.commit_if_clean(ROOT, rel, str(path)) is None:
            commit = None
            break

    stmts.append(
        'INSERT INTO catalog.seed_provenance'
        ' (target, source_repo, source_commit, source_path, source_sha256,'
        '  dom_version_id, row_count, loader, loaded_at)'
        f" SELECT 'connector_manifests', {sql_literal(rp.repo_slug(ROOT))}, {sql_literal(commit)},"
        f" 'connectors', {sql_literal(digest)},"
        '        d.id, (SELECT count(*) FROM catalog.connector_manifests),'
        " 'db/seeds/0003_connectors.py', now()"
        '   FROM catalog.dom_versions d WHERE d.is_current'
        ' ON CONFLICT (target) DO UPDATE SET'
        '   source_repo = EXCLUDED.source_repo,'
        '   source_commit = EXCLUDED.source_commit,'
        '   source_path = EXCLUDED.source_path,'
        '   source_sha256 = EXCLUDED.source_sha256,'
        '   dom_version_id = EXCLUDED.dom_version_id,'
        '   row_count = EXCLUDED.row_count,'
        '   loader = EXCLUDED.loader,'
        '   loaded_at = EXCLUDED.loaded_at;'
    )

    # 4. 投入した件数が、検証を通ったファイルの数と一致すること。
    #    「入ったつもり」で終わらせない。
    stmts.append(
        'DO $$ DECLARE n int; BEGIN'
        '  SELECT count(*) INTO n FROM catalog.connector_manifests;'
        f'  IF n <> {len(docs)} THEN'
        f"    RAISE EXCEPTION 'マニフェストの件数が合いません: DB % / ファイル {len(docs)}', n;"
        '  END IF;'
        ' END $$;'
    )
    stmts.append('COMMIT;')

    proc = subprocess.run(
        ['psql', '-v', 'ON_ERROR_STOP=1', '-q', '-d', db_url(), '-f', '-'],
        input='\n'.join(stmts), text=True,
    )
    if proc.returncode != 0:
        return proc.returncode

    for path, doc in docs:
        rel = os.path.relpath(os.path.abspath(str(path)), ROOT)
        print(f'[connectors] {doc["connector"]} v{doc["version"]} ({doc["kind"]}) '
              f'← {rel} / resource {len(doc["resources"])} 件')
    print(f'[connectors] 出所: {rp.repo_slug(ROOT)} connectors '
          f'commit={commit or "(未コミットの変更あり)"} sha={digest[:12]}…')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
