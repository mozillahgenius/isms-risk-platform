-- 0027: リスク台帳・資産/施策マスタ・枠組みタグ・評価履歴
-- 既存の catalog / app.risk_* を壊さず、運用台帳の登録面を追加する。

-- ---------------------------------------------------------------------------
-- 共有カタログ: 枠組みタグ
-- ---------------------------------------------------------------------------
INSERT INTO catalog.frameworks (key, name_ja, version, source_note)
VALUES (
  'RISK-MANAGEMENT',
  'リスクマネジメント＋ISMS',
  '1.0',
  '自社のリスク台帳・ISMS運用を横断して見るための枠組みタグ。規格本文ではない。'
)
ON CONFLICT (key) DO UPDATE
   SET name_ja = EXCLUDED.name_ja,
       version = EXCLUDED.version,
       source_note = EXCLUDED.source_note;

-- 既存のリスク雛形は domain に Phase を含めていた。Phase は独立列へ移し、
-- domain は領域名だけに正規化する。タイトルや要約には触れない。
ALTER TABLE catalog.risk_scenario_templates
  ADD COLUMN area text,
  ADD COLUMN phase smallint;

UPDATE catalog.risk_scenario_templates
   SET area = substring(domain FROM '^(.*)（Phase[1-5]）$'),
       phase = substring(domain FROM 'Phase([1-5])')::smallint
 WHERE domain ~ '^.*（Phase[1-5]）$';

UPDATE catalog.risk_scenario_templates
   SET domain = area
 WHERE area IS NOT NULL;

ALTER TABLE catalog.risk_scenario_templates
  ALTER COLUMN area SET NOT NULL,
  ALTER COLUMN phase SET NOT NULL,
  ADD CONSTRAINT risk_scenario_templates_phase_check CHECK (phase BETWEEN 1 AND 5);

ALTER TABLE catalog.risk_scenario_templates
  DROP CONSTRAINT IF EXISTS risk_scenario_templates_domain_theme_measure_frame_summary_key;
ALTER TABLE catalog.risk_scenario_templates
  ADD CONSTRAINT risk_scenario_templates_business_key
  UNIQUE (domain, phase, theme, measure, frame, summary);

-- 統制は従来 framework_key を単一値で持っていた。互いに重なる枠組みを
-- 表現できるタグ表を追加し、既存値を初期タグとして移す。
CREATE TABLE catalog.control_frameworks (
  control_id   uuid NOT NULL REFERENCES catalog.controls(id),
  framework_key text NOT NULL REFERENCES catalog.frameworks(key),
  PRIMARY KEY (control_id, framework_key)
);

INSERT INTO catalog.control_frameworks (control_id, framework_key)
SELECT id, framework_key FROM catalog.controls
ON CONFLICT DO NOTHING;

-- 既存の上場準備ルールは、リスクマネジメント画面でも再利用する。
-- ISO27001タグは、附属書 A の実データを捏造しないため付けない。
INSERT INTO catalog.control_frameworks (control_id, framework_key)
SELECT id, 'RISK-MANAGEMENT'
  FROM catalog.controls
 WHERE framework_key = 'IPO-KARTE'
ON CONFLICT DO NOTHING;

CREATE TABLE catalog.risk_template_frameworks (
  template_id   uuid NOT NULL REFERENCES catalog.risk_scenario_templates(id),
  framework_key text NOT NULL REFERENCES catalog.frameworks(key),
  PRIMARY KEY (template_id, framework_key)
);

INSERT INTO catalog.risk_template_frameworks (template_id, framework_key)
SELECT id, 'RISK-MANAGEMENT'
  FROM catalog.risk_scenario_templates
 WHERE retired_at IS NULL
ON CONFLICT DO NOTHING;

CREATE TABLE catalog.policy_frameworks (
  policy_key    text NOT NULL REFERENCES catalog.policies_default(key),
  framework_key text NOT NULL REFERENCES catalog.frameworks(key),
  PRIMARY KEY (policy_key, framework_key)
);

INSERT INTO catalog.policy_frameworks (policy_key, framework_key)
SELECT p.key, f.framework_key
  FROM catalog.policies_default p
 CROSS JOIN (VALUES ('RISK-MANAGEMENT'::text), ('ISO27001:2022'::text)) f(framework_key)
 WHERE p.key IN ('p01_basic','p02_scope','p03_org','p04_ra','p05_rt_soa','p06_asset','p07_access')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- テナント台帳: 資産 / 施策 / リスクと枠組みタグ
-- ---------------------------------------------------------------------------
CREATE TABLE app.assets (
  id                   uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL,
  asset_key            text NOT NULL,
  name                 text NOT NULL,
  asset_type           text NOT NULL,
  description          text NOT NULL DEFAULT '',
  classification       text NOT NULL REFERENCES catalog.asset_classes_default(key),
  owner_department_id  uuid,
  source_note          text NOT NULL DEFAULT '',
  status               text NOT NULL DEFAULT 'active'
                       CHECK (status IN ('active','retired')),
  created_at           timestamptz NOT NULL DEFAULT now(),
  created_by           uuid,
  updated_at           timestamptz NOT NULL DEFAULT now(),
  updated_by           uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, asset_key),
  FOREIGN KEY (tenant_id, owner_department_id)
    REFERENCES app.departments(tenant_id, id)
);

CREATE TABLE app.asset_frameworks (
  tenant_id    uuid NOT NULL,
  asset_id     uuid NOT NULL,
  framework_key text NOT NULL REFERENCES catalog.frameworks(key),
  PRIMARY KEY (tenant_id, asset_id, framework_key),
  FOREIGN KEY (tenant_id, asset_id) REFERENCES app.assets(tenant_id, id)
);

CREATE TABLE app.measures (
  id                   uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL,
  measure_key          text NOT NULL,
  name                 text NOT NULL,
  summary              text NOT NULL,
  strategy             text NOT NULL
                       CHECK (strategy IN ('mitigate','transfer','avoid','accept')),
  owner_department_id  uuid,
  status               text NOT NULL DEFAULT 'planned'
                       CHECK (status IN ('planned','in_progress','done','retired')),
  source_note          text NOT NULL DEFAULT '',
  created_at           timestamptz NOT NULL DEFAULT now(),
  created_by           uuid,
  updated_at           timestamptz NOT NULL DEFAULT now(),
  updated_by           uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, measure_key),
  FOREIGN KEY (tenant_id, owner_department_id)
    REFERENCES app.departments(tenant_id, id)
);

CREATE TABLE app.measure_frameworks (
  tenant_id    uuid NOT NULL,
  measure_id   uuid NOT NULL,
  framework_key text NOT NULL REFERENCES catalog.frameworks(key),
  PRIMARY KEY (tenant_id, measure_id, framework_key),
  FOREIGN KEY (tenant_id, measure_id) REFERENCES app.measures(tenant_id, id)
);

ALTER TABLE app.risk_scenarios
  ADD COLUMN area text NOT NULL DEFAULT '',
  ADD COLUMN phase smallint NOT NULL DEFAULT 1
             CHECK (phase BETWEEN 1 AND 5);

UPDATE app.risk_scenarios SET area = domain WHERE area = '';

CREATE TABLE app.risk_scenario_assets (
  tenant_id       uuid NOT NULL,
  risk_scenario_id uuid NOT NULL,
  asset_id        uuid NOT NULL,
  relation        text NOT NULL DEFAULT 'primary'
                  CHECK (relation IN ('primary','secondary','dependency')),
  PRIMARY KEY (tenant_id, risk_scenario_id, asset_id),
  FOREIGN KEY (tenant_id, risk_scenario_id)
    REFERENCES app.risk_scenarios(tenant_id, id),
  FOREIGN KEY (tenant_id, asset_id)
    REFERENCES app.assets(tenant_id, id)
);

CREATE TABLE app.risk_scenario_frameworks (
  tenant_id       uuid NOT NULL,
  risk_scenario_id uuid NOT NULL,
  framework_key   text NOT NULL REFERENCES catalog.frameworks(key),
  PRIMARY KEY (tenant_id, risk_scenario_id, framework_key),
  FOREIGN KEY (tenant_id, risk_scenario_id)
    REFERENCES app.risk_scenarios(tenant_id, id)
);

ALTER TABLE app.risk_treatments
  ADD COLUMN measure_id uuid;
ALTER TABLE app.risk_treatments
  ADD CONSTRAINT risk_treatments_measure_fk
  FOREIGN KEY (tenant_id, measure_id) REFERENCES app.measures(tenant_id, id);

-- リスクマップの時系列。既存 risk_assessments は監査用の基準版、こちらは
-- 画面で固有/施策前/施策後を比較する追記型の表示用スナップショット。
CREATE TABLE app.risk_evaluation_snapshots (
  id               uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL,
  risk_scenario_id uuid NOT NULL,
  measure_id       uuid,
  stage            text NOT NULL
                   CHECK (stage IN ('inherent','before_measure','after_measure')),
  assessed_on      date NOT NULL,
  probability      smallint NOT NULL CHECK (probability BETWEEN 1 AND 5),
  impact           smallint NOT NULL CHECK (impact BETWEEN 1 AND 5),
  risk_level       smallint GENERATED ALWAYS AS (probability * impact) STORED,
  rationale        text NOT NULL,
  source_note      text NOT NULL DEFAULT '',
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, risk_scenario_id)
    REFERENCES app.risk_scenarios(tenant_id, id),
  FOREIGN KEY (tenant_id, measure_id)
    REFERENCES app.measures(tenant_id, id),
  CHECK (stage = 'after_measure' OR measure_id IS NULL),
  CHECK (stage <> 'after_measure' OR measure_id IS NOT NULL)
);
CREATE INDEX risk_evaluation_snapshots_timeline
  ON app.risk_evaluation_snapshots (tenant_id, risk_scenario_id, assessed_on, created_at);

-- 新規 app テーブルは 0015 の一括処理より後に作られるため、ここで同じ
-- テナント分離を明示的に適用する。履歴は UPDATE/DELETE 不可。
DO $$
DECLARE
  t text;
  tables constant text[] := ARRAY[
    'assets','asset_frameworks','measures','measure_frameworks',
    'risk_scenario_assets','risk_scenario_frameworks','risk_evaluation_snapshots'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw
                    USING (tenant_id = app.current_tenant())
                    WITH CHECK (tenant_id = app.current_tenant())', t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro
                    USING (tenant_id = app.current_tenant())', t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC', t);
    IF t = 'risk_evaluation_snapshots' THEN
      EXECUTE format('GRANT SELECT, INSERT ON app.%I TO app_rw', t);
    ELSE
      EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON app.%I TO app_rw', t);
    END IF;
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro', t);
  END LOOP;
END $$;

REVOKE UPDATE, DELETE ON app.risk_evaluation_snapshots FROM app_rw;
