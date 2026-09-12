-- 0038 app: competence management (screen ⑤ "Competence management")
--
-- The management area corresponding to the competence requirement of ISO/IEC 27001 (clause 7.2).
-- Defines the competence (job requirements) needed per role and records fulfillment per member.
--
-- For the same reason as 0037, RLS is set up individually here (0015's bulk RLS only applies to
-- tables that existed when 0015 ran; discovered while implementing 0037, and from then on new tables
-- are set up individually from the start).

CREATE TABLE app.competency_requirements (
  id                  uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL,
  role                text NOT NULL,
  required_competency text NOT NULL,
  description         text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, role, required_competency)
);

CREATE TABLE app.competency_fulfillments (
  id             uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL,
  requirement_id uuid NOT NULL,
  member_id      uuid NOT NULL,
  status         text NOT NULL DEFAULT '未充足'
                   CHECK (status IN ('充足','育成中','未充足')),
  evidence_ref   text NOT NULL DEFAULT '',
  assessed_on    date NOT NULL DEFAULT CURRENT_DATE,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, requirement_id) REFERENCES app.competency_requirements(tenant_id, id),
  FOREIGN KEY (tenant_id, member_id) REFERENCES app.users(tenant_id, id),
  -- Fulfillment for the same requirement and member is kept in one row (if history is needed, extend later
  -- to an append-only form including assessed_on; for now focus on listing "the current state").
  UNIQUE (tenant_id, requirement_id, member_id)
);

COMMENT ON TABLE app.competency_requirements IS '役割ごとに必要な力量(職能要件)の定義';
COMMENT ON TABLE app.competency_fulfillments IS '力量要件に対するメンバーごとの充足状況。evidence_refに根拠(研修修了記録等)の所在を記す';

DO $$
DECLARE
  t text;
  tables constant text[] := ARRAY['competency_requirements','competency_fulfillments'];
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
