-- 0037 app: rate master and education cost records (foundation of screen (5) "education cost and labor cost")
--
-- User decision (2026-09-02): per-person hourly rates (salary equivalents) are
-- not put in the production DB. Only per-role default rates. No member_id.
--
-- On production view/edit restrictions (spec C5 "not opened to anyone but the secretariat"):
-- The app currently has no SSO/per-person login (as the next.config.ts comment says,
-- "an internal, local-only viewing app; no SSO yet") and runs on a single shared
-- per-tenant session. Since individuals cannot be identified, role-based
-- access control is technically impossible in the app layer (same constraint as every existing screen).
-- Keeping per-role aggregates rather than per-person salaries is the risk
-- mitigation chosen with this constraint in mind (decision of 2026-09-02).

CREATE TABLE app.rate_master (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  role          text NOT NULL,                     -- instructor/material author/learner/default etc. Free text
  hourly_rate   numeric(10,2) NOT NULL CHECK (hourly_rate >= 0 AND hourly_rate <> 'NaN'::numeric),
  effective_from date NOT NULL,
  source_note   text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  -- No multiple rows for the same role with the same effective_from (uniqueness of the rate).
  -- On revision, add a row with a new effective_from (append-only; existing rows are not rewritten).
  UNIQUE (tenant_id, role, effective_from)
);

CREATE TABLE app.education_records (
  id                uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL,
  program_name      text NOT NULL,
  role              text NOT NULL,                  -- matched with rate_master.role to look up the rate
  member_id         uuid,                            -- optional; only when recording an individual
  hours             numeric(6,2) NOT NULL CHECK (hours > 0 AND hours <> 'NaN'::numeric),
  conducted_on      date NOT NULL,
  related_measure_id uuid,
  source_note       text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, member_id) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, related_measure_id) REFERENCES app.measures(tenant_id, id)
);

COMMENT ON TABLE app.rate_master IS '役割別の既定時間単価。個人別給与は持たない(2026-09-02決定)';
COMMENT ON TABLE app.education_records IS '教育プログラムの工数記録。role経由でrate_masterと突き合わせて人件費コストを算出する';

-- 0015's bulk RLS setup only applies to tables existing when 0015 ran. New tables
-- created in 0016 and later are configured individually here, following existing patterns such as 0027
-- (forgetting this is a cross-tenant defect; found by measurement in local verification).
DO $$
DECLARE
  t text;
  tables constant text[] := ARRAY['rate_master','education_records'];
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
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON app.%I TO app_rw', t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro', t);
  END LOOP;
END $$;
