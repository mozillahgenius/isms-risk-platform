-- Standard operating model DOM 2026.1 (design doc Part I)
-- Idempotent. Running it any number of times does not increase row counts (fixed UUIDs / natural keys + ON CONFLICT DO UPDATE).

BEGIN;
SELECT pg_advisory_xact_lock(8891234501);
SET ROLE schema_owner;

-- 1. DOM version --------------------------------------------------------------
INSERT INTO catalog.dom_versions (id, version, released_at, changelog, is_current)
VALUES ('00000000-0000-0000-0000-000000002026', '2026.1',
        timestamptz '2026-08-13 00:00:00+09',
        '初版。標準ロール5・資産分類4・リスク基準5x5・年間カレンダー14・標準規程12。', true)
ON CONFLICT (version) DO UPDATE
  SET changelog = EXCLUDED.changelog, is_current = EXCLUDED.is_current;

-- 2. Standard roles (5. Do not add more. design doc 1.3) ----------------------
INSERT INTO catalog.roles_default (key, name_ja, description, sort_order) VALUES
 ('ciso',        '経営責任者', '受容判断、例外・逸脱の承認、マネジメントレビューの主宰', 1),
 ('secretariat', '事務局', '日々の運用。リスク・統制・証跡・是正の管理、コネクタ設定', 2),
 ('risk_owner',  'リスクオーナー', '自部門のリスクと是正処置の実行', 3),
 ('auditor',     '監査人', '内部監査の計画・実施・記録。業務データは変更できない', 4),
 ('employee',    '従業員', '規程の閲覧同意、教育受講、自端末の状態確認', 5)
ON CONFLICT (key) DO UPDATE
  SET name_ja = EXCLUDED.name_ja, description = EXCLUDED.description,
      sort_order = EXCLUDED.sort_order;

-- 3. Standard asset classes (4 categories. Immutable. design doc 1.7) ---------
INSERT INTO catalog.asset_classes_default (key, name_ja, rank, external_share_policy) VALUES
 ('top_secret',   '極秘',     4, 'forbidden'),
 ('confidential', '機密',     3, 'approval_required'),
 ('internal',     '社内限定', 2, 'approval_required'),
 ('public',       '公開',     1, 'allowed')
ON CONFLICT (key) DO UPDATE
  SET name_ja = EXCLUDED.name_ja, rank = EXCLUDED.rank,
      external_share_policy = EXCLUDED.external_share_policy;

-- 4. Standard risk criteria (design doc 1.5) ----------------------------------
--    Holds the 14 values reachable on a 5x5 grid as a set. Structurally removes ambiguity in boundary interpretation.
INSERT INTO catalog.risk_criteria_default
  (dom_version_id, impact_sec_formula,
   band_top_priority, band_action, band_consider, band_accept,
   due_days_top_priority, due_days_action)
VALUES ('00000000-0000-0000-0000-000000002026', 'max_cia',
        '{15,16,20,25}', '{8,9,10,12}', '{3,4,5,6}', '{1,2}', 30, 90)
ON CONFLICT (dom_version_id) DO UPDATE
  SET impact_sec_formula = EXCLUDED.impact_sec_formula,
      band_top_priority  = EXCLUDED.band_top_priority,
      band_action        = EXCLUDED.band_action,
      band_consider      = EXCLUDED.band_consider,
      band_accept        = EXCLUDED.band_accept;

-- 5. Standard annual calendar (design doc 1.4) --------------------------------
--    offset_months is the number of months from the start of the fiscal year. The start month is a tenant setting (default April).
INSERT INTO catalog.calendar_events_default
  (key, name_ja, cadence, offset_months, owner_role, clause_ref, extendable) VALUES
 ('daily_checks',        '自動チェックの実行・ドリフト通知', 'daily',      NULL, 'secretariat', '9.1',  false),
 ('weekly_findings',     '未対応の指摘レビュー・期限超過の督促', 'weekly',   NULL, 'secretariat', '10.2', true),
 ('monthly_accounts',    'アカウント棚卸（HR 突合の確認）', 'monthly',      NULL, 'secretariat', 'A.5.18', true),
 ('monthly_endpoints',   '端末ポスチャの未達一覧確認', 'monthly',           NULL, 'secretariat', 'A.8.1',  true),
 ('quarterly_sharing',   '外部公開文書の棚卸', 'quarterly',                  0,   'secretariat', 'A.5.10', true),
 ('quarterly_deviation', '逸脱の棚卸（期限切れ・再承認）', 'quarterly',      0,   'ciso',        '1.11',   false),
 ('quarterly_restore',   'バックアップ復元演習', 'quarterly',                0,   'secretariat', 'A.5.29', true),
 ('semiannual_vendors',  '委託先評価の更新', 'semiannual',                   0,   'secretariat', 'A.5.19', true),
 ('annual_risk',         'リスクアセスメントの見直し', 'annual',             0,   'secretariat', '8.2',    true),
 ('annual_audit',        '内部監査', 'annual',                               2,   'auditor',     '9.2',    true),
 ('annual_review',       'マネジメントレビュー', 'annual',                   3,   'ciso',        '9.3',    true),
 ('annual_training',     '情報セキュリティ教育', 'annual',                   0,   'secretariat', '7.2',    true),
 ('event_onboarding',    '入社時（規程同意・端末登録・教育）', 'event',      NULL, 'employee',    '6.3',    false),
 ('event_offboarding',   '退職時（アカウント停止・資産返却・権限剥奪の検証）', 'event', NULL, 'secretariat', 'A.5.11', false)
ON CONFLICT (key) DO UPDATE
  SET name_ja = EXCLUDED.name_ja, cadence = EXCLUDED.cadence,
      offset_months = EXCLUDED.offset_months, owner_role = EXCLUDED.owner_role,
      clause_ref = EXCLUDED.clause_ref, extendable = EXCLUDED.extendable;

-- 6. Standard document set (12 policies. design doc 1.8) ----------------------
--    body_md is an outline only. Fleshing out the text is separate Phase 1 work.
INSERT INTO catalog.policies_default (key, dom_version_id, title_ja, body_md, clause_refs, sort_order) VALUES
 ('p01_basic',    '00000000-0000-0000-0000-000000002026', '情報セキュリティ基本方針',
  E'# 情報セキュリティ基本方針\n\n（標準本文。差分を持つと逸脱として記録される）', '{5.2}', 1),
 ('p02_scope',    '00000000-0000-0000-0000-000000002026', 'ISMS 適用範囲',
  E'# ISMS 適用範囲\n\n（標準本文）', '{4.3}', 2),
 ('p03_org',      '00000000-0000-0000-0000-000000002026', '組織・役割・責任規程',
  E'# 組織・役割・責任規程\n\n（標準本文）', '{5.3,A.5.2}', 3),
 ('p04_ra',       '00000000-0000-0000-0000-000000002026', 'リスクアセスメント手順',
  E'# リスクアセスメント手順\n\n（標準本文）', '{6.1.2,8.2}', 4),
 ('p05_rt_soa',   '00000000-0000-0000-0000-000000002026', 'リスク対応手順・適用宣言書（SoA）',
  E'# リスク対応手順・適用宣言書\n\n（標準本文）', '{6.1.3,8.3}', 5),
 ('p06_asset',    '00000000-0000-0000-0000-000000002026', '情報資産管理規程（分類・取扱い）',
  E'# 情報資産管理規程\n\n（標準本文）', '{A.5.9,A.5.13}', 6),
 ('p07_access',   '00000000-0000-0000-0000-000000002026', 'アクセス制御規程',
  E'# アクセス制御規程\n\n（標準本文）', '{A.5.15,A.5.18}', 7),
 ('p08_people',   '00000000-0000-0000-0000-000000002026', '人的セキュリティ規程（入退社・教育）',
  E'# 人的セキュリティ規程\n\n（標準本文）', '{A.6.1,A.6.6}', 8),
 ('p09_physical', '00000000-0000-0000-0000-000000002026', '物理セキュリティ規程',
  E'# 物理セキュリティ規程\n\n（標準本文）', '{A.7.1,A.7.14}', 9),
 ('p10_technical','00000000-0000-0000-0000-000000002026', '技術的セキュリティ規程',
  E'# 技術的セキュリティ規程\n\n（標準本文）', '{A.8.1,A.8.34}', 10),
 ('p11_vendor',   '00000000-0000-0000-0000-000000002026', '委託先管理規程',
  E'# 委託先管理規程\n\n（標準本文）', '{A.5.19,A.5.23}', 11),
 ('p12_incident', '00000000-0000-0000-0000-000000002026', 'インシデント対応・事業継続規程',
  E'# インシデント対応・事業継続規程\n\n（標準本文）', '{A.5.24,A.5.30}', 12)
ON CONFLICT (key) DO UPDATE
  SET title_ja = EXCLUDED.title_ja, body_md = EXCLUDED.body_md,
      clause_refs = EXCLUDED.clause_refs, sort_order = EXCLUDED.sort_order;

-- 7. Frameworks (design doc 1.10) --------------------------------------------
INSERT INTO catalog.frameworks (key, name_ja, version, source_note) VALUES
 ('ISO27001:2022', 'ISO/IEC 27001:2022 附属書 A（Amd 1:2024 を含む）', '2022',
  '国際規格。統制の番号と名称は規格本文に従う。'),
 ('IPO-KARTE',     'サンプル統制チェックカルテ（架空）', '1',
  '同梱のサンプル統制カタログ用の枠組み。架空のサンプルであり、実在の基準・公的標準ではない。'
  '利用者は自組織の統制カタログを読み込んで置き換える。')
ON CONFLICT (key) DO UPDATE
  SET name_ja = EXCLUDED.name_ja, version = EXCLUDED.version,
      source_note = EXCLUDED.source_note;

RESET ROLE;
COMMIT;
