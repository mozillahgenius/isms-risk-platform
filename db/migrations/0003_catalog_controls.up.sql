-- 0003 catalog: 統制カタログとチェックカタログ（設計書 2.4 後半 / 2.9 前半）
-- frameworks → controls → framework_mappings
--   → risk_scenario_templates → risk_template_controls → checks → check_controls

CREATE TABLE catalog.frameworks (
  key        text PRIMARY KEY,                     -- 'ISO27001:2022','IPO-KARTE'（旧版はseedで廃止）
  name_ja    text NOT NULL,
  version    text NOT NULL,
  source_note text                                 -- 出典（独自マスタである旨など）
);

CREATE TABLE catalog.controls (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  framework_key text NOT NULL REFERENCES catalog.frameworks(key),
  code         text NOT NULL,                      -- 'A.5.10' / 'A-30-10-10(3)'
  title_ja     text NOT NULL,
  theme        text,                               -- 組織的/人的/物理的/技術的
  guidance_md  text,
  -- 再同期で「入力から消えた統制」を検知するための世代印（設計書に無い追加。
  -- ON CONFLICT DO UPDATE だけでは旧行が残るという Codex 指摘への対応）
  retired_at   timestamptz,
  UNIQUE (framework_key, code)
);

CREATE TABLE catalog.framework_mappings (
  from_control_id uuid NOT NULL REFERENCES catalog.controls(id),
  to_control_id   uuid NOT NULL REFERENCES catalog.controls(id),
  relation        text NOT NULL DEFAULT 'equivalent'
                    CHECK (relation IN ('equivalent','broader','narrower','related')),
  PRIMARY KEY (from_control_id, to_control_id),
  CHECK (from_control_id <> to_control_id)
);

CREATE TABLE catalog.risk_scenario_templates (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  domain        text NOT NULL,                     -- 機能領域（経理・税務 等）
  theme         text NOT NULL,                     -- 課題テーマ
  measure       text NOT NULL,                     -- 施策
  frame         text NOT NULL
                  CHECK (frame IN ('管理可能性','精度','スピード')),
  summary       text NOT NULL,                     -- リスク要約
  default_action text NOT NULL,                    -- 標準対応策
  industry_presets text[] NOT NULL DEFAULT '{general}',
  retired_at    timestamptz,
  -- 再投入を冪等にするための自然キー（設計書に無い追加。seed の冪等性要件）
  UNIQUE (domain, theme, measure, frame, summary)
);

CREATE TABLE catalog.risk_template_controls (
  template_id uuid NOT NULL REFERENCES catalog.risk_scenario_templates(id),
  control_id  uuid NOT NULL REFERENCES catalog.controls(id),
  PRIMARY KEY (template_id, control_id)
);

-- チェックカタログ（設計書 2.9 / 6.1）
CREATE TABLE catalog.checks (
  key            text PRIMARY KEY,                  -- 'CHK-SHARE-001'
  dom_version_id uuid NOT NULL REFERENCES catalog.dom_versions(id),
  title_ja       text NOT NULL,
  severity       text NOT NULL CHECK (severity IN ('critical','high','medium','low')),
  cadence        text NOT NULL CHECK (cadence IN ('daily','weekly','monthly','quarterly')),
  connectors     text[] NOT NULL,                   -- 必要な接続
  query_sql      text NOT NULL,
  expect         jsonb NOT NULL,                    -- {"rows":0}
  coverage_required numeric(3,2) NOT NULL DEFAULT 0.95,
  evidence_mode  text NOT NULL DEFAULT 'attach_rows',
  due_days       smallint NOT NULL DEFAULT 7,
  assign_to      text NOT NULL,                     -- resource_owner / role:secretariat 等
  negative_fixture text NOT NULL                    -- 逆向き検証のフィクスチャ（必須）
);

CREATE TABLE catalog.check_controls (
  check_key  text NOT NULL REFERENCES catalog.checks(key),
  control_id uuid NOT NULL REFERENCES catalog.controls(id),
  PRIMARY KEY (check_key, control_id)
);
