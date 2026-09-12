-- 0003 catalog: control catalog and check catalog (design doc 2.4 second half / 2.9 first half)
-- frameworks → controls → framework_mappings
--   → risk_scenario_templates → risk_template_controls → checks → check_controls

CREATE TABLE catalog.frameworks (
  key        text PRIMARY KEY,                     -- 'ISO27001:2022','IPO-KARTE' (old versions retired by seed)
  name_ja    text NOT NULL,
  version    text NOT NULL,
  source_note text                                 -- source (e.g. that it is a proprietary master)
);

CREATE TABLE catalog.controls (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  framework_key text NOT NULL REFERENCES catalog.frameworks(key),
  code         text NOT NULL,                      -- 'A.5.10' / 'A-30-10-10(3)'
  title_ja     text NOT NULL,
  theme        text,                               -- organizational/people/physical/technological
  guidance_md  text,
  -- Generation marker for detecting "controls that disappeared from the input" on resync (an addition not
  -- in the design doc; addresses the Codex finding that ON CONFLICT DO UPDATE alone leaves old rows behind)
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
  domain        text NOT NULL,                     -- functional area (accounting/tax etc.)
  theme         text NOT NULL,                     -- issue theme
  measure       text NOT NULL,                     -- measure
  frame         text NOT NULL
                  CHECK (frame IN ('管理可能性','精度','スピード')),
  summary       text NOT NULL,                     -- risk summary
  default_action text NOT NULL,                    -- standard response
  industry_presets text[] NOT NULL DEFAULT '{general}',
  retired_at    timestamptz,
  -- Natural key making reloads idempotent (an addition not in the design doc; seed idempotency requirement)
  UNIQUE (domain, theme, measure, frame, summary)
);

CREATE TABLE catalog.risk_template_controls (
  template_id uuid NOT NULL REFERENCES catalog.risk_scenario_templates(id),
  control_id  uuid NOT NULL REFERENCES catalog.controls(id),
  PRIMARY KEY (template_id, control_id)
);

-- Check catalog (design doc 2.9 / 6.1)
CREATE TABLE catalog.checks (
  key            text PRIMARY KEY,                  -- 'CHK-SHARE-001'
  dom_version_id uuid NOT NULL REFERENCES catalog.dom_versions(id),
  title_ja       text NOT NULL,
  severity       text NOT NULL CHECK (severity IN ('critical','high','medium','low')),
  cadence        text NOT NULL CHECK (cadence IN ('daily','weekly','monthly','quarterly')),
  connectors     text[] NOT NULL,                   -- required connectors
  query_sql      text NOT NULL,
  expect         jsonb NOT NULL,                    -- {"rows":0}
  coverage_required numeric(3,2) NOT NULL DEFAULT 0.95,
  evidence_mode  text NOT NULL DEFAULT 'attach_rows',
  due_days       smallint NOT NULL DEFAULT 7,
  assign_to      text NOT NULL,                     -- resource_owner / role:secretariat etc.
  negative_fixture text NOT NULL                    -- fixture for negative verification (required)
);

CREATE TABLE catalog.check_controls (
  check_key  text NOT NULL REFERENCES catalog.checks(key),
  control_id uuid NOT NULL REFERENCES catalog.controls(id),
  PRIMARY KEY (check_key, control_id)
);
