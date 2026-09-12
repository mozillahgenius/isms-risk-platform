-- Standard checks (core). Only **what can be judged from actual data today** goes in.
--
-- The design doc envisions 66 standard checks, but only 4 have query_sql and negative_fixture
-- written, and all 4 presuppose results fetched by external connectors (Google Workspace etc.).
-- Connectors are Phase 2 and not started yet, so they would not work even if added.
-- Listing checks that do not run only inflates the catalog count and makes it look like "there are checks".
-- Here we restrict to **what can be judged from app.* data without connectors** (4 checks).
--
-- Contract (decided in this implementation; docs/DECISIONS.md D-22):
--   query_sql        ... a SELECT returning **violating rows**. Passes if it returns no rows.
--                      Run over a read-only connection with the tenant context established.
--   expect           ... {"max_violations": N}. Up to N rows counts as a pass.
--   negative_fixture ... SQL that deliberately creates one violation. Run in an isolated DB and
--                      used to confirm **that a previously passing check fails**.
--                      A check that could not be confirmed cannot be recorded as pass (0021's constraint).

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
     -- detach one expanded policy from its standard = create the same state as a missed expansion
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
     -- Absence is the violation. Return one row when absent.
     $q$SELECT 'ciso' AS missing_role
         WHERE NOT EXISTS (
                 SELECT 1 FROM app.memberships m
                  WHERE m.role_key = 'ciso' AND m.revoked_at IS NULL)$q$,
     '{"max_violations": 0}'::jsonb, 1.00, 'attach_rows', 30, 'secretariat',
     $f$UPDATE app.memberships SET revoked_at = now()
         WHERE role_key = 'ciso' AND revoked_at IS NULL$f$),

    -- Has the policy body drifted from the standard?
    -- Design doc 1.6 states "differences from the standard are recorded as deviations".
    -- If only the body is rewritten without registering a deviation, it looks compliant with the standard but the content differs.
    -- Note: matching against deviations (app.deviations) is not in yet. This only detects the difference.
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

-- Link to related controls. The control catalog is IPO-KARTE only, so
-- link only those whose corresponding requirement can be identified (do not force-link everything).
INSERT INTO catalog.check_controls (check_key, control_id)
SELECT 'CHK-CORE-POLICY-001', c.id
  FROM catalog.controls c
 WHERE c.framework_key = 'IPO-KARTE' AND c.theme LIKE '%規程%' AND c.retired_at IS NULL
 LIMIT 1
ON CONFLICT DO NOTHING;

-- Verify the number inserted. Pinned here so any increase or decrease is noticed.
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
