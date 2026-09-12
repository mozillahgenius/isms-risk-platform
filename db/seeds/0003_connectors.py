# -*- coding: utf-8 -*-
"""Project connectors/**/v*.yaml into catalog.connector_manifests.

  python3 db/seeds/0003_connectors.py

The source of truth is the Git manifests. The DB is their projection, and **this is the only loading path**.

Always run validation before loading (scripts/validate_manifests.py). Leaving a direct load that skips
validation would make validation "something run separately from loading", and eventually it gets forgotten.
Re-running it here is not duplicate work: it guarantees, through the loading path itself, that **nothing that
failed validation gets into the DB**.

Idempotent. The same (connector, version) is overwritten with its contents. However,
provenance (SHA-256) is recorded **so that a change to the contents of an already-used version is detectable**.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'scripts'))

import validate_manifests as vm  # noqa: E402

# Reuse the existing implementation for provenance recording (commit / SHA produced by the same rules).
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

    # 1. Validate. If even one fails, **load nothing** (never leave a half-loaded state).
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

    # 2. Load. Insert everything in one transaction.
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

    # 3. Provenance. **The manifests span multiple files, so a single file's SHA cannot represent them.**
    #    List "relative path + SHA-256" for each file and record the SHA-256 of the whole
    #    (picking just one file would leave the record unchanged when others change).
    manifest_dir = os.path.join(ROOT, 'connectors')
    lines = []
    for path in paths:
        rel = os.path.relpath(os.path.abspath(str(path)), ROOT)
        lines.append(f'{rel} {rp.sha256_of(str(path))}')
    digest_src = '\n'.join(sorted(lines)) + '\n'
    import hashlib
    digest = hashlib.sha256(digest_src.encode('utf-8')).hexdigest()

    # Record commit only when "everything under connectors/ matches HEAD".
    # If even one file in the working tree is dirty, NULL (do not point at a state that does not exist).
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

    # 4. The number loaded must match the number of files that passed validation.
    #    Do not stop at "it should have gone in".
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
