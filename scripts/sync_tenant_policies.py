#!/usr/bin/env python3
"""既に在るテナントへ、標準規程（catalog.policies_default）を反映する。

なぜ要るか:
  規程がテナントへ展開されるのは app.provision_tenant()、つまり **テナントを作る
  瞬間だけ**。あとから標準規程を足したり本文を書いたりしても、既存のテナントには
  何も届かない。届かないまま catalog だけ変えると、CHK-CORE-POLICY-003
  （展開した規程の本文が標準と一致している）が違反として鳴り続ける。

やること（1 トランザクション）:
  1. まだ展開されていない規程を app.policies へ足し、版 1 に標準の本文を入れる
  2. 題名が catalog と違えば合わせる
  3. 最新版の本文が catalog と違う規程に、**新しい版を足す**
     （既存の版の本文は書き換えない。前の版には superseded_at を打つ）

やらないこと:
  - 承認しない。approved_by / approved_at / effective_from は入れない。
    このスクリプトは「標準を配る」だけで、有効化の判断は人が行う。
  - 逸脱（policy_edit）は作らない。ここで入れる本文は標準そのものなので、
    標準からの差分は生じない。テナントが本文を変えるときに逸脱を登録する。
  - 他テナントには触れない。テナント文脈（トークン）で行レベルセキュリティが
    効いているため、他テナントの行はそもそも見えない。

diff_clause_count は 0。標準の写しであって、条項を変えたわけではないため。

使い方:
  python3 scripts/sync_tenant_policies.py --dry-run   # 変更点を見るだけ（巻き戻す）
  python3 scripts/sync_tenant_policies.py             # 反映する

接続:
  ISMS_WRITE_DATABASE_URL（既定 postgres://127.0.0.1/isms_dev?user=app_rw）
  ISMS_WEB_TENANT_TOKEN もしくは web/.env.local のトークン
"""

from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def literal(value: str) -> str:
    """SQL の文字列リテラルにする（引用符は二重化）。"""
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

-- 反映前の状態を出す。件数を見ずに「入れた」と言わないため。
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

-- 同時に 2 つ走らないようにする。
-- 行ロックだけでは足りない。**まだ存在しない規程行**は押さえられないので、
-- 2 本が同時に走ると同じ規程を二重に作ろうとする（一意制約で片方が落ちるだけで、
-- 途中まで進んだ側の意味は残らない）。テナント単位の助言ロックで入口を 1 本に絞る。
SELECT pg_advisory_xact_lock(hashtext('isms:sync_tenant_policies'),
                             hashtext(app.current_tenant()::text));

-- 既にある規程行も押さえる（版番号の採番が競合しないように）。
SELECT id FROM app.policies
 WHERE tenant_id = app.current_tenant()
 ORDER BY id
   FOR UPDATE;

-- 1. まだ展開されていない規程。id を先に決めてしまい、書き戻して読まない
--    （app.provision_tenant() と同じ理由。RETURNING は読み取りの権限を要求する）。
WITH src AS MATERIALIZED (
  -- gen_random_uuid() は volatile。2 度参照するので必ず 1 回で確定させる。
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

-- 2. 題名を catalog に合わせる。
UPDATE app.policies p
   SET title = d.title_ja, updated_at = now()
  FROM catalog.policies_default d
  JOIN catalog.dom_versions dv ON dv.id = d.dom_version_id AND dv.is_current
 WHERE d.key = p.catalog_key
   AND p.tenant_id = app.current_tenant()
   AND p.title IS DISTINCT FROM d.title_ja;

-- 3. 本文が動いている規程に、新しい版を足す。既存の版は書き換えない。
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

-- 4. 反映できたことをその場で確かめる。
--    ここが落ちるなら反映は成立していない。COMMIT させない。
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

  -- 版番号が 1 から始まる連番であること（同時実行で飛ぶと履歴が読めなくなる）。
  -- max = count だけでは足りない。(0,2) のように 1 始まりでない並びを通してしまう。
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
    # トークンは **標準入力で渡す**。psql の引数（-v tenant_token=...）に置くと、
    # 同じ機の誰でも ps で読める。SQL 本文なら argv には出ない。
    sql = sql.replace("__TENANT_TOKEN__", literal(token))
    command = ["psql", "-X", "-v", "ON_ERROR_STOP=1", "-d", dsn]
    subprocess.run(command, input=sql, text=True, check=True)
    print("sync_tenant_policies: OK" + ("（dry-run。巻き戻した）" if args.dry_run else "（反映した）"))


if __name__ == "__main__":
    main()
