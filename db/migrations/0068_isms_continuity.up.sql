-- @run-as: admin
-- 0068: storage for business continuity plans and tests (A.5.29 / A.5.30) (the 3rd item of design doc 2026-09-11 §4).
--
-- A.5.29 requires maintaining information security during disruption; A.5.30 requires ICT continuity readiness and its planning and testing.
-- These are Annex A controls, so whether they apply is decided by the Statement of Applicability. The stage screen only shows counts and does not make them mandatory
-- (2026-09-12 design decision).
--
-- Plans (continuity_plans) and tests (continuity_tests) are separate. Having written a plan and having tested that it works are different things.
-- As with audits, only tests dated up to today count as "performed" (§4.4 "do not count a plan as performed").
-- The plan text itself is not stored. Where it is (its location) is mandatory (same idea as evidence).
-- No approval (the standard's text does not require it). No version table either. Withdraw rather than delete. No content data is loaded.
-- Formatting, RLS, and down policy are the same as 0065-0067. Only the records screen writes these tables, so 0067's role policies are applied too.

SET ROLE schema_owner;

CREATE TABLE app.continuity_plans (
  id                  uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL,
  title               text NOT NULL,
  -- What the plan protects (business process / system). Empty plans are not allowed.
  scope               text NOT NULL,
  -- Recovery time objective (hours) / recovery point objective (hours). Empty if not decided.
  rto_hours           integer CHECK (rto_hours > 0),
  rpo_hours           integer CHECK (rpo_hours >= 0),
  -- Where the plan text is (storage location / URL). Mandatory.
  procedure_location  text NOT NULL,
  owner_user_id       uuid,
  -- Deadline for the next test.
  next_test_due       date,
  status              text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, title),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id),
  CHECK (title ~ '[^[:space:]]'),
  CHECK (scope ~ '[^[:space:]]'),
  CHECK (procedure_location ~ '[^[:space:]]')
);

-- Test records. When, how it was tested, what the result was, and who did it are mandatory.
CREATE TABLE app.continuity_tests (
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL,
  plan_id         uuid NOT NULL,
  tested_on       date NOT NULL,
  method          text NOT NULL CHECK (method IN ('tabletop','walkthrough','simulation','full_interruption')),
  result          text NOT NULL CHECK (result IN ('passed','partially_passed','failed')),
  -- Whether the recovery time objective was met. Empty if not measured.
  rto_met         boolean,
  findings_note   text NOT NULL DEFAULT '',
  performed_by    uuid NOT NULL,
  evidence_id     uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, plan_id)      REFERENCES app.continuity_plans(tenant_id, id),
  FOREIGN KEY (tenant_id, performed_by) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, evidence_id)  REFERENCES app.evidences(tenant_id, id)
);
CREATE INDEX continuity_tests_plan ON app.continuity_tests (tenant_id, plan_id, tested_on DESC);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['continuity_plans','continuity_tests'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO app_rw',t);
    -- Same role policies as 0067 (name, shape, and target tables are fixed by check_rls.sql).
    EXECUTE format('CREATE POLICY records_role_insert ON app.%I AS RESTRICTIVE FOR INSERT TO app_rw '
                   'WITH CHECK ((SELECT app.records_role_allows(%L)))', t, 'continuity');
    EXECUTE format('CREATE POLICY records_role_update ON app.%I AS RESTRICTIVE FOR UPDATE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L))) WITH CHECK ((SELECT app.records_role_allows(%L)))',
                   t, 'continuity', 'continuity');
    EXECUTE format('CREATE POLICY records_role_delete ON app.%I AS RESTRICTIVE FOR DELETE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L)))', t, 'continuity');
  END LOOP;
END $$;

COMMENT ON TABLE app.continuity_plans IS
  '事業継続の計画（A.5.29 / A.5.30）。scope（何を守るか）と procedure_location（計画の所在）は必須。';
COMMENT ON TABLE app.continuity_tests IS
  '事業継続の試験。tested_on が今日までのものだけを実施済みとして数える。実施者（performed_by）と結果は必須。';

-- Add continuity to the permission table: owner / admin / manager (records of business operations). Auditors cannot write.
-- Only adds one kind to 0067's version (down reverts to 0067's version).
CREATE OR REPLACE FUNCTION app.records_role_allows(p_kind text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text;
  v_allowed text[];
BEGIN
  v_allowed := CASE p_kind
    WHEN 'audit'             THEN ARRAY['owner','admin','auditor']
    WHEN 'corrective'        THEN ARRAY['owner','admin','manager']
    WHEN 'effectiveness'     THEN ARRAY['owner','admin']
    WHEN 'management_review' THEN ARRAY['owner','admin']
    WHEN 'objective'         THEN ARRAY['owner','admin']
    WHEN 'evidence'          THEN ARRAY['owner','admin','manager']
    WHEN 'exception'         THEN ARRAY['owner']
    WHEN 'context'           THEN ARRAY['owner','admin']
    WHEN 'legal'             THEN ARRAY['owner','admin','manager']
    WHEN 'continuity'        THEN ARRAY['owner','admin','manager']
  END;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'unknown record kind: %', p_kind;
  END IF;
  IF app.current_session_user() IS NULL THEN
    RETURN false;
  END IF;
  v_role := app.current_management_role();
  RETURN v_role IS NOT NULL AND v_role = ANY (v_allowed);
END $$;

RESET ROLE;
