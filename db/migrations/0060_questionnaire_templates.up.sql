-- 0060: 外部リソース向けチェックリスト／アンケートのテンプレート
--
-- 背景（実測）: web/src/app/operations/external-resources/actions.ts が 5 問を
--   ハードコードしていた。委託先・クラウド事業者・業務委託先で聞くことは違うのに、
--   問い直すたびにコードを書き換えることになる。テンプレートを台帳へ出す。
--
-- 送信経路を先に作らない。テンプレートは社内データで、メール・PDF・紙のどれで
-- 配っても再利用できる。出口（0059 の app.mail_outbox）とは独立させる。

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
  -- single_choice で選択肢が空だと、回答者が選べない質問票を送ってしまう。
  -- 0057 の external_questionnaire_questions は同じ穴を持つが、そちらは
  -- 適用済みなので直さない（新しい番号で足す方針）。テンプレート側で止める。
  CHECK (answer_type <> 'single_choice' OR jsonb_array_length(options) >= 2)
);

-- どの雛形から作ったかを残す。雛形を後から直しても、送った質問票の中身は
-- external_questionnaire_questions に複写済みなので変わらない（意図的）。
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

-- 雛形の作成・改廃はマネージャー以上（0057 の questionnaire_manage と同じ境界）。
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
