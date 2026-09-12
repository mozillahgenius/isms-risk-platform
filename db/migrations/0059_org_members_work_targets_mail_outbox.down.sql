SET ROLE schema_owner;

DROP FUNCTION IF EXISTS app.reclaim_stale_mail(integer);
DROP FUNCTION IF EXISTS app.mark_mail_failed(uuid,text);
DROP FUNCTION IF EXISTS app.mark_mail_sent(uuid);
DROP FUNCTION IF EXISTS app.claim_mail_batch(integer,boolean,boolean);
DROP FUNCTION IF EXISTS app.require_mail_worker();
DROP POLICY IF EXISTS tenant_security_definer ON app.external_questionnaires;
DROP FUNCTION IF EXISTS app.current_tenant_or_null();
-- Keep the roles (other DBs may be using them). They own nothing, so no harm.
REVOKE ALL ON SCHEMA app FROM mail_worker;

DROP TRIGGER IF EXISTS trg_guard_mail_outbox_update ON app.mail_outbox;
DROP FUNCTION IF EXISTS app.guard_mail_outbox_update();
DROP TRIGGER IF EXISTS trg_guard_mail_outbox ON app.mail_outbox;
DROP FUNCTION IF EXISTS app.guard_mail_outbox();
DROP TABLE IF EXISTS app.mail_outbox;

DROP TRIGGER IF EXISTS trg_guard_certification_body ON app.certification_bodies;
DROP FUNCTION IF EXISTS app.guard_org_settings();
DROP TRIGGER IF EXISTS trg_guard_org_department ON app.departments;
DROP FUNCTION IF EXISTS app.guard_org_department();
DROP TRIGGER IF EXISTS trg_guard_org_membership ON app.memberships;
DROP FUNCTION IF EXISTS app.guard_org_membership();

DROP TRIGGER IF EXISTS trg_guard_work_item_resource ON app.work_items;
DROP FUNCTION IF EXISTS app.guard_work_item_resource();
DROP INDEX IF EXISTS app.work_items_resource_idx;
ALTER TABLE app.work_items DROP CONSTRAINT IF EXISTS work_items_resource_pair;
ALTER TABLE app.work_items DROP COLUMN IF EXISTS resource_id;
ALTER TABLE app.work_items DROP COLUMN IF EXISTS resource_type;

DROP TRIGGER IF EXISTS trg_user_status_keeps_owner ON app.users;
DROP TRIGGER IF EXISTS trg_membership_keeps_owner ON app.memberships;
DROP FUNCTION IF EXISTS app.assert_owner_remains();
DROP FUNCTION IF EXISTS app.lock_owner_guard(uuid);
DROP TRIGGER IF EXISTS trg_guard_org_user ON app.users;
DROP FUNCTION IF EXISTS app.guard_org_user();
DROP FUNCTION IF EXISTS app.has_actor_context();

-- Restore 0057's body (drop the member_manage / department_manage / notify branches).
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

RESET ROLE;
