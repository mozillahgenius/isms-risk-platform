-- 0011 app: 運用（設計書 2.10）
-- 指摘・是正・規程・教育・監査・レビュー・委託先・インシデント・タスク・承認

CREATE TABLE app.findings (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL,
  source      text NOT NULL CHECK (source IN ('check','internal_audit','external_audit','incident','manual')),
  check_key   text, check_run_id uuid, audit_id uuid,
  title       text NOT NULL, detail text,
  severity    text NOT NULL CHECK (severity IN ('critical','high','medium','low')),
  status      text NOT NULL DEFAULT 'detected' CHECK (status IN (
                'detected','in_remediation','remediated','retest_passed',
                'verified','closed','exception','risk_accepted')),
  assigned_to uuid, due_date date,
  detected_at timestamptz NOT NULL DEFAULT now(),
  verified_by uuid, verified_at timestamptz,
  closed_at   timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  -- 人の確認なしにクローズできない（設計書 1.9）
  CHECK (status <> 'verified' OR (verified_by IS NOT NULL AND verified_at IS NOT NULL)),
  CHECK (status <> 'closed'   OR (verified_by IS NOT NULL AND closed_at   IS NOT NULL))
);
CREATE INDEX findings_open ON app.findings (tenant_id, status, due_date);

-- 0010 の exceptions から findings への FK を後付けする
ALTER TABLE app.exceptions
  ADD CONSTRAINT exceptions_finding_fk
  FOREIGN KEY (tenant_id, finding_id) REFERENCES app.findings(tenant_id, id);

CREATE TABLE app.corrective_actions (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL, finding_id uuid NOT NULL,
  root_cause  text NOT NULL CHECK (length(btrim(root_cause)) > 0),
  action      text NOT NULL, owner_user_id uuid, due_date date,
  completed_at timestamptz,
  effectiveness_reviewed_by uuid, effectiveness_reviewed_at timestamptz,
  effectiveness_result text CHECK (effectiveness_result IN ('effective','not_effective')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, finding_id) REFERENCES app.findings(tenant_id, id)
);

CREATE TABLE app.policies (
  id             uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL,
  catalog_key    text REFERENCES catalog.policies_default(key),
  title          text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, catalog_key)
);

CREATE TABLE app.policy_versions (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL, policy_id uuid NOT NULL,
  version     int NOT NULL,
  body_md     text NOT NULL,
  diff_clause_count int NOT NULL DEFAULT 0,         -- 標準からの変更条項数（適合度スコア用）
  approved_by uuid, approved_at timestamptz,
  effective_from date, superseded_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, policy_id, version),
  FOREIGN KEY (tenant_id, policy_id) REFERENCES app.policies(tenant_id, id)
);

CREATE TABLE app.policy_acknowledgements (
  tenant_id uuid NOT NULL, policy_version_id uuid NOT NULL, user_id uuid NOT NULL,
  acknowledged_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, policy_version_id, user_id),
  FOREIGN KEY (tenant_id, policy_version_id) REFERENCES app.policy_versions(tenant_id, id),
  FOREIGN KEY (tenant_id, user_id)           REFERENCES app.users(tenant_id, id)
);

CREATE TABLE app.trainings (
  id uuid NOT NULL DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
  title text NOT NULL, fiscal_year int NOT NULL, due_date date,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id)
);
CREATE TABLE app.training_records (
  tenant_id uuid NOT NULL, training_id uuid NOT NULL, user_id uuid NOT NULL,
  completed_at timestamptz, score int,
  PRIMARY KEY (tenant_id, training_id, user_id),
  FOREIGN KEY (tenant_id, training_id) REFERENCES app.trainings(tenant_id, id),
  FOREIGN KEY (tenant_id, user_id)     REFERENCES app.users(tenant_id, id)
);

CREATE TABLE app.audit_programs (
  id uuid NOT NULL DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
  fiscal_year int NOT NULL,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','fixed','completed')),
  coverage_verified_at timestamptz,                 -- 全統制網羅の確認（Phase 4 受入）
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id), UNIQUE (tenant_id, fiscal_year)
);

CREATE TABLE app.audits (
  id uuid NOT NULL DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
  program_id uuid NOT NULL, auditor_user_id uuid NOT NULL,
  scope text NOT NULL, criteria text NOT NULL,
  planned_on date, performed_on date,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, program_id)      REFERENCES app.audit_programs(tenant_id, id),
  FOREIGN KEY (tenant_id, auditor_user_id) REFERENCES app.users(tenant_id, id)
);

CREATE TABLE app.audit_items (
  tenant_id uuid NOT NULL, audit_id uuid NOT NULL, control_id uuid NOT NULL,
  result text CHECK (result IN ('conform','nonconform','observation','na')),
  note text,
  PRIMARY KEY (tenant_id, audit_id, control_id),
  FOREIGN KEY (tenant_id, audit_id) REFERENCES app.audits(tenant_id, id),
  FOREIGN KEY (control_id)          REFERENCES catalog.controls(id)
);

CREATE TABLE app.auditor_competences (
  tenant_id uuid NOT NULL, user_id uuid NOT NULL,
  qualification text NOT NULL, acquired_on date, expires_on date,
  PRIMARY KEY (tenant_id, user_id, qualification),
  FOREIGN KEY (tenant_id, user_id) REFERENCES app.users(tenant_id, id)
);

CREATE TABLE app.management_reviews (
  id uuid NOT NULL DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
  fiscal_year int NOT NULL, held_on date, chaired_by uuid,
  minutes_md text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id), UNIQUE (tenant_id, fiscal_year)
);
CREATE TABLE app.management_review_inputs (
  tenant_id uuid NOT NULL, review_id uuid NOT NULL, item_key text NOT NULL,
  content_md text NOT NULL, auto_generated boolean NOT NULL DEFAULT true,
  PRIMARY KEY (tenant_id, review_id, item_key),
  FOREIGN KEY (tenant_id, review_id) REFERENCES app.management_reviews(tenant_id, id)
);
CREATE TABLE app.management_review_outputs (
  id uuid NOT NULL DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, review_id uuid NOT NULL,
  decision text NOT NULL, owner_user_id uuid NOT NULL, due_date date NOT NULL,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','done','cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, review_id)     REFERENCES app.management_reviews(tenant_id, id),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id)
);

CREATE TABLE app.vendors (
  id uuid NOT NULL DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
  name text NOT NULL, service_name text,
  discovery_source text CHECK (discovery_source IN ('manual','oauth_app','sso_log','expense')),
  criticality text CHECK (criticality IN ('high','medium','low')),
  contract_on date, nda_on date,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id)
);
CREATE TABLE app.vendor_assessments (
  id uuid NOT NULL DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, vendor_id uuid NOT NULL,
  assessed_on date NOT NULL, result text, next_due_on date,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, vendor_id) REFERENCES app.vendors(tenant_id, id)
);

CREATE TABLE app.incidents (
  id uuid NOT NULL DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
  title text NOT NULL, occurred_at timestamptz, detected_at timestamptz,
  severity text CHECK (severity IN ('critical','high','medium','low')),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','contained','closed')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id)
);

CREATE TABLE app.tasks (                       -- 標準カレンダー由来のタスク
  id uuid NOT NULL DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
  calendar_event_key text REFERENCES catalog.calendar_events_default(key),
  title text NOT NULL, assigned_role text, assigned_to uuid,
  due_date date NOT NULL,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','done','overdue')),
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, assigned_to) REFERENCES app.users(tenant_id, id)
);

CREATE TABLE app.approvals (
  id uuid NOT NULL DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
  target_type text NOT NULL, target_id uuid NOT NULL,
  target_version_hash bytea NOT NULL,          -- 何を承認したかを特定できるようにする
  approver_user_id uuid NOT NULL, approved_at timestamptz NOT NULL DEFAULT now(),
  comment text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, approver_user_id) REFERENCES app.users(tenant_id, id)
);
