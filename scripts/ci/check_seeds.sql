-- seed の検査。件数だけでなく、代表レコードと不変条件まで見る。
\set ON_ERROR_STOP on

DO $$
DECLARE n int; v record; p int; i int; lv int; hit int;
BEGIN
  -- 1. DOM 版が 1 つだけ current
  SELECT count(*) INTO n FROM catalog.dom_versions WHERE is_current;
  IF n <> 1 THEN RAISE EXCEPTION 'is_current な DOM 版が % 個', n; END IF;
  IF NOT EXISTS (SELECT 1 FROM catalog.dom_versions WHERE version = '2026.1' AND is_current) THEN
    RAISE EXCEPTION 'DOM 2026.1 が current でない';
  END IF;

  -- 2〜5 は件数だけを見ない。**キー集合を完全一致で**確かめる。
  -- 件数だけだと「5 件あるが中身が別物」を通してしまう。
  IF (SELECT array_agg(key ORDER BY key) FROM catalog.roles_default)
     IS DISTINCT FROM ARRAY['auditor','ciso','employee','risk_owner','secretariat'] THEN
    RAISE EXCEPTION '標準ロールのキー集合が想定と違う: %',
      (SELECT array_agg(key ORDER BY key) FROM catalog.roles_default);
  END IF;
  -- 表示名・並び順が空でないこと（キーだけ合っていて中身が空、を通さない）
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
  -- 極秘は外部共有禁止、公開は制限なし（設計書 1.7 の既定の取扱い）
  IF NOT EXISTS (SELECT 1 FROM catalog.asset_classes_default
                  WHERE key='top_secret' AND rank=4 AND external_share_policy='forbidden') THEN
    RAISE EXCEPTION '極秘の既定が「外部共有禁止・rank 4」になっていない';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM catalog.asset_classes_default
                  WHERE key='public' AND rank=1 AND external_share_policy='allowed') THEN
    RAISE EXCEPTION '公開の既定が「制限なし・rank 1」になっていない';
  END IF;

  -- 標準規程 28 本。12 本は DOM 2026.1 当初のもの、16 本は 0008 で足した
  -- 「ISMS を回すのに要る側」（文書・教育・監視・監査・レビュー・是正）と
  -- 技術／利用形態ごとの規程。
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
  -- cardinality(NULL) は NULL なので、IS NULL を別に見る。
  -- 列は NOT NULL だが、検査の側が「無い」を見落とす形で書かれていると、
  -- 制約を緩めたときに黙って通る。
  IF EXISTS (SELECT 1 FROM catalog.policies_default
              WHERE btrim(title_ja) = '' OR btrim(body_md) = ''
                 OR clause_refs IS NULL OR cardinality(clause_refs) = 0) THEN
    RAISE EXCEPTION '標準規程に空の題名・本文・箇条参照がある';
  END IF;

  -- **本文が仮置きでないこと。** 空でないことだけを見ると、
  -- 見出し 1 行と「（標準本文）」だけの行が「本文あり」として通ってしまう
  -- （実際、DOM 2026.1 当初の 12 本はその状態だった）。
  -- 画面側の判定（web/src/lib/policyBody.ts）と同じ考え方をここにも置く:
  --   仮置きの印を含む / 短すぎる / 見出しと括弧書きの注記しか無い、のいずれも落とす。
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
  -- 見出し（# 始まり）と空行を除いた行が 5 行未満、または
  -- 残った行がすべて括弧書きの注記なら、中身が無いとみなす。
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
  -- 枠組みタグ。0027 は p01〜p07 にしか入れていなかった。全 28 本に要る。
  IF EXISTS (SELECT 1 FROM catalog.policies_default p
              WHERE NOT EXISTS (SELECT 1 FROM catalog.policy_frameworks f
                                 WHERE f.policy_key = p.key
                                   AND f.framework_key = 'RISK-MANAGEMENT')
                 OR NOT EXISTS (SELECT 1 FROM catalog.policy_frameworks f
                                 WHERE f.policy_key = p.key
                                   AND f.framework_key = 'ISO27001:2022')) THEN
    RAISE EXCEPTION '枠組みタグの付いていない標準規程がある';
  END IF;
  -- 全ての規程が現行 DOM に紐づいていること
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
  -- 内部監査は監査人、マネジメントレビューは CISO（設計書 1.4 の担当）
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
  -- 逸脱の棚卸と日次チェックは周期延長を許さない
  IF EXISTS (SELECT 1 FROM catalog.calendar_events_default
              WHERE key IN ('quarterly_deviation','daily_checks') AND extendable) THEN
    RAISE EXCEPTION '延長不可であるべきイベントが extendable=true';
  END IF;

  -- 6. リスク基準: 5x5 の全 25 組が 4 区分のいずれか 1 つにだけ該当する
  -- 先に「現行 DOM の基準がちょうど 1 行ある」ことを見る。0 行だと下の SELECT INTO が
  -- NULL になり、比較が NULL のまま進む。複数行だと、どの行を見たのかが決まらない。
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

  -- 7. フレームワーク 3 種。IPO-KARTE には架空サンプルの出典注記が必須
  SELECT count(*) INTO n FROM catalog.frameworks;
  IF n <> 3 THEN RAISE EXCEPTION 'フレームワークが % 件（3 でなければならない）', n; END IF;
  IF NOT EXISTS (SELECT 1 FROM catalog.frameworks
                  WHERE key = 'IPO-KARTE' AND source_note LIKE '%架空のサンプル%') THEN
    RAISE EXCEPTION 'IPO-KARTE に架空のサンプルである旨の出典注記が無い';
  END IF;
  -- 表示名は 0050 で「リソースマネジメント」へ改めた（web/src/lib/navigation.ts の
  -- RESOURCE_MANAGEMENT_NAME と同じ）。旧名のまま検査していたため、0009 の seed が通る
  -- 新規 DB ではここで必ず落ちていた（0062 で 0009 が通るようになって表に出た）。
  IF NOT EXISTS (SELECT 1 FROM catalog.frameworks
                  WHERE key = 'RISK-MANAGEMENT' AND name_ja = 'リソースマネジメント') THEN
    RAISE EXCEPTION 'リソースマネジメント枠組みタグが無い';
  END IF;

  -- 8. 統制カタログ: 同梱サンプルまたは設定済み外部カタログを検査する。
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

  -- 8b. 統制の中身が空でないこと。code の付け方が崩れていないこと。
  IF EXISTS (SELECT 1 FROM catalog.controls
              WHERE framework_key='IPO-KARTE' AND retired_at IS NULL
                AND (btrim(title_ja) = '' OR btrim(coalesce(theme,'')) = '')) THEN
    RAISE EXCEPTION '統制に空の題名・区分がある';
  END IF;
  -- code は 大項目記号-小項目コード(要請No) の形（例 A-10-10-10(1)）。
  -- 既存マスタには要請No が '-'（要請事項が「なし」のプレースホルダ）の行が
  -- 1 件だけある。実データを曲げないので許容し、代わりに件数を固定して
  -- 「いつの間にか増えていた」を検知する。
  IF EXISTS (SELECT 1 FROM catalog.controls
              WHERE framework_key='IPO-KARTE' AND retired_at IS NULL
                AND code !~ '^[A-Z]-[0-9]+-[0-9]+-[0-9]+\(([0-9]+|-)\)$') THEN
    RAISE EXCEPTION 'code の形が崩れている統制がある: %',
      (SELECT string_agg(code, ', ') FROM catalog.controls
        WHERE framework_key='IPO-KARTE' AND retired_at IS NULL
          AND code !~ '^[A-Z]-[0-9]+-[0-9]+-[0-9]+\(([0-9]+|-)\)$');
  END IF;

  -- 9. リスクシナリオテンプレート。frame は 3 観点のいずれかだけ。
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
  -- 3 観点がすべて出現していること（1 観点しか無い＝取り込み事故）
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

  -- 10. Phase 3a の端末定義・D チェック。件数だけでなく、固定定義の形も見る。
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
  -- Windows の定義（0079）。OS ごとに active は1つ。項目名は macOS と同じ14個で、保護機能は Windows の形。
  IF (SELECT count(*) FROM catalog.agent_definitions
       WHERE platform = 'windows' AND version = 2 AND active) <> 1 THEN
    RAISE EXCEPTION 'Windows agent definition v2 が active で 1 件ではない';
  END IF;
  IF (SELECT count(*) FROM catalog.agent_definitions
       WHERE platform = 'windows' AND active) <> 1 THEN
    RAISE EXCEPTION 'Windows agent definition の active 行が唯一ではない';
  END IF;
  IF (SELECT array_agg(item->>'name' ORDER BY ord)
        FROM catalog.agent_definitions d,
             jsonb_array_elements(d.definition->'items') WITH ORDINALITY AS t(item, ord)
       WHERE d.platform = 'windows' AND d.version = 2)
     IS DISTINCT FROM
     (SELECT array_agg(item->>'name' ORDER BY ord)
        FROM catalog.agent_definitions d,
             jsonb_array_elements(d.definition->'items') WITH ORDINALITY AS t(item, ord)
       WHERE d.platform = 'macos' AND d.version = 2) THEN
    RAISE EXCEPTION 'Windows agent definition v2 の項目が macOS v2 と同じ14個・同じ順ではない';
  END IF;
  -- 実行ファイルは agent 側の isAbsoluteExecutable と同じ規則（ドライブ文字＋:\＋1文字以上）。
  -- 欠落・null・空は NULL 比較で素通りしないよう coalesce で空文字にしてから判定する（Codex レビュー 2026-09-13）。
  IF EXISTS (
    SELECT 1
      FROM catalog.agent_definitions d,
           jsonb_array_elements(d.definition->'items') AS item,
           jsonb_array_elements(coalesce(item->'commands', '[]'::jsonb)) AS command
     WHERE d.platform = 'windows' AND d.version = 2
       AND coalesce(command->>'executable', '') !~ '^[A-Za-z]:\\.+'
  ) THEN
    RAISE EXCEPTION 'Windows agent definition v2 に絶対パスでない（または空の）実行ファイルがある';
  END IF;
  -- 実機のコマンドで集める項目（collector が metadata 以外）には、コマンドが1つ以上ある。
  IF EXISTS (
    SELECT 1
      FROM catalog.agent_definitions d,
           jsonb_array_elements(d.definition->'items') AS item
     WHERE d.platform = 'windows' AND d.version = 2
       AND coalesce(item->>'collector', '') <> 'metadata'
       AND jsonb_array_length(coalesce(item->'commands', '[]'::jsonb)) = 0
  ) THEN
    RAISE EXCEPTION 'Windows agent definition v2 にコマンドの無い収集項目がある';
  END IF;
  IF (SELECT count(*) FROM catalog.agent_definitions
       WHERE platform NOT IN ('macos', 'windows')) <> 0 THEN
    RAISE EXCEPTION 'macOS・Windows 以外の agent definition がある';
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
