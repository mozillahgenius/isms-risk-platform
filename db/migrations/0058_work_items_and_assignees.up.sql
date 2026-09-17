-- 0058: 作業単位の依頼と複数メンバー割当
-- 0057 のレコード単位 work_assignments は互換のため残し、画面と新規権限判定は
-- work_items / work_item_assignees を正本として扱う。

SET ROLE schema_owner;

CREATE TABLE app.work_items (
  id                    uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL,
  work_type             text NOT NULL CHECK (work_type IN (
                          'asset_inventory','risk_assessment','incident_response',
                          'training_execution','external_resource_review','custom'
                        )),
  title                 text NOT NULL CHECK (length(btrim(title)) > 0),
  instructions          text NOT NULL DEFAULT '',
  due_date              date,
  status                text NOT NULL DEFAULT 'requested'
                        CHECK (status IN ('requested','in_progress','submitted','completed','cancelled')),
  created_at            timestamptz NOT NULL DEFAULT now(),
  created_by            uuid,
  updated_at            timestamptz NOT NULL DEFAULT now(),
  updated_by            uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, updated_by) REFERENCES app.users(tenant_id, id)
);

CREATE INDEX work_items_status_idx ON app.work_items (tenant_id, status, due_date);
CREATE INDEX work_items_type_idx ON app.work_items (tenant_id, work_type, status);

CREATE TABLE app.work_item_assignees (
  tenant_id             uuid NOT NULL,
  work_item_id          uuid NOT NULL,
  user_id               uuid NOT NULL,
  assignment_role       text NOT NULL DEFAULT 'editor'
                        CHECK (assignment_role IN ('owner','editor','reviewer','approver')),
  status                text NOT NULL DEFAULT 'requested'
                        CHECK (status IN ('requested','accepted','in_progress','submitted','completed','declined','cancelled')),
  completion_note       text NOT NULL DEFAULT '',
  completed_at          timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  created_by            uuid,
  updated_at            timestamptz NOT NULL DEFAULT now(),
  updated_by            uuid,
  PRIMARY KEY (tenant_id, work_item_id, user_id),
  FOREIGN KEY (tenant_id, work_item_id) REFERENCES app.work_items(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, user_id) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, updated_by) REFERENCES app.users(tenant_id, id),
  CHECK (status <> 'completed' OR completed_at IS NOT NULL)
);

CREATE INDEX work_item_assignees_user_idx
  ON app.work_item_assignees (tenant_id, user_id, status);

CREATE OR REPLACE FUNCTION app.work_type_for_resource(p_resource_type text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_resource_type
    WHEN 'asset' THEN 'asset_inventory'
    WHEN 'risk' THEN 'risk_assessment'
    WHEN 'measure' THEN 'risk_assessment'
    WHEN 'incident' THEN 'incident_response'
    WHEN 'training' THEN 'training_execution'
    WHEN 'vendor' THEN 'external_resource_review'
    WHEN 'vendor_assessment' THEN 'external_resource_review'
    ELSE NULL
  END
$$;
ALTER FUNCTION app.work_type_for_resource(text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.work_type_for_resource(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.work_type_for_resource(text) TO app_rw;

CREATE OR REPLACE FUNCTION app.require_work_permission(
  p_resource_type text, p_resource_id uuid, p_action text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text := app.current_management_role();
  v_work_type text := app.work_type_for_resource(p_resource_type);
BEGIN
  IF v_role IN ('owner','admin','manager') THEN RETURN; END IF;
  IF v_role IN ('none','auditor') OR v_work_type IS NULL
     OR p_action NOT IN ('create','write') THEN
    RAISE EXCEPTION 'work permission required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM app.work_items w
      JOIN app.work_item_assignees a
        ON a.tenant_id=w.tenant_id AND a.work_item_id=w.id
     WHERE w.tenant_id=app.current_tenant()
       AND w.work_type=v_work_type
       AND w.status NOT IN ('completed','cancelled')
       AND a.user_id=app.current_session_user()
       AND a.assignment_role IN ('owner','editor')
       AND a.status NOT IN ('declined','cancelled','completed')
  ) THEN
    RETURN;
  END IF;
  RAISE EXCEPTION 'active work assignment required' USING ERRCODE='insufficient_privilege';
END
$$;
ALTER FUNCTION app.require_work_permission(text,uuid,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.require_work_permission(text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.require_work_permission(text,uuid,text) TO app_rw;

CREATE OR REPLACE FUNCTION app.require_work_item_permission(
  p_work_item uuid, p_action text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text := app.current_management_role();
BEGIN
  IF v_role IN ('owner','admin','manager') THEN RETURN; END IF;
  IF v_role IN ('none','auditor') OR p_action <> 'status' THEN
    RAISE EXCEPTION 'work item permission required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF EXISTS (
    SELECT 1 FROM app.work_items w
    JOIN app.work_item_assignees a
      ON a.tenant_id=w.tenant_id AND a.work_item_id=w.id
   WHERE w.tenant_id=app.current_tenant() AND w.id=p_work_item
     AND w.status NOT IN ('completed','cancelled')
     AND a.user_id=app.current_session_user()
     AND a.status NOT IN ('declined','cancelled','completed')
  ) THEN
    RETURN;
  END IF;
  RAISE EXCEPTION 'active work item assignment required' USING ERRCODE='insufficient_privilege';
END
$$;
ALTER FUNCTION app.require_work_item_permission(uuid,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.require_work_item_permission(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.require_work_item_permission(uuid,text) TO app_rw;

CREATE OR REPLACE FUNCTION app.set_management_frameworks_for_work(
  p_entity_type text, p_entity uuid, p_keys text[]
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  PERFORM app.require_work_permission(
    CASE WHEN p_entity_type='risk_scenario' THEN 'risk' ELSE p_entity_type END,
    p_entity, 'write'
  );
  PERFORM app.set_management_frameworks_v2(p_entity_type,p_entity,p_keys,'human');
END
$$;
ALTER FUNCTION app.set_management_frameworks_for_work(text,uuid,text[]) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.set_management_frameworks_for_work(text,uuid,text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.set_management_frameworks_for_work(text,uuid,text[]) TO app_rw;

CREATE OR REPLACE FUNCTION app.guard_work_item_assignee() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM app.users
     WHERE tenant_id=app.current_tenant() AND id=NEW.user_id AND status='active'
  ) THEN
    RAISE EXCEPTION 'assignee must be an active user';
  END IF;
  IF TG_OP='UPDATE'
     AND OLD.user_id=app.current_session_user()
     AND NEW.user_id=OLD.user_id
     AND NEW.work_item_id=OLD.work_item_id
     AND NEW.assignment_role=OLD.assignment_role THEN
    RETURN NEW;
  END IF;
  IF app.current_management_role() NOT IN ('owner','admin','manager') THEN
    RAISE EXCEPTION 'manager role required' USING ERRCODE='insufficient_privilege';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION app.guard_work_item_assignee() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_work_item_assignee() FROM PUBLIC;
CREATE TRIGGER trg_guard_work_item_assignee
  BEFORE INSERT OR UPDATE ON app.work_item_assignees
  FOR EACH ROW EXECUTE FUNCTION app.guard_work_item_assignee();

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['work_items','work_item_assignees'] LOOP
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

GRANT EXECUTE ON FUNCTION app.guard_work_item_assignee() TO app_rw;

COMMENT ON TABLE app.work_items IS
  '資産・リスク・インシデント・教育・外部リソース等の作業単位。個別レコードではなく作業を依頼する正本';
COMMENT ON TABLE app.work_item_assignees IS
  '作業に参加する複数メンバーと担当区分・進捗';

RESET ROLE;
