-- 0057: 作業依頼・権限マッピング・外部リソース質問票
--
-- ISMS固有の列を増やさず、資産・リスク・インシデント・教育などを
-- 共通の依頼台帳で扱う。外部質問票も vendor を起点にした共通機能とする。

SET ROLE schema_owner;

CREATE TABLE app.work_assignments (
  id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  resource_type      text NOT NULL CHECK (resource_type IN (
                       'asset','risk','measure','incident','training','vendor','vendor_assessment'
                     )),
  resource_id        uuid NOT NULL,
  title              text NOT NULL CHECK (length(btrim(title)) > 0),
  instructions       text NOT NULL DEFAULT '',
  assignment_role    text NOT NULL DEFAULT 'editor'
                     CHECK (assignment_role IN ('owner','editor','reviewer','approver')),
  assignee_user_id   uuid NOT NULL,
  requested_by       uuid NOT NULL,
  due_date           date,
  status             text NOT NULL DEFAULT 'requested'
                     CHECK (status IN ('requested','accepted','in_progress','submitted','completed','declined','cancelled')),
  completion_note    text NOT NULL DEFAULT '',
  completed_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, assignee_user_id) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, requested_by) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, updated_by) REFERENCES app.users(tenant_id, id),
  CHECK (status <> 'completed' OR completed_at IS NOT NULL)
);

CREATE INDEX work_assignments_assignee_idx
  ON app.work_assignments (tenant_id, assignee_user_id, status, due_date);
CREATE INDEX work_assignments_resource_idx
  ON app.work_assignments (tenant_id, resource_type, resource_id, status);

CREATE TABLE app.external_questionnaires (
  id               uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL,
  vendor_id        uuid NOT NULL,
  title            text NOT NULL,
  purpose          text NOT NULL DEFAULT '',
  recipient_name   text NOT NULL DEFAULT '',
  recipient_email  citext NOT NULL,
  due_date         date,
  status           text NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft','ready','queued','sent','in_progress','submitted','reviewed','cancelled')),
  queued_at        timestamptz,
  sent_at          timestamptz,
  submitted_at     timestamptz,
  reviewed_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, vendor_id) REFERENCES app.vendors(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, updated_by) REFERENCES app.users(tenant_id, id),
  CHECK (recipient_email = lower(recipient_email::text)),
  CHECK (length(recipient_email::text) BETWEEN 3 AND 254),
  CHECK (status NOT IN ('queued','sent') OR queued_at IS NOT NULL),
  CHECK (status <> 'sent' OR sent_at IS NOT NULL)
);

CREATE TABLE app.external_questionnaire_questions (
  id                uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL,
  questionnaire_id  uuid NOT NULL,
  ordinal           smallint NOT NULL CHECK (ordinal > 0),
  prompt            text NOT NULL CHECK (length(btrim(prompt)) > 0),
  answer_type       text NOT NULL DEFAULT 'text'
                    CHECK (answer_type IN ('text','boolean','single_choice')),
  options           jsonb NOT NULL DEFAULT '[]'::jsonb,
  required          boolean NOT NULL DEFAULT true,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, questionnaire_id, ordinal),
  FOREIGN KEY (tenant_id, questionnaire_id)
    REFERENCES app.external_questionnaires(tenant_id, id) ON DELETE CASCADE,
  CHECK (jsonb_typeof(options) = 'array')
);

CREATE TABLE app.external_questionnaire_answers (
  tenant_id         uuid NOT NULL,
  questionnaire_id  uuid NOT NULL,
  question_id       uuid NOT NULL,
  answer_text       text NOT NULL DEFAULT '',
  answered_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, questionnaire_id, question_id),
  FOREIGN KEY (tenant_id, questionnaire_id)
    REFERENCES app.external_questionnaires(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, question_id)
    REFERENCES app.external_questionnaire_questions(tenant_id, id) ON DELETE CASCADE
);

CREATE OR REPLACE FUNCTION app.current_management_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, app AS $$
  SELECT CASE
    WHEN EXISTS (
      SELECT 1 FROM app.memberships m JOIN app.users u
        ON u.tenant_id=m.tenant_id AND u.id=m.user_id
       WHERE m.tenant_id=app.current_tenant() AND m.user_id=app.current_session_user()
         AND m.role_key='ciso' AND m.revoked_at IS NULL AND u.status='active'
    ) THEN 'owner'
    WHEN EXISTS (
      SELECT 1 FROM app.memberships m JOIN app.users u
        ON u.tenant_id=m.tenant_id AND u.id=m.user_id
       WHERE m.tenant_id=app.current_tenant() AND m.user_id=app.current_session_user()
         AND m.role_key='secretariat' AND m.revoked_at IS NULL AND u.status='active'
    ) THEN 'admin'
    WHEN EXISTS (
      SELECT 1 FROM app.memberships m JOIN app.users u
        ON u.tenant_id=m.tenant_id AND u.id=m.user_id
       WHERE m.tenant_id=app.current_tenant() AND m.user_id=app.current_session_user()
         AND m.role_key='risk_owner' AND m.revoked_at IS NULL AND u.status='active'
    ) THEN 'manager'
    WHEN EXISTS (
      SELECT 1 FROM app.memberships m JOIN app.users u
        ON u.tenant_id=m.tenant_id AND u.id=m.user_id
       WHERE m.tenant_id=app.current_tenant() AND m.user_id=app.current_session_user()
         AND m.role_key='employee' AND m.revoked_at IS NULL AND u.status='active'
    ) THEN 'member'
    WHEN EXISTS (
      SELECT 1 FROM app.memberships m JOIN app.users u
        ON u.tenant_id=m.tenant_id AND u.id=m.user_id
       WHERE m.tenant_id=app.current_tenant() AND m.user_id=app.current_session_user()
         AND m.role_key='auditor' AND m.revoked_at IS NULL AND u.status='active'
    ) THEN 'auditor'
    ELSE 'none'
  END
$$;
ALTER FUNCTION app.current_management_role() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.current_management_role() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.current_management_role() TO app_rw, app_ro;

CREATE OR REPLACE FUNCTION app.require_management_permission(
  p_resource_type text,
  p_resource_id uuid,
  p_action text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text := app.current_management_role();
  v_tenant uuid := app.current_tenant();
  v_user uuid := app.current_session_user();
BEGIN
  IF v_user IS NULL OR v_role IN ('none','auditor') THEN
    RAISE EXCEPTION 'management permission required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF p_action = 'role_manage' AND v_role <> 'owner' THEN
    RAISE EXCEPTION 'owner role required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF p_action = 'questionnaire_send' AND v_role NOT IN ('owner','admin') THEN
    RAISE EXCEPTION 'admin role required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF p_action IN ('assign','create','questionnaire_manage')
     AND v_role NOT IN ('owner','admin','manager') THEN
    RAISE EXCEPTION 'manager role required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF p_action = 'write' THEN
    IF v_role IN ('owner','admin','manager') THEN RETURN; END IF;
    IF EXISTS (
      SELECT 1 FROM app.work_assignments a
       WHERE a.tenant_id=v_tenant AND a.resource_type=p_resource_type
         AND a.resource_id=p_resource_id AND a.assignee_user_id=v_user
         AND a.assignment_role IN ('owner','editor')
         AND a.status NOT IN ('declined','cancelled','completed')
    ) THEN RETURN; END IF;
    RAISE EXCEPTION 'active assignment required' USING ERRCODE='insufficient_privilege';
  END IF;
END
$$;
ALTER FUNCTION app.require_management_permission(text,uuid,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.require_management_permission(text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.require_management_permission(text,uuid,text) TO app_rw;

CREATE OR REPLACE FUNCTION app.set_management_frameworks_for_assignee(
  p_entity_type text, p_entity uuid, p_keys text[]
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text := app.current_management_role();
  v_resource_type text := CASE
    WHEN p_entity_type='risk_scenario' THEN 'risk'
    ELSE p_entity_type
  END;
BEGIN
  IF v_role IN ('owner','admin','manager') THEN
    PERFORM app.set_management_frameworks_v2(p_entity_type,p_entity,p_keys,'human');
    RETURN;
  END IF;
  IF EXISTS (
    SELECT 1 FROM app.work_assignments a
     WHERE a.tenant_id=app.current_tenant()
       AND a.resource_type=v_resource_type AND a.resource_id=p_entity
       AND a.assignee_user_id=app.current_session_user()
       AND a.assignment_role IN ('owner','editor')
       AND a.status NOT IN ('declined','cancelled','completed')
  ) THEN
    PERFORM app.set_management_frameworks_v2(p_entity_type,p_entity,p_keys,'human');
    RETURN;
  END IF;
  RAISE EXCEPTION 'active assignment required' USING ERRCODE='insufficient_privilege';
END
$$;
ALTER FUNCTION app.set_management_frameworks_for_assignee(text,uuid,text[]) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.set_management_frameworks_for_assignee(text,uuid,text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.set_management_frameworks_for_assignee(text,uuid,text[]) TO app_rw;

CREATE OR REPLACE FUNCTION app.assignment_target_exists(p_type text, p_id uuid, p_tenant uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF p_type='asset' THEN RETURN EXISTS (SELECT 1 FROM app.assets WHERE tenant_id=p_tenant AND id=p_id AND status='active'); END IF;
  IF p_type='risk' THEN RETURN EXISTS (SELECT 1 FROM app.risk_scenarios WHERE tenant_id=p_tenant AND id=p_id AND status='active'); END IF;
  IF p_type='measure' THEN RETURN EXISTS (SELECT 1 FROM app.measures WHERE tenant_id=p_tenant AND id=p_id AND status <> 'retired'); END IF;
  IF p_type='incident' THEN RETURN EXISTS (SELECT 1 FROM app.incidents WHERE tenant_id=p_tenant AND id=p_id); END IF;
  IF p_type='training' THEN RETURN EXISTS (SELECT 1 FROM app.trainings WHERE tenant_id=p_tenant AND id=p_id); END IF;
  IF p_type='vendor' THEN RETURN EXISTS (SELECT 1 FROM app.vendors WHERE tenant_id=p_tenant AND id=p_id); END IF;
  IF p_type='vendor_assessment' THEN RETURN EXISTS (SELECT 1 FROM app.vendor_assessments WHERE tenant_id=p_tenant AND id=p_id); END IF;
  RETURN false;
END
$$;
ALTER FUNCTION app.assignment_target_exists(text,uuid,uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.assignment_target_exists(text,uuid,uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION app.guard_work_assignment() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant uuid := app.current_tenant();
  v_user uuid := app.current_session_user();
BEGIN
  IF NOT app.assignment_target_exists(NEW.resource_type, NEW.resource_id, v_tenant) THEN
    RAISE EXCEPTION 'assignment target not found';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app.users WHERE tenant_id=v_tenant AND id=NEW.assignee_user_id AND status='active') THEN
    RAISE EXCEPTION 'assignee must be an active user';
  END IF;
  IF TG_OP='UPDATE' AND OLD.assignee_user_id=v_user AND NEW.assignee_user_id=v_user
     AND NEW.resource_type=OLD.resource_type AND NEW.resource_id=OLD.resource_id
     AND NEW.title=OLD.title AND NEW.instructions=OLD.instructions
     AND NEW.assignment_role=OLD.assignment_role AND NEW.requested_by=OLD.requested_by
     AND NEW.due_date IS NOT DISTINCT FROM OLD.due_date THEN
    RETURN NEW;
  END IF;
  PERFORM app.require_management_permission(NEW.resource_type, NEW.resource_id, 'assign');
  RETURN NEW;
END
$$;
ALTER FUNCTION app.guard_work_assignment() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_work_assignment() FROM PUBLIC;
CREATE TRIGGER trg_guard_work_assignment
  BEFORE INSERT OR UPDATE ON app.work_assignments
  FOR EACH ROW EXECUTE FUNCTION app.guard_work_assignment();

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'work_assignments','external_questionnaires',
    'external_questionnaire_questions','external_questionnaire_answers'
  ] LOOP
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

GRANT EXECUTE ON FUNCTION app.assignment_target_exists(text,uuid,uuid) TO app_rw;
GRANT EXECUTE ON FUNCTION app.guard_work_assignment() TO app_rw;

COMMENT ON TABLE app.work_assignments IS
  '会社側から担当者へ資産・リスク・施策・インシデント・教育・外部リソースの対応を依頼する共通台帳';
COMMENT ON TABLE app.external_questionnaires IS
  '外部業者・外部サービスへ送る質問票の台帳。メール本文や秘密値は保存せず、送信キューの状態だけを持つ';

RESET ROLE;
