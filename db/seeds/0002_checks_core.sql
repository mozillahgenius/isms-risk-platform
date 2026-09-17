-- 標準チェック（core）。**いま実体から判定できるものだけ**を入れる。
--
-- 設計書は標準チェック 66 本を想定しているが、query_sql と negative_fixture が
-- 書かれているのは 4 本だけで、その 4 本はいずれも外部コネクタ（Google Workspace 等）の
-- 取得結果を前提にしている。コネクタは Phase 2 で未着手なので、入れても動かない。
-- 動かないチェックを並べると、カタログの件数だけが増えて「検査がある」ように見える。
-- ここでは **コネクタ無しで app.* の実体から判定できるもの**に絞る（4 本）。
--
-- 契約（この実装で決めたこと。docs/DECISIONS.md D-22）:
--   query_sql        … **違反している行**を返す SELECT。1 行も返さなければ合格。
--                      テナント文脈を確立した読み取り専用の接続で実行する。
--   expect           … {"max_violations": N} 。N 行までは合格とみなす。
--   negative_fixture … 違反を 1 件わざと作る SQL。隔離した DB で流し、
--                      **合格していた検査が落ちること**を確かめるために使う。
--                      確かめられなかったチェックは pass として記録できない（0021 の制約）。

BEGIN;
SELECT pg_advisory_xact_lock(8891234502);
SET ROLE schema_owner;

INSERT INTO catalog.checks
  (key, dom_version_id, title_ja, severity, cadence, connectors,
   query_sql, expect, coverage_required, evidence_mode, due_days, assign_to, negative_fixture)
SELECT x.key, d.id, x.title_ja, x.severity, x.cadence, x.connectors,
       x.query_sql, x.expect, x.coverage_required, x.evidence_mode, x.due_days, x.assign_to,
       x.negative_fixture
  FROM catalog.dom_versions d,
  LATERAL (VALUES
    ('CHK-CORE-POLICY-001',
     '標準規程がすべて展開されている',
     'high', 'monthly', '{}'::text[],
     $q$SELECT d.key AS missing_policy_key, d.title_ja
          FROM catalog.policies_default d
          JOIN catalog.dom_versions v ON v.id = d.dom_version_id AND v.is_current
         WHERE NOT EXISTS (
                 SELECT 1 FROM app.policies p WHERE p.catalog_key = d.key)$q$,
     '{"max_violations": 0}'::jsonb, 1.00, 'attach_rows', 30, 'secretariat',
     -- 展開済みの 1 本から標準への結び付きを外す＝展開漏れと同じ状態を作る
     $f$UPDATE app.policies SET catalog_key = NULL
         WHERE catalog_key = (SELECT catalog_key FROM app.policies
                               WHERE catalog_key IS NOT NULL ORDER BY catalog_key LIMIT 1)$f$),

    ('CHK-CORE-POLICY-002',
     '展開した規程に版が 1 つ以上ある',
     'high', 'monthly', '{}'::text[],
     $q$SELECT p.id AS policy_id, p.title
          FROM app.policies p
         WHERE NOT EXISTS (
                 SELECT 1 FROM app.policy_versions pv
                  WHERE pv.tenant_id = p.tenant_id AND pv.policy_id = p.id)$q$,
     '{"max_violations": 0}'::jsonb, 1.00, 'attach_rows', 30, 'secretariat',
     $f$DELETE FROM app.policy_versions
         WHERE id = (SELECT id FROM app.policy_versions ORDER BY id LIMIT 1)$f$),

    ('CHK-CORE-ROLE-001',
     '経営責任者が 1 人以上いる',
     'critical', 'monthly', '{}'::text[],
     -- 居ないことが違反。居ない時に 1 行返す形にする。
     $q$SELECT 'ciso' AS missing_role
         WHERE NOT EXISTS (
                 SELECT 1 FROM app.memberships m
                  WHERE m.role_key = 'ciso' AND m.revoked_at IS NULL)$q$,
     '{"max_violations": 0}'::jsonb, 1.00, 'attach_rows', 30, 'secretariat',
     $f$UPDATE app.memberships SET revoked_at = now()
         WHERE role_key = 'ciso' AND revoked_at IS NULL$f$),

    -- 規程の本文が標準から動いていないか。
    -- 設計書 1.6 は「標準からの差分は逸脱として記録される」と定めている。
    -- 逸脱として登録されないまま本文だけ書き換わると、標準に従っているように見えて中身が違う。
    -- ※ 逸脱（app.deviations）との突き合わせはまだ入れていない。ここは差分の検出まで。
    ('CHK-CORE-POLICY-003',
     '展開した規程の本文が標準と一致している',
     'high', 'monthly', '{}'::text[],
     $q$SELECT p.id AS policy_id, p.title
          FROM app.policies p
          JOIN catalog.policies_default d ON d.key = p.catalog_key
          JOIN LATERAL (
                 SELECT pv.body_md
                   FROM app.policy_versions pv
                  WHERE pv.tenant_id = p.tenant_id AND pv.policy_id = p.id
                  ORDER BY pv.version DESC LIMIT 1) latest ON true
         WHERE latest.body_md IS DISTINCT FROM d.body_md$q$,
     '{"max_violations": 0}'::jsonb, 1.00, 'attach_rows', 30, 'secretariat',
     $f$UPDATE app.policy_versions SET body_md = body_md || E'\n（標準から動かした）'
         WHERE id = (SELECT id FROM app.policy_versions ORDER BY id LIMIT 1)$f$)
  ) AS x(key, title_ja, severity, cadence, connectors, query_sql, expect,
         coverage_required, evidence_mode, due_days, assign_to, negative_fixture)
 WHERE d.is_current
ON CONFLICT (key) DO UPDATE SET
  dom_version_id    = EXCLUDED.dom_version_id,
  title_ja          = EXCLUDED.title_ja,
  severity          = EXCLUDED.severity,
  cadence           = EXCLUDED.cadence,
  connectors        = EXCLUDED.connectors,
  query_sql         = EXCLUDED.query_sql,
  expect            = EXCLUDED.expect,
  coverage_required = EXCLUDED.coverage_required,
  evidence_mode     = EXCLUDED.evidence_mode,
  due_days          = EXCLUDED.due_days,
  assign_to         = EXCLUDED.assign_to,
  negative_fixture  = EXCLUDED.negative_fixture;

-- 関連する統制への結び付け。統制カタログは IPO-KARTE のみなので、
-- 対応する要請事項が特定できるものだけを結ぶ（無理に全件結ばない）。
INSERT INTO catalog.check_controls (check_key, control_id)
SELECT 'CHK-CORE-POLICY-001', c.id
  FROM catalog.controls c
 WHERE c.framework_key = 'IPO-KARTE' AND c.theme LIKE '%規程%' AND c.retired_at IS NULL
 LIMIT 1
ON CONFLICT DO NOTHING;

-- 入れた数を確かめる。増減に気づけるように、ここで固定する。
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM catalog.checks WHERE key LIKE 'CHK-CORE-%';
  IF n <> 4 THEN
    RAISE EXCEPTION 'core チェックが 4 本になりません（現在 %本）', n;
  END IF;
END $$;

RESET ROLE;
COMMIT;
