-- 0060: Checklist / questionnaire templates for external resources
--
-- Background (measured): web/src/app/operations/external-resources/actions.ts hard-coded
--   5 questions. What to ask differs between contractors, cloud providers, and outsourcees,
--   yet re-asking meant rewriting code each time. Move the templates into a register.
--
-- Don't build the delivery channel first. Templates are internal data, reusable whether distributed by
-- email, PDF, or paper. Keep them independent of the outlet (0059's app.mail_outbox).

SET ROLE schema_owner;

CREATE TABLE app.questionnaire_templates (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL,
  name        text NOT NULL CHECK (length(btrim(name)) > 0),
  kind        text NOT NULL DEFAULT 'checklist'
              CHECK (kind IN ('checklist','survey')),
  purpose     text NOT NULL DEFAULT '',
  description text NOT NULL DEFAULT '',
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, name),
  FOREIGN KEY (tenant_id, created_by) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, updated_by) REFERENCES app.users(tenant_id, id)
);

COMMENT ON TABLE app.questionnaire_templates IS
  '外部リソースへ送るチェックリスト・アンケートの雛形。kind=checklist は可否確認、survey は記述回答が主';

CREATE TABLE app.questionnaire_template_questions (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL,
  template_id uuid NOT NULL,
  ordinal     smallint NOT NULL CHECK (ordinal > 0),
  prompt      text NOT NULL CHECK (length(btrim(prompt)) > 0),
  answer_type text NOT NULL DEFAULT 'text'
              CHECK (answer_type IN ('text','boolean','single_choice')),
  options     jsonb NOT NULL DEFAULT '[]'::jsonb,
  required    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, template_id, ordinal),
  FOREIGN KEY (tenant_id, template_id)
    REFERENCES app.questionnaire_templates(tenant_id, id) ON DELETE CASCADE,
  CHECK (jsonb_typeof(options) = 'array'),
  -- With single_choice and empty options, we'd send a questionnaire the respondent can't answer.
  -- 0057's external_questionnaire_questions has the same hole, but it is
  -- already applied so we don't fix it (policy: add under new numbers). Stop it on the template side.
  CHECK (answer_type <> 'single_choice' OR jsonb_array_length(options) >= 2)
);

-- Record which template it was created from. Even if the template is edited later, the sent questionnaire's contents
-- have already been copied into external_questionnaire_questions and don't change (intentional).
ALTER TABLE app.external_questionnaires
  ADD COLUMN template_id uuid,
  ADD CONSTRAINT external_questionnaires_template_fk
    FOREIGN KEY (tenant_id, template_id)
    REFERENCES app.questionnaire_templates(tenant_id, id);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['questionnaire_templates','questionnaire_template_questions'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw
                    USING (tenant_id = app.current_tenant())
                    WITH CHECK (tenant_id = app.current_tenant())', t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro
                    USING (tenant_id = app.current_tenant())', t);
    EXECUTE format('CREATE POLICY tenant_security_definer ON app.%I FOR ALL TO schema_owner
                    USING (tenant_id = app.current_tenant())
                    WITH CHECK (tenant_id = app.current_tenant())', t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON app.%I TO app_rw', t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro', t);
  END LOOP;
END $$;

-- Creating / revising / retiring templates requires manager or above (same boundary as 0057's questionnaire_manage).
CREATE OR REPLACE FUNCTION app.guard_questionnaire_template() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF NOT app.has_actor_context() THEN RETURN COALESCE(NEW, OLD); END IF;
  PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'questionnaire_manage');
  RETURN COALESCE(NEW, OLD);
END
$$;
ALTER FUNCTION app.guard_questionnaire_template() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_questionnaire_template() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_questionnaire_template() TO app_rw;

CREATE TRIGGER trg_guard_questionnaire_template
  BEFORE INSERT OR UPDATE OR DELETE ON app.questionnaire_templates
  FOR EACH ROW EXECUTE FUNCTION app.guard_questionnaire_template();
CREATE TRIGGER trg_guard_questionnaire_template_question
  BEFORE INSERT OR UPDATE OR DELETE ON app.questionnaire_template_questions
  FOR EACH ROW EXECUTE FUNCTION app.guard_questionnaire_template();

RESET ROLE;
