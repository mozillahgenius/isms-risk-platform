-- Seed checks. Look beyond counts: representative records and invariants too.
\set ON_ERROR_STOP on

DO $$
DECLARE n int; v record; p int; i int; lv int; hit int;
BEGIN
  -- 1. Exactly one DOM version is current
  SELECT count(*) INTO n FROM catalog.dom_versions WHERE is_current;
  IF n <> 1 THEN RAISE EXCEPTION 'is_current な DOM 版が % 個', n; END IF;
  IF NOT EXISTS (SELECT 1 FROM catalog.dom_versions WHERE version = '2026.1' AND is_current) THEN
    RAISE EXCEPTION 'DOM 2026.1 が current でない';
  END IF;

  -- 2-5 don't look at counts only. Verify the **key sets match exactly**.
  -- Counts alone would pass "there are 5 rows but the contents are something else".
  IF (SELECT array_agg(key ORDER BY key) FROM catalog.roles_default)
     IS DISTINCT FROM ARRAY['auditor','ciso','employee','risk_owner','secretariat'] THEN
    RAISE EXCEPTION '標準ロールのキー集合が想定と違う: %',
      (SELECT array_agg(key ORDER BY key) FROM catalog.roles_default);
  END IF;
  -- Display names and sort orders are not empty (don't pass "keys match but contents are empty")
  IF EXISTS (SELECT 1 FROM catalog.roles_default
              WHERE btrim(name_ja) = '' OR btrim(description) = '' OR sort_order IS NULL) THEN
    RAISE EXCEPTION '標準ロールに空の名称・説明・並び順がある';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM catalog.roles_default WHERE key = 'ciso' AND name_ja = '経営責任者')
     OR NOT EXISTS (SELECT 1 FROM catalog.roles_default WHERE key = 'secretariat' AND name_ja = '事務局') THEN
    RAISE EXCEPTION '経営責任者・事務局の表示名が想定と違う';
  END IF;

  IF (SELECT array_agg(key ORDER BY key) FROM catalog.asset_classes_default)
     IS DISTINCT FROM ARRAY['confidential','internal','public','top_secret'] THEN
    RAISE EXCEPTION '標準資産分類のキー集合が想定と違う';
  END IF;
  IF (SELECT array_agg(rank ORDER BY rank) FROM catalog.asset_classes_default)
     IS DISTINCT FROM ARRAY[1,2,3,4]::smallint[] THEN
    RAISE EXCEPTION '資産分類の rank が 1..4 を過不足なく覆っていない';
  END IF;
  -- Top secret: no external sharing; public: unrestricted (default handling per design doc 1.7)
  IF NOT EXISTS (SELECT 1 FROM catalog.asset_classes_default
                  WHERE key='top_secret' AND rank=4 AND external_share_policy='forbidden') THEN
    RAISE EXCEPTION '極秘の既定が「外部共有禁止・rank 4」になっていない';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM catalog.asset_classes_default
                  WHERE key='public' AND rank=1 AND external_share_policy='allowed') THEN
    RAISE EXCEPTION '公開の既定が「制限なし・rank 1」になっていない';
  END IF;

  -- 28 standard policies. 12 are from the original DOM 2026.1; 16 were added in 0008:
  -- the "needed to run an ISMS" side (documents, training, monitoring, audit, review, corrective action) and
  -- policies per technology / usage pattern.
  IF (SELECT array_agg(key ORDER BY key) FROM catalog.policies_default)
     IS DISTINCT FROM ARRAY['p01_basic','p02_scope','p03_org','p04_ra','p05_rt_soa',
                            'p06_asset','p07_access','p08_people','p09_physical',
                            'p10_technical','p11_vendor','p12_incident',
                            'p13_docs','p14_awareness','p15_monitor','p16_audit',
                            'p17_review','p18_nc','p19_change','p20_crypto',
                            'p21_log','p22_vuln','p23_dev','p24_cloud',
                            'p25_remote','p26_privacy','p27_legal','p28_ai'] THEN
    RAISE EXCEPTION '標準規程 28 本のキー集合が想定と違う: %',
      (SELECT array_agg(key ORDER BY key) FROM catalog.policies_default);
  END IF;
  -- cardinality(NULL) is NULL, so check IS NULL separately.
  -- The column is NOT NULL, but if the check is written in a way that misses "absent",
  -- it silently passes when the constraint is relaxed.
  IF EXISTS (SELECT 1 FROM catalog.policies_default
              WHERE btrim(title_ja) = '' OR btrim(body_md) = ''
                 OR clause_refs IS NULL OR cardinality(clause_refs) = 0) THEN
    RAISE EXCEPTION '標準規程に空の題名・本文・箇条参照がある';
  END IF;

  -- **Bodies must not be placeholders.** Checking only for non-empty would let
  -- rows with just one heading line and the "(standard body)" placeholder pass as "has a body"
  -- (in fact, the original 12 in DOM 2026.1 were in that state).
  -- Apply the same idea here as the UI-side check (web/src/lib/policyBody.ts):
  --   fail if it contains a placeholder marker / is too short / has only headings and parenthetical notes.
  IF EXISTS (SELECT 1 FROM catalog.policies_default WHERE body_md LIKE '%（標準本文%') THEN
    RAISE EXCEPTION '仮置きの印（標準本文）が残っている規程がある: %',
      (SELECT string_agg(key, ', ' ORDER BY key) FROM catalog.policies_default
        WHERE body_md LIKE '%（標準本文%');
  END IF;
  IF EXISTS (SELECT 1 FROM catalog.policies_default WHERE length(body_md) < 400) THEN
    RAISE EXCEPTION '本文が短すぎる規程がある（400 字未満）: %',
      (SELECT string_agg(key || '=' || length(body_md), ', ' ORDER BY key)
         FROM catalog.policies_default WHERE length(body_md) < 400);
  END IF;
  -- If fewer than 5 lines remain after excluding headings (starting with #) and blank lines, or
  -- all remaining lines are parenthetical notes, treat it as having no content.
  IF EXISTS (
    SELECT 1 FROM catalog.policies_default p
     CROSS JOIN LATERAL (
       SELECT array_agg(l) AS rest
         FROM unnest(string_to_array(p.body_md, E'\n')) AS l
        WHERE btrim(l) <> '' AND left(btrim(l), 1) <> '#'
     ) x
     WHERE x.rest IS NULL
        OR cardinality(x.rest) < 5
        OR NOT EXISTS (SELECT 1 FROM unnest(x.rest) r
                        WHERE btrim(r) !~ '^[（(].*[）)]$')
  ) THEN
    RAISE EXCEPTION '見出しと注記しか無い規程がある: %',
      (SELECT string_agg(p.key, ', ' ORDER BY p.key)
         FROM catalog.policies_default p
        CROSS JOIN LATERAL (
          SELECT array_agg(l) AS rest
            FROM unnest(string_to_array(p.body_md, E'\n')) AS l
           WHERE btrim(l) <> '' AND left(btrim(l), 1) <> '#'
        ) x
        WHERE x.rest IS NULL
           OR cardinality(x.rest) < 5
           OR NOT EXISTS (SELECT 1 FROM unnest(x.rest) r
                           WHERE btrim(r) !~ '^[（(].*[）)]$'));
  END IF;
  -- Framework tags. 0027 only populated p01-p07. All 28 need them.
  IF EXISTS (SELECT 1 FROM catalog.policies_default p
              WHERE NOT EXISTS (SELECT 1 FROM catalog.policy_frameworks f
                                 WHERE f.policy_key = p.key
                                   AND f.framework_key = 'RISK-MANAGEMENT')
                 OR NOT EXISTS (SELECT 1 FROM catalog.policy_frameworks f
                                 WHERE f.policy_key = p.key
                                   AND f.framework_key = 'ISO27001:2022')) THEN
    RAISE EXCEPTION '枠組みタグの付いていない標準規程がある';
  END IF;
  -- Every policy is linked to the current DOM
  IF EXISTS (SELECT 1 FROM catalog.policies_default p
              WHERE p.dom_version_id <> (SELECT id FROM catalog.dom_versions WHERE is_current)) THEN
    RAISE EXCEPTION '現行 DOM に紐づかない標準規程がある';
  END IF;

  IF (SELECT array_agg(key ORDER BY key) FROM catalog.calendar_events_default)
     IS DISTINCT FROM ARRAY['annual_audit','annual_review','annual_risk','annual_training',
                            'daily_checks','event_offboarding','event_onboarding',
                            'monthly_accounts','monthly_endpoints','quarterly_deviation',
                            'quarterly_restore','quarterly_sharing','semiannual_vendors',
                            'weekly_findings'] THEN
    RAISE EXCEPTION '標準カレンダーのキー集合が想定と違う';
  END IF;
  IF EXISTS (SELECT 1 FROM catalog.calendar_events_default
              WHERE btrim(name_ja) = '') THEN
    RAISE EXCEPTION '標準カレンダーに名称が空のイベントがある';
  END IF;
  -- Internal audit by the auditor, management review by the CISO (owners per design doc 1.4)
  IF NOT EXISTS (SELECT 1 FROM catalog.calendar_events_default
                  WHERE key='annual_audit' AND owner_role='auditor' AND cadence='annual') THEN
    RAISE EXCEPTION '内部監査の担当・周期が想定と違う';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM catalog.calendar_events_default
                  WHERE key='annual_review' AND owner_role='ciso' AND cadence='annual') THEN
    RAISE EXCEPTION 'マネジメントレビューの担当・周期が想定と違う';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM catalog.calendar_events_default
                  WHERE key = 'quarterly_restore' AND cadence = 'quarterly') THEN
    RAISE EXCEPTION 'バックアップ復元演習が四半期で登録されていない（受入 #16）';
  END IF;
  -- Deviation inventory and daily checks do not allow cycle extension
  IF EXISTS (SELECT 1 FROM catalog.calendar_events_default
              WHERE key IN ('quarterly_deviation','daily_checks') AND extendable) THEN
    RAISE EXCEPTION '延長不可であるべきイベントが extendable=true';
  END IF;

  -- 6. Risk criteria: each of the 25 cells of the 5x5 falls into exactly one of the 4 bands
  -- First check that "there is exactly one criteria row for the current DOM". With 0 rows the SELECT INTO below
  -- yields NULL and comparisons proceed as NULL. With multiple rows, which row was checked is undefined.
  SELECT count(*) INTO n FROM catalog.risk_criteria_default d
    JOIN catalog.dom_versions ver ON ver.id = d.dom_version_id AND ver.is_current;
  IF n <> 1 THEN
    RAISE EXCEPTION '現行 DOM のリスク基準が % 行（1 行でなければならない）', n;
  END IF;
  SELECT * INTO v FROM catalog.risk_criteria_default d
    JOIN catalog.dom_versions ver ON ver.id = d.dom_version_id AND ver.is_current;
  FOR p IN 1..5 LOOP FOR i IN 1..5 LOOP
    lv := p * i;
    hit := (CASE WHEN lv = ANY(v.band_top_priority) THEN 1 ELSE 0 END)
         + (CASE WHEN lv = ANY(v.band_action)       THEN 1 ELSE 0 END)
         + (CASE WHEN lv = ANY(v.band_consider)     THEN 1 ELSE 0 END)
         + (CASE WHEN lv = ANY(v.band_accept)       THEN 1 ELSE 0 END);
    IF hit <> 1 THEN
      RAISE EXCEPTION '発生可能性=% 影響度=% (レベル %) が % 個の区分に該当', p, i, lv, hit;
    END IF;
  END LOOP; END LOOP;
  IF v.impact_sec_formula <> 'max_cia' THEN
    RAISE EXCEPTION '既定の算定式が max_cia でない: %', v.impact_sec_formula;
  END IF;

  -- 7. Three frameworks. IPO-KARTE requires a source note stating it is a "fictional sample"
  SELECT count(*) INTO n FROM catalog.frameworks;
  IF n <> 3 THEN RAISE EXCEPTION 'フレームワークが % 件（3 でなければならない）', n; END IF;
  IF NOT EXISTS (SELECT 1 FROM catalog.frameworks
                  WHERE key = 'IPO-KARTE' AND source_note LIKE '%架空のサンプル%') THEN
    RAISE EXCEPTION 'IPO-KARTE に架空のサンプルである旨の出典注記が無い';
  END IF;
  -- The display name was changed to "Resource Management" in 0050 (same as RESOURCE_MANAGEMENT_NAME in
  -- web/src/lib/navigation.ts). The check still used the old name, so on a fresh DB where the 0009 seed
  -- passes it always failed here (surfaced once 0009 started passing in 0062).
  IF NOT EXISTS (SELECT 1 FROM catalog.frameworks
                  WHERE key = 'RISK-MANAGEMENT' AND name_ja = 'リソースマネジメント') THEN
    RAISE EXCEPTION 'リソースマネジメント枠組みタグが無い';
  END IF;

  -- 8. Control catalog (CSV loaded by load_csv.py). The count depends on the CSV, so it is not fixed.
  --    Check it is non-empty and every row has a framework tag.
  --    Matching the CSV row count is verified by scripts/ci/run.sh, which counts the CSV.
  SELECT count(*) INTO n FROM catalog.controls
   WHERE framework_key = 'IPO-KARTE' AND retired_at IS NULL;
  IF n = 0 THEN
    RAISE EXCEPTION 'IPO-KARTE の統制が 0 件（load_csv.py を先に流すこと）';
  END IF;
  IF EXISTS (SELECT 1 FROM catalog.controls c
              WHERE c.framework_key = 'IPO-KARTE' AND c.retired_at IS NULL
                AND NOT EXISTS (SELECT 1 FROM catalog.control_frameworks f
                                 WHERE f.control_id = c.id AND f.framework_key = 'IPO-KARTE')) THEN
    RAISE EXCEPTION 'IPO-KARTE の枠組みタグが付いていない統制がある';
  END IF;

  -- 8b. Control contents are not empty, and the code format is intact.
  IF EXISTS (SELECT 1 FROM catalog.controls
              WHERE framework_key='IPO-KARTE' AND retired_at IS NULL
                AND (btrim(title_ja) = '' OR btrim(coalesce(theme,'')) = '')) THEN
    RAISE EXCEPTION '統制に空の題名・区分がある';
  END IF;
  -- code has the form <category symbol>-<subitem code>(<requirement No>) (e.g. S-10-10-10(1)).
  -- Some catalogs have rows whose requirement No is '-' (placeholder for "no requirement"),
  -- so that form is accepted too.
  IF EXISTS (SELECT 1 FROM catalog.controls
              WHERE framework_key='IPO-KARTE' AND retired_at IS NULL
                AND code !~ '^[A-Z]-[0-9]+-[0-9]+-[0-9]+\(([0-9]+|-)\)$') THEN
    RAISE EXCEPTION 'code の形が崩れている統制がある: %',
      (SELECT string_agg(code, ', ') FROM catalog.controls
        WHERE framework_key='IPO-KARTE' AND retired_at IS NULL
          AND code !~ '^[A-Z]-[0-9]+-[0-9]+-[0-9]+\(([0-9]+|-)\)$');
  END IF;

  -- 9. Risk scenario templates. frame must be one of the 3 perspectives.
  SELECT count(*) INTO n FROM catalog.risk_scenario_templates WHERE retired_at IS NULL;
  IF n = 0 THEN RAISE EXCEPTION 'risk_scenario_templates が空'; END IF;
  IF EXISTS (SELECT 1 FROM catalog.risk_scenario_templates
              WHERE frame NOT IN ('管理可能性','精度','スピード')) THEN
    RAISE EXCEPTION 'テンプレートに 3 観点以外の frame がある';
  END IF;
  IF EXISTS (SELECT 1 FROM catalog.risk_scenario_templates
              WHERE retired_at IS NULL
                AND (btrim(domain) = '' OR btrim(theme) = '' OR btrim(measure) = ''
                  OR btrim(summary) = '' OR btrim(default_action) = '')) THEN
    RAISE EXCEPTION 'テンプレートに空の必須項目がある';
  END IF;
  -- All 3 perspectives appear (only 1 perspective = an import accident)
  IF (SELECT count(DISTINCT frame) FROM catalog.risk_scenario_templates
       WHERE retired_at IS NULL) <> 3 THEN
    RAISE EXCEPTION 'テンプレートに 3 観点が揃っていない';
  END IF;
  IF EXISTS (SELECT 1 FROM catalog.risk_scenario_templates
              WHERE retired_at IS NULL AND (phase < 1 OR phase > 5)) THEN
    RAISE EXCEPTION 'テンプレートの Phase が 1..5 の範囲外';
  END IF;
  IF (SELECT count(*) FROM catalog.risk_template_frameworks
       WHERE framework_key = 'RISK-MANAGEMENT')
     <> (SELECT count(*) FROM catalog.risk_scenario_templates WHERE retired_at IS NULL) THEN
    RAISE EXCEPTION 'リスク雛形のリスクマネジメントタグが全件そろっていない';
  END IF;

  -- 10. Phase 3a device definitions and D checks. Check not only counts but also the shape of the fixed definitions.
  IF (SELECT count(*) FROM catalog.agent_definitions
       WHERE platform = 'macos' AND version = 2 AND active) <> 1 THEN
    RAISE EXCEPTION 'macOS agent definition v2 が active で 1 件ではない';
  END IF;
  IF (SELECT count(*) FROM catalog.agent_definitions
       WHERE platform = 'macos' AND version = 1 AND NOT active) <> 1 THEN
    RAISE EXCEPTION 'macOS agent definition v1 の rollback 用 inactive 行が 1 件ではない';
  END IF;
  IF (SELECT count(*) FROM catalog.agent_definitions
       WHERE platform = 'macos' AND active) <> 1 THEN
    RAISE EXCEPTION 'macOS agent definition の active 行が唯一ではない';
  END IF;
  IF (SELECT jsonb_array_length(definition->'items') FROM catalog.agent_definitions
       WHERE platform = 'macos' AND version = 2) <> 14 THEN
    RAISE EXCEPTION 'macOS agent definition v2 の項目数が 14 ではない';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM catalog.agent_definitions d,
           jsonb_array_elements(d.definition->'items') AS item
     WHERE d.platform = 'macos' AND d.version = 2
       AND coalesce(item->>'collector', '') = ''
  ) THEN
    RAISE EXCEPTION 'macOS agent definition v2 に collector 未指定の項目がある';
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM catalog.agent_definitions d,
           jsonb_array_elements(d.definition->'items') AS item
     WHERE d.platform = 'macos' AND d.version = 2
       AND item->>'name' = 'unapproved_apps'
       AND item->'location_prefixes' = '["/Applications"]'::jsonb
       AND item->'excluded_location_prefixes' = '["/System/Applications", "~/Applications"]'::jsonb
       AND item->>'location_depth' = '1'
       AND item->>'application_inventory' = 'system_profiler_and_directory'
       AND item->>'include_hidden_bundles' = 'true'
  ) THEN
    RAISE EXCEPTION 'unapproved_apps の母集団・突合・隠しバンドル定義が不正';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM catalog.agent_definitions d,
           jsonb_array_elements(d.definition->'items') AS item
     WHERE d.platform = 'macos' AND d.version = 2
       AND item->>'name' = 'admin_account_count'
       AND item->'admin_exclusions'->'names' ? 'remoteaccess'
  ) THEN
    RAISE EXCEPTION 'admin_account_count が実在ユーザー remoteaccess を除外している';
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM catalog.agent_definitions d,
           jsonb_array_elements(d.definition->'items') AS item
     WHERE d.platform = 'macos' AND d.version = 2
       AND item->>'name' = 'builtin_protection'
       AND jsonb_array_length(item->'commands') = 6
       AND item->>'output' = 'stdout'
       AND item->>'kind' = 'builtin_protection'
  ) OR NOT EXISTS (
    SELECT 1
      FROM catalog.agent_definitions d,
           jsonb_array_elements(d.definition->'items') AS item
     WHERE d.platform = 'macos' AND d.version = 2
       AND item->>'name' = 'edr_vendor'
       AND item->>'kind' = 'edr_vendor'
  ) THEN
    RAISE EXCEPTION 'XProtect/EDR vendor の定義項目が不正';
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM catalog.agent_definitions d,
           jsonb_array_elements(d.definition->'items') AS item
     WHERE d.platform = 'macos' AND d.version = 2
       AND item->>'name' = 'builtin_protection'
       AND item->'promotes_to' = '["edr_running"]'::jsonb
  ) THEN
    RAISE EXCEPTION 'builtin_protection の edr_running 昇格関係が定義されていない';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM catalog.checks
     WHERE key = ANY(ARRAY[
       'CHK-ENDPOINT-001', 'CHK-ENDPOINT-002', 'CHK-ENDPOINT-003',
       'CHK-ENDPOINT-004', 'CHK-ENDPOINT-005', 'CHK-ENDPOINT-006',
       'CHK-ENDPOINT-007', 'CHK-ENDPOINT-008', 'CHK-ENDPOINT-009'
     ])
       AND (
         query_sql NOT LIKE '%DISTINCT ON (device_id)%'
         OR query_sql NOT LIKE '%ORDER BY device_id, collected_at DESC, id DESC%'
       )
  ) THEN
    RAISE EXCEPTION 'snapshot checks must evaluate the latest snapshot per device with a deterministic descending order';
  END IF;
  SELECT count(*) INTO n FROM catalog.checks WHERE key LIKE 'CHK-ENDPOINT-%';
  IF n <> 10 THEN
    RAISE EXCEPTION 'Phase 3a の D チェックが % 本（10 本でなければならない）', n;
  END IF;

  RAISE NOTICE 'check_seeds: OK（Phase 3a D チェック % 本）', n;
END $$;
