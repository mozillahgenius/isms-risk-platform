-- @run-as: admin
-- 0055: a home for information security objectives (JIS Q 27001:2023 6.2).
--
-- 6.2 requires "measurable objectives" and "how achievement will be evaluated".
-- Recording only a numeric target, without how to measure it, means nobody can say whether it was achieved.
-- So measure_how (how to measure) is NOT NULL, and registering an objective alone is not allowed.
--
-- The achievement record (measured value, evaluation date, evaluator) is **written when evaluated**.
-- It is empty when the objective is set, and being empty itself means "not measured yet".

SET ROLE schema_owner;

CREATE TABLE app.security_objectives (
  id                uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL,
  fiscal_year       integer NOT NULL,
  title             text NOT NULL,
  -- Free text for what and how far. Do not allow empty objectives.
  description       text NOT NULL DEFAULT '',
  -- **How to measure is required**. An objective that cannot be measured is not a 6.2 objective.
  measure_how       text NOT NULL,
  target_value      text NOT NULL DEFAULT '',
  owner_user_id     uuid,
  due_date          date,
  -- The following are filled only when achievement is evaluated. Empty when the objective is set.
  achieved_value    text,
  evaluated_at      timestamptz,
  evaluated_by      uuid,
  status            text NOT NULL DEFAULT 'planned'
                    CHECK (status IN ('planned','in_progress','achieved','not_achieved','cancelled')),
  source_note       text NOT NULL DEFAULT '',
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_by        uuid,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  updated_by        uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, fiscal_year, title),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, evaluated_by)  REFERENCES app.users(tenant_id, id),
  -- Prevent circumventing it by filling measure_how with an empty string.
  CHECK (length(btrim(measure_how)) > 0),
  -- **Claiming an evaluation requires who measured what and when.** Either all 3 are set or all 3 are empty.
  CHECK (
    (achieved_value IS NULL AND evaluated_at IS NULL AND evaluated_by IS NULL)
    OR (achieved_value IS NOT NULL AND evaluated_at IS NOT NULL AND evaluated_by IS NOT NULL)
  ),
  -- Achieved / not achieved requires a completed evaluation. The status cannot be advanced on its own.
  CHECK (status NOT IN ('achieved','not_achieved') OR evaluated_at IS NOT NULL)
);
CREATE INDEX security_objectives_year ON app.security_objectives (tenant_id, fiscal_year);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['security_objectives'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY management_definer_access ON app.%I FOR ALL TO schema_owner USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO app_rw',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO schema_owner',t);
  END LOOP;
END $$;

COMMENT ON TABLE app.security_objectives IS
  '情報セキュリティ目的（6.2）。measure_how は測り方で必須。達成の評価は achieved_value / evaluated_at / evaluated_by が揃ったときだけ成立する。';

RESET ROLE;
