#!/usr/bin/env python3
"""Apply the standard policies (catalog.policies_default) to existing tenants.

Why this is needed:
  Policies are deployed to a tenant only by app.provision_tenant(), i.e. **only at the moment
  the tenant is created**. Standard policies added or bodies written later never reach
  existing tenants. If only the catalog changes without reaching them, CHK-CORE-POLICY-003
  (deployed policy bodies match the standard) keeps firing as a violation.

What it does (one transaction):
  1. Adds policies not yet deployed to app.policies and puts the standard body into version 1
  2. Aligns titles that differ from the catalog
  3. For policies whose latest version body differs from the catalog, **adds a new version**
     (existing version bodies are not rewritten; the previous version gets superseded_at)

What it does not do:
  - It does not approve. approved_by / approved_at / effective_from are not set.
    This script only "distributes the standard"; the decision to make it effective is made by a person.
  - It does not create deviations (policy_edit). The body inserted here is the standard itself,
    so there is no difference from the standard. Deviations are registered when a tenant changes a body.
  - It does not touch other tenants. Row-level security is in effect via the tenant context (token),
    so other tenants' rows are not even visible.

diff_clause_count is 0, because it is a copy of the standard and no clauses were changed.

Usage:
  python3 scripts/sync_tenant_policies.py --dry-run   # only show changes (rolled back)
  python3 scripts/sync_tenant_policies.py             # apply

Connection:
  ISMS_WRITE_DATABASE_URL (default postgres://127.0.0.1/isms_dev?user=app_rw)
  ISMS_WEB_TENANT_TOKEN or the token in web/.env.local
"""

from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def literal(value: str) -> str:
    """Make an SQL string literal (quotes doubled)."""
    return "'" + value.replace("'", "''") + "'"


def read_token() -> str:
    value = os.environ.get("ISMS_WEB_TENANT_TOKEN", "").strip()
    if value:
        return value
    env_path = ROOT / "web" / ".env.local"
    if env_path.exists():
        for line in env_path.read_text(encoding="utf-8").splitlines():
            if line.startswith("ISMS_WEB_TENANT_TOKEN="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit(
        "ISMS_WEB_TENANT_TOKEN がありません。web/.env.local または環境変数を確認してください。"
    )


SQL = r"""
BEGIN;
SELECT app.set_tenant_context(__TENANT_TOKEN__);

-- Show the state before applying, so we never claim "inserted" without looking at the counts.
SELECT '反映前' AS phase,
       (SELECT count(*) FROM catalog.policies_default d
          JOIN catalog.dom_versions v ON v.id = d.dom_version_id AND v.is_current) AS catalog_policies,
       (SELECT count(*) FROM app.policies WHERE tenant_id = app.current_tenant()) AS tenant_policies,
       (SELECT count(*) FROM app.policy_versions WHERE tenant_id = app.current_tenant()) AS versions,
       (SELECT count(*) FROM app.policies p
          JOIN catalog.policies_default d ON d.key = p.catalog_key
          JOIN catalog.dom_versions dv ON dv.id = d.dom_version_id AND dv.is_current
          JOIN LATERAL (SELECT body_md FROM app.policy_versions pv
                         WHERE pv.tenant_id = p.tenant_id AND pv.policy_id = p.id
                         ORDER BY version DESC LIMIT 1) v ON true
         WHERE p.tenant_id = app.current_tenant()
           AND v.body_md IS DISTINCT FROM d.body_md) AS body_mismatch;

-- Prevent two runs at the same time.
-- Row locks alone are not enough: rows for **policies that do not exist yet** cannot be locked, so
-- two concurrent runs would try to create the same policy twice (the unique constraint just makes one fail,
-- and the partially applied run leaves nothing meaningful). A per-tenant advisory lock admits only one run.
SELECT pg_advisory_xact_lock(hashtext('isms:sync_tenant_policies'),
                             hashtext(app.current_tenant()::text));

-- Also lock existing policy rows (so version numbering does not race).
SELECT id FROM app.policies
 WHERE tenant_id = app.current_tenant()
 ORDER BY id
   FOR UPDATE;

-- 1. Policies not yet expanded. Decide the id up front and write it without reading it back
--    (same reason as app.provision_tenant(): RETURNING requires read privilege).
WITH src AS MATERIALIZED (
  -- gen_random_uuid() is volatile. It is referenced twice, so fix its value exactly once.
  SELECT gen_random_uuid() AS policy_id, d.key, d.title_ja, d.body_md
    FROM catalog.policies_default d
    JOIN catalog.dom_versions v ON v.id = d.dom_version_id AND v.is_current
   WHERE NOT EXISTS (SELECT 1 FROM app.policies p
                      WHERE p.tenant_id = app.current_tenant() AND p.catalog_key = d.key)
), ins AS (
  INSERT INTO app.policies (id, tenant_id, catalog_key, title)
  SELECT policy_id, app.current_tenant(), key, title_ja FROM src
)
INSERT INTO app.policy_versions (tenant_id, policy_id, version, body_md, diff_clause_count)
SELECT app.current_tenant(), policy_id, 1, body_md, 0 FROM src;

-- 2. Align titles with the catalog.
UPDATE app.policies p
   SET title = d.title_ja, updated_at = now()
  FROM catalog.policies_default d
  JOIN catalog.dom_versions dv ON dv.id = d.dom_version_id AND dv.is_current
 WHERE d.key = p.catalog_key
   AND p.tenant_id = app.current_tenant()
   AND p.title IS DISTINCT FROM d.title_ja;

-- 3. Add a new version to policies whose body has changed. Existing versions are never rewritten.
WITH latest AS (
  SELECT p.id AS policy_id, d.body_md AS want,
         v.version AS cur_version, v.id AS cur_version_id, v.body_md AS have
    FROM app.policies p
    JOIN catalog.policies_default d ON d.key = p.catalog_key
    JOIN catalog.dom_versions dv ON dv.id = d.dom_version_id AND dv.is_current
    LEFT JOIN LATERAL (
      SELECT id, version, body_md FROM app.policy_versions pv
       WHERE pv.tenant_id = p.tenant_id AND pv.policy_id = p.id
       ORDER BY version DESC LIMIT 1) v ON true
   WHERE p.tenant_id = app.current_tenant()
), changed AS (
  SELECT * FROM latest WHERE have IS DISTINCT FROM want
), sup AS (
  UPDATE app.policy_versions pv
     SET superseded_at = now(), updated_at = now()
    FROM changed c
   WHERE pv.tenant_id = app.current_tenant()
     AND pv.id = c.cur_version_id
     AND pv.superseded_at IS NULL
)
INSERT INTO app.policy_versions (tenant_id, policy_id, version, body_md, diff_clause_count)
SELECT app.current_tenant(), c.policy_id, coalesce(c.cur_version, 0) + 1, c.want, 0
  FROM changed c;

-- 4. Verify on the spot that the sync took effect.
--    If this fails, the sync did not happen. Do not let it COMMIT.
DO $$
DECLARE n_missing int; n_mismatch int;
BEGIN
  SELECT count(*) INTO n_missing
    FROM catalog.policies_default d
    JOIN catalog.dom_versions v ON v.id = d.dom_version_id AND v.is_current
   WHERE NOT EXISTS (SELECT 1 FROM app.policies p
                      WHERE p.tenant_id = app.current_tenant() AND p.catalog_key = d.key);
  IF n_missing <> 0 THEN
    RAISE EXCEPTION '展開されていない標準規程が % 本ある', n_missing;
  END IF;

  SELECT count(*) INTO n_mismatch
    FROM app.policies p
    JOIN catalog.policies_default d ON d.key = p.catalog_key
    JOIN catalog.dom_versions dv ON dv.id = d.dom_version_id AND dv.is_current
    JOIN LATERAL (SELECT body_md FROM app.policy_versions pv
                   WHERE pv.tenant_id = p.tenant_id AND pv.policy_id = p.id
                   ORDER BY version DESC LIMIT 1) v ON true
   WHERE p.tenant_id = app.current_tenant()
     AND v.body_md IS DISTINCT FROM d.body_md;
  IF n_mismatch <> 0 THEN
    RAISE EXCEPTION '最新版の本文が標準と一致しない規程が % 本ある', n_mismatch;
  END IF;

  -- Version numbers must be consecutive starting at 1 (gaps from concurrent runs make the history unreadable).
  -- max = count alone is not enough: it would accept sequences that do not start at 1, such as (0,2).
  IF EXISTS (
    SELECT 1 FROM app.policies p
     CROSS JOIN LATERAL (
       SELECT min(version) AS lo, max(version) AS hi, count(*) AS n
         FROM app.policy_versions pv
        WHERE pv.tenant_id = p.tenant_id AND pv.policy_id = p.id) v
     WHERE p.tenant_id = app.current_tenant()
       AND (v.n = 0 OR v.lo <> 1 OR v.hi <> v.n)
  ) THEN
    RAISE EXCEPTION '版番号が 1 から始まる連番になっていない規程がある';
  END IF;
END $$;

SELECT '反映後' AS phase,
       (SELECT count(*) FROM app.policies WHERE tenant_id = app.current_tenant()) AS tenant_policies,
       (SELECT count(*) FROM app.policy_versions WHERE tenant_id = app.current_tenant()) AS versions,
       (SELECT count(*) FROM app.policy_versions
         WHERE tenant_id = app.current_tenant() AND superseded_at IS NOT NULL) AS superseded,
       (SELECT count(*) FROM app.policy_versions
         WHERE tenant_id = app.current_tenant() AND approved_at IS NOT NULL) AS approved;
COMMIT;
"""


def main() -> None:
    parser = argparse.ArgumentParser(description="標準規程を既存テナントへ反映する")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="反映せず、前後の件数だけを見る（最後に巻き戻す）",
    )
    args = parser.parse_args()

    token = read_token()
    dsn = os.environ.get("ISMS_WRITE_DATABASE_URL", "postgres://127.0.0.1/isms_dev?user=app_rw")
    sql = SQL.replace("\nCOMMIT;\n", "\nROLLBACK;\n") if args.dry_run else SQL
    # The token is **passed via stdin**. Putting it in psql arguments (-v tenant_token=...) would let
    # anyone on the same machine read it with ps. In the SQL body it never appears in argv.
    sql = sql.replace("__TENANT_TOKEN__", literal(token))
    command = ["psql", "-X", "-v", "ON_ERROR_STOP=1", "-d", dsn]
    subprocess.run(command, input=sql, text=True, check=True)
    print("sync_tenant_policies: OK" + ("（dry-run。巻き戻した）" if args.dry_run else "（反映した）"))


if __name__ == "__main__":
    main()
