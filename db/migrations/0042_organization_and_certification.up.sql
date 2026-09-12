-- 0042 app: organization initial settings and certification body information (the substance of screen ⑨ steps 1 and 2)
--
-- Actual schema check (principle of reusing existing code): app.tenants already has name, but
-- has no column for the ISMS scope (scope statement). Certification body information is not in existing tables
-- either. The organization name reuses app.tenants.name; the only new needs are one scope column and
-- a table for certification body information.
--
-- Unlike other app tables, app.tenants has no tenant_id column (id itself is that), so
-- it is outside 0015's bulk RLS application, but 0005 already set RLS on it individually
-- (only a column is added, so RLS need not be reconfigured).

ALTER TABLE app.tenants
  ADD COLUMN iso_scope_statement text NOT NULL DEFAULT '';
COMMENT ON COLUMN app.tenants.iso_scope_statement IS 'ISMS適用範囲の声明。画面⑨ウィザードのステップ1「初期設定」に対応';

CREATE TABLE app.certification_bodies (
  id                   uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES app.tenants(id),
  body_name            text NOT NULL,
  certification_standard text NOT NULL DEFAULT 'ISO/IEC 27001:2022',
  certificate_number   text NOT NULL DEFAULT '',
  initial_certified_on date,
  last_audit_on        date,
  next_audit_on        date,
  contact_info         text NOT NULL DEFAULT '',
  source_note          text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  -- Date ordering. If one or both are missing there is nothing to compare, so allow it
  -- (the same rule as the Server Action validation in organization/actions.ts is also placed
  -- in the DB to prevent reversed order via direct SQL paths. Codex review 2026-09-03, 8th-round finding).
  CHECK (initial_certified_on IS NULL OR last_audit_on IS NULL
         OR initial_certified_on <= last_audit_on),
  CHECK (last_audit_on IS NULL OR next_audit_on IS NULL
         OR last_audit_on <= next_audit_on),
  CHECK (initial_certified_on IS NULL OR next_audit_on IS NULL
         OR initial_certified_on <= next_audit_on)
);

COMMENT ON TABLE app.certification_bodies IS '審査機関情報。画面⑨ウィザードのステップ2「適用範囲・審査機関」に対応';

DO $$
BEGIN
  ALTER TABLE app.certification_bodies ENABLE ROW LEVEL SECURITY;
  ALTER TABLE app.certification_bodies FORCE ROW LEVEL SECURITY;
  CREATE POLICY tenant_isolation ON app.certification_bodies FOR ALL TO app_rw
    USING (tenant_id = app.current_tenant())
    WITH CHECK (tenant_id = app.current_tenant());
  CREATE POLICY tenant_read ON app.certification_bodies FOR SELECT TO app_ro
    USING (tenant_id = app.current_tenant());
  REVOKE ALL ON app.certification_bodies FROM PUBLIC;
  GRANT SELECT, INSERT, UPDATE, DELETE ON app.certification_bodies TO app_rw;
  GRANT SELECT ON app.certification_bodies TO app_ro;
END $$;
