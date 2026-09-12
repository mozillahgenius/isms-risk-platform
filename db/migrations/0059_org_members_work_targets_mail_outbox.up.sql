-- @run-as: admin
-- 0059: Organization and member management / linking work to records / mail send queue
--
-- Background (measured):
--   (1) navigation.ts shows /organization in both RISK and ISMS modes, yet
--       web/src/app/organization/ was empty and returned 404 (deleted in 27c56ef). In restoring
--       the screen, we also let it handle "adding and suspending members", which the screen
--       never had. app.set_tenant_context_for_proxy (0050) only admits "people with status='active' and
--       exactly one valid membership", so the member table is effectively the access-rights
--       list. Who may touch it is enforced on the DB side too.
--   (2) app.work_items in 0058 holds only the unit of work, not which record the work is
--       about. app.work_assignments in 0057 is per record but can hold only one person,
--       which would mean two ledgers. Here work_items carries the target record, consolidating
--       the ledger into work_items alone (work_assignments is left as in 0057).
--   (3) "Sending" external questionnaires and request notifications both exit through one channel: mail. Rather than a table
--       per destination, everything goes into a single send queue, app.mail_outbox.
--
-- Policy: DML is done by the application (management_web = app_rw); this migration
--   puts only "who may do it" and "never allowing a broken state" on the DB side.
--   app.users / app.memberships are under FORCE RLS and schema_owner has only SELECT
--   policies on them (ctx_*_lookup in 0005), so a SECURITY DEFINER function cannot
--   write to them. Same shape as 0057 / 0058 (checks in functions, writes in the app)
--   for consistency.

SET ROLE schema_owner;

-- ------------------------------------------------------------------
-- (1) Add member_manage / department_manage / notify to the permission check
--     Carries over the 0057 body as-is and only adds branches. So that there are not two
--     permission checks, new screens also look only here.
-- ------------------------------------------------------------------
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
  -- Registering, suspending and reactivating members, and creating/retiring departments, are for owners and admins only.
  -- Managers can make requests for their own department but do not decide who joins or leaves.
  -- People joining/leaving (member_manage) and the organization's shape, scope and certification body (org_manage)
  -- are for owners and admins only. Managers can make requests for their own department but decide neither
  -- joining/leaving nor the organization's shape. Reassigning management roles themselves is role_manage (owner).
  IF p_action IN ('member_manage','org_manage') AND v_role NOT IN ('owner','admin') THEN
    RAISE EXCEPTION 'admin role required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF p_action = 'questionnaire_send' AND v_role NOT IN ('owner','admin') THEN
    RAISE EXCEPTION 'admin role required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF p_action IN ('assign','create','questionnaire_manage','notify')
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

-- ------------------------------------------------------------------
-- (2) Member management invariants
--
--   Paths without a context (app.provision_tenant in 0021 stays SECURITY DEFINER and
--   INSERTs into app.users without setting app.tenant_id; migration scripts and
--   tests/*.sh do the same) pass through. Only writes coming from the screens are
--   constrained here. Constraining without a context would break tenant creation itself.
-- ------------------------------------------------------------------
-- A state where a tenant context exists but the actor is not set is NOT passed through.
--
-- If it were, app_rw could create a context with set_tenant_context, then
-- clear only the actor with set_config('app.session_user_id',''), after which this function returns
-- false and the guard is bypassed entirely (Codex finding).
-- The only case allowed through is "no tenant context at all"
-- = app.provision_tenant (0021), migration scripts, and direct writes in tests/*.sh.
-- The legitimate paths (app.set_tenant_context / set_tenant_context_for_proxy)
-- always set tenant and session_user together, so a half-set state never arises.
CREATE OR REPLACE FUNCTION app.has_actor_context() RETURNS boolean
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, app AS $$
BEGIN
  IF coalesce(pg_catalog.current_setting('app.tenant_id', true), '') = '' THEN
    RETURN false;
  END IF;
  IF coalesce(pg_catalog.current_setting('app.session_user_id', true), '') = '' THEN
    RAISE EXCEPTION 'session user context is required' USING ERRCODE='insufficient_privilege';
  END IF;
  RETURN true;
END
$$;
ALTER FUNCTION app.has_actor_context() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.has_actor_context() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.has_actor_context() TO app_rw, app_ro;

CREATE OR REPLACE FUNCTION app.guard_org_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF NOT app.has_actor_context() THEN RETURN NEW; END IF;
  PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'member_manage');
  RETURN NEW;
END
$$;
ALTER FUNCTION app.guard_org_user() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_org_user() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_org_user() TO app_rw;
CREATE TRIGGER trg_guard_org_user
  BEFORE INSERT OR UPDATE ON app.users
  FOR EACH ROW EXECUTE FUNCTION app.guard_org_user();

-- Reject operations that would leave zero owners (ciso). With zero owners,
-- role_manage in require_management_permission passes for nobody, and
-- permissions can never be restored from the screens (verified by measurement).
-- The owner-count check is serialized per tenant.
-- If two transactions each demote a different owner, each sees "the other one remains"
-- and both pass, leaving zero owners. Ordering them with an advisory lock makes
-- the later one recount after seeing the earlier result (under READ COMMITTED a new statement
-- takes a new snapshot, so committed changes are visible).
CREATE OR REPLACE FUNCTION app.lock_owner_guard(p_tenant uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
  SELECT pg_catalog.pg_advisory_xact_lock(
           pg_catalog.hashtext('app.owner_guard'), pg_catalog.hashtext(p_tenant::text))
$$;
ALTER FUNCTION app.lock_owner_guard(uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.lock_owner_guard(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.lock_owner_guard(uuid) TO app_rw;

CREATE OR REPLACE FUNCTION app.assert_owner_remains() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE v_tenant uuid := coalesce(OLD.tenant_id, NEW.tenant_id);
BEGIN
  PERFORM app.lock_owner_guard(v_tenant);
  -- A tenant with no remaining memberships is being dismantled or not yet created. There is no
  -- organization to protect, so say nothing (cleanup in tests/rls_test.sh and the
  -- intermediate state of app.provision_tenant land here). The path the screens use is an update setting revoked_at,
  -- where other memberships remain, so this escape hatch cannot be used there.
  IF NOT EXISTS (
    SELECT 1 FROM app.memberships m
     WHERE m.tenant_id=v_tenant AND m.revoked_at IS NULL
  ) THEN
    RETURN NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM app.memberships m JOIN app.users u
      ON u.tenant_id=m.tenant_id AND u.id=m.user_id
     WHERE m.tenant_id=v_tenant AND m.role_key='ciso'
       AND m.revoked_at IS NULL AND u.status='active'
  ) THEN
    RAISE EXCEPTION 'tenant must keep at least one active owner';
  END IF;
  RETURN NULL;
END
$$;
ALTER FUNCTION app.assert_owner_remains() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.assert_owner_remains() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.assert_owner_remains() TO app_rw;

CREATE CONSTRAINT TRIGGER trg_membership_keeps_owner
  AFTER UPDATE OR DELETE ON app.memberships
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW WHEN (OLD.role_key='ciso' AND OLD.revoked_at IS NULL)
  EXECUTE FUNCTION app.assert_owner_remains();

CREATE CONSTRAINT TRIGGER trg_user_status_keeps_owner
  AFTER UPDATE ON app.users
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW WHEN (OLD.status='active' AND NEW.status <> 'active')
  EXECUTE FUNCTION app.assert_owner_remains();

-- Constrain reassignment of memberships (= the permissions themselves) on the DB side too.
-- app_rw has all DML on app.memberships since 0015, so through paths that bypass Server Actions
-- (another screen's code, a mixed-up SQL statement) a member could add ciso to
-- themselves. Granting/removing owner requires role_manage (owner); any other
-- membership change requires member_manage (owner, admin).
CREATE OR REPLACE FUNCTION app.guard_org_membership() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF NOT app.has_actor_context() THEN RETURN coalesce(NEW, OLD); END IF;
  -- **Look at both old and new.** Looking only at NEW, an update rewriting a ciso row to employee
  -- would pass with member_manage, letting an admin demote an owner
  -- (revoking owner, not just granting it, is role_manage's domain).
  IF NEW.role_key = 'ciso' OR OLD.role_key = 'ciso' THEN
    PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'role_manage');
  ELSE
    PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'member_manage');
  END IF;
  RETURN coalesce(NEW, OLD);
END
$$;
ALTER FUNCTION app.guard_org_membership() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_org_membership() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_org_membership() TO app_rw;
CREATE TRIGGER trg_guard_org_membership
  BEFORE INSERT OR UPDATE OR DELETE ON app.memberships
  FOR EACH ROW EXECUTE FUNCTION app.guard_org_membership();

CREATE OR REPLACE FUNCTION app.guard_org_department() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF NOT app.has_actor_context() THEN RETURN coalesce(NEW, OLD); END IF;
  PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'org_manage');
  RETURN coalesce(NEW, OLD);
END
$$;
ALTER FUNCTION app.guard_org_department() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_org_department() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_org_department() TO app_rw;
CREATE TRIGGER trg_guard_org_department
  BEFORE INSERT OR UPDATE OR DELETE ON app.departments
  FOR EACH ROW EXECUTE FUNCTION app.guard_org_department();

-- The organization's scope and certification-body information sit behind the same boundary. Anyone could write them from the screens.
CREATE OR REPLACE FUNCTION app.guard_org_settings() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF NOT app.has_actor_context() THEN RETURN coalesce(NEW, OLD); END IF;
  PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'org_manage');
  RETURN coalesce(NEW, OLD);
END
$$;
ALTER FUNCTION app.guard_org_settings() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_org_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_org_settings() TO app_rw;
CREATE TRIGGER trg_guard_certification_body
  BEFORE INSERT OR UPDATE OR DELETE ON app.certification_bodies
  FOR EACH ROW EXECUTE FUNCTION app.guard_org_settings();

-- ------------------------------------------------------------------
-- (3) Link work down to "which record it is about"
--     The ledger stays work_items alone. Both NULL (work not tied to a record) is also
--     allowed (e.g. a company-wide asset inventory).
-- ------------------------------------------------------------------
ALTER TABLE app.work_items
  ADD COLUMN resource_type text,
  ADD COLUMN resource_id uuid;

ALTER TABLE app.work_items
  ADD CONSTRAINT work_items_resource_pair
    CHECK ((resource_type IS NULL) = (resource_id IS NULL));

CREATE INDEX work_items_resource_idx
  ON app.work_items (tenant_id, resource_type, resource_id)
  WHERE resource_type IS NOT NULL;

COMMENT ON COLUMN app.work_items.resource_type IS
  '対象レコードの種別（asset/risk/measure/incident/training/vendor/vendor_assessment）。作業全体への依頼なら NULL';

-- **Not SECURITY DEFINER.** app.assignment_target_exists in 0057 is
-- SECURITY DEFINER and runs as schema_owner, but app.assets etc. are under FORCE ROW
-- LEVEL SECURITY with policies only for app_rw / app_ro (0015).
-- With no owner policy, that function always returns false (measured).
-- Here existence is checked with the caller's (app_rw) privileges.
CREATE OR REPLACE FUNCTION app.guard_work_item_resource() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE v_exists boolean;
BEGIN
  IF NEW.resource_type IS NULL THEN RETURN NEW; END IF;
  -- Do not allow a resource type that mismatches the work type. On a mismatch,
  -- require_work_permission looks at a different work type and wrongly grants or denies.
  IF app.work_type_for_resource(NEW.resource_type) IS DISTINCT FROM NEW.work_type THEN
    RAISE EXCEPTION 'resource type does not match work type';
  END IF;
  CASE NEW.resource_type
    WHEN 'asset' THEN
      SELECT EXISTS (SELECT 1 FROM app.assets
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id AND status='active') INTO v_exists;
    WHEN 'risk' THEN
      SELECT EXISTS (SELECT 1 FROM app.risk_scenarios
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id AND status='active') INTO v_exists;
    WHEN 'measure' THEN
      SELECT EXISTS (SELECT 1 FROM app.measures
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id AND status <> 'retired') INTO v_exists;
    WHEN 'incident' THEN
      SELECT EXISTS (SELECT 1 FROM app.incidents
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id) INTO v_exists;
    WHEN 'training' THEN
      SELECT EXISTS (SELECT 1 FROM app.trainings
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id) INTO v_exists;
    WHEN 'vendor' THEN
      SELECT EXISTS (SELECT 1 FROM app.vendors
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id) INTO v_exists;
    WHEN 'vendor_assessment' THEN
      SELECT EXISTS (SELECT 1 FROM app.vendor_assessments
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id) INTO v_exists;
    ELSE
      v_exists := false;
  END CASE;
  IF NOT v_exists THEN
    RAISE EXCEPTION 'assignment target not found';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION app.guard_work_item_resource() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_work_item_resource() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_work_item_resource() TO app_rw;
CREATE TRIGGER trg_guard_work_item_resource
  BEFORE INSERT OR UPDATE ON app.work_items
  FOR EACH ROW EXECUTE FUNCTION app.guard_work_item_resource();

-- ------------------------------------------------------------------
-- (4) Mail send queue
--
--   The web process holds no SMTP credentials. The screens only enqueue a "send";
--   actual sending is done by scripts/send_mail_outbox.py in a separate process.
--   The ISMS in-scope system itself thus has no direct outbound channel to the outside.
-- ------------------------------------------------------------------
CREATE TABLE app.mail_outbox (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  purpose       text NOT NULL CHECK (purpose IN ('external_questionnaire','work_assignment')),
  to_email      citext NOT NULL,
  to_name       text NOT NULL DEFAULT '',
  subject       text NOT NULL CHECK (length(btrim(subject)) > 0),
  body_text     text NOT NULL CHECK (length(btrim(body_text)) > 0),
  related_type  text,
  related_id    uuid,
  status        text NOT NULL DEFAULT 'queued'
                CHECK (status IN ('queued','sending','sent','failed','cancelled')),
  attempts      integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error    text NOT NULL DEFAULT '',
  queued_at     timestamptz NOT NULL DEFAULT now(),
  sent_at       timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    uuid,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES app.users(tenant_id, id),
  CHECK (to_email = lower(to_email::text)),
  CHECK (length(to_email::text) BETWEEN 3 AND 254),
  CHECK (status <> 'sent' OR sent_at IS NOT NULL),
  -- The send worker processes psql output. If control characters get into the recipient name or subject,
  -- they are read as delimiters and the row is silently dropped (= it vanishes while still
  -- pending). These values also go into headers, so they are not allowed at all.
  CHECK (to_email::text ~ '^[^[:cntrl:][:space:]]+$'),
  CHECK (to_name ~ '^[^[:cntrl:]]*$'),
  CHECK (subject ~ '^[^[:cntrl:]]*$'),
  -- The body allows only newlines and tabs.
  CHECK (body_text ~ '^([^[:cntrl:]]|[\n\t])*$')
);

CREATE INDEX mail_outbox_pending_idx
  ON app.mail_outbox (tenant_id, status, queued_at)
  WHERE status IN ('queued','sending');
CREATE INDEX mail_outbox_related_idx
  ON app.mail_outbox (tenant_id, related_type, related_id);

COMMENT ON TABLE app.mail_outbox IS
  '外部質問票の送付と依頼通知の送信キュー。Web は積むだけで、送信は別プロセス';

-- Only the enqueuing side checks permissions. The send worker (app_rw + tenant context only, no actor identity)
-- advances status, so UPDATE does not go through this check.
CREATE OR REPLACE FUNCTION app.guard_mail_outbox() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  -- **The enqueuing side cannot specify delivery state.** Without pinning it here, even with UPDATE
  -- blocked, simply INSERTing status='sent', sent_at=now() would
  -- create a "sent" record (the send record would not be evidence).
  -- An enqueued row always starts queued, with 0 attempts, no error, and not sent.
  NEW.status := 'queued';
  NEW.attempts := 0;
  NEW.last_error := '';
  NEW.sent_at := NULL;
  NEW.queued_at := now();
  NEW.created_at := now();
  NEW.updated_at := now();
  -- The send queue has no bootstrap path (neither tenant creation nor migrations enqueue mail).
  -- Never allow rows whose enqueuer is unknown, and always run the permission check.
  IF NOT app.has_actor_context() THEN
    RAISE EXCEPTION 'queued mail requires an actor context' USING ERRCODE='insufficient_privilege';
  END IF;
  NEW.created_by := app.current_session_user();
  NEW.updated_by := app.current_session_user();
  IF NEW.purpose = 'external_questionnaire' THEN
    PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'questionnaire_send');
  ELSE
    PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'notify');
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION app.guard_mail_outbox() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_mail_outbox() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_mail_outbox() TO app_rw;
CREATE TRIGGER trg_guard_mail_outbox
  BEFORE INSERT ON app.mail_outbox
  FOR EACH ROW EXECUTE FUNCTION app.guard_mail_outbox();

-- Prevent rewriting the content after enqueueing. Recipient, subject, body, purpose and
-- related target are immutable. The send worker may only advance the state and attempt record.
-- Without this, something never sent could be marked "sent", and it would not serve as audit evidence.
CREATE OR REPLACE FUNCTION app.guard_mail_outbox_update() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.purpose IS DISTINCT FROM OLD.purpose
     OR NEW.to_email IS DISTINCT FROM OLD.to_email
     OR NEW.to_name IS DISTINCT FROM OLD.to_name
     OR NEW.subject IS DISTINCT FROM OLD.subject
     OR NEW.body_text IS DISTINCT FROM OLD.body_text
     OR NEW.related_type IS DISTINCT FROM OLD.related_type
     OR NEW.related_id IS DISTINCT FROM OLD.related_id
     OR NEW.queued_at IS DISTINCT FROM OLD.queued_at
     OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
    RAISE EXCEPTION 'queued mail is immutable except for its delivery state';
  END IF;
  -- State can only move in the defined order; in particular, sent can only be entered from sending.
  -- If this were open, just writing status='sent' and
  -- sent_at=now() without sending a single message would create a "sent" record,
  -- and the send queue would not hold up as evidence. Only the send worker that grabbed the row with
  -- FOR UPDATE SKIP LOCKED can set sending.
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (
         (OLD.status = 'queued'  AND NEW.status IN ('sending','cancelled'))
      OR (OLD.status = 'sending' AND NEW.status IN ('sent','failed'))
      OR (OLD.status = 'failed'  AND NEW.status IN ('sending','cancelled'))
    ) THEN
      RAISE EXCEPTION 'illegal mail state transition: % -> %', OLD.status, NEW.status;
    END IF;
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'delivery attempts cannot decrease';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION app.guard_mail_outbox_update() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_mail_outbox_update() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_mail_outbox_update() TO app_rw;
CREATE TRIGGER trg_guard_mail_outbox_update
  BEFORE UPDATE ON app.mail_outbox
  FOR EACH ROW EXECUTE FUNCTION app.guard_mail_outbox_update();

ALTER TABLE app.mail_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.mail_outbox FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.mail_outbox FOR ALL TO app_rw
  USING (tenant_id = app.current_tenant())
  WITH CHECK (tenant_id = app.current_tenant());
CREATE POLICY tenant_read ON app.mail_outbox FOR SELECT TO app_ro
  USING (tenant_id = app.current_tenant());
CREATE POLICY tenant_security_definer ON app.mail_outbox FOR ALL TO schema_owner
  USING (tenant_id = app.current_tenant())
  WITH CHECK (tenant_id = app.current_tenant());
REVOKE ALL ON app.mail_outbox FROM PUBLIC;
-- **Do not grant UPDATE to app_rw.** The web only "enqueues".
-- Only the send worker may advance state, and it does so through the SECURITY DEFINER functions below
-- (callable only by mail_worker). Leaving UPDATE with app_rw would let it write
-- queued->sending->sent without sending anything and create a "sent" record.
-- DELETE is not granted either (a deletable audit log is not evidence).
GRANT SELECT, INSERT ON app.mail_outbox TO app_rw;
GRANT SELECT ON app.mail_outbox TO app_ro;

-- ------------------------------------------------------------------
-- (5) Send worker boundary
--
--   Same shape as management_web in 0050. A dedicated role is created, and only SECURITY DEFINER
--   functions callable solely by that role can advance the send queue's state.
--   Without a separate role, "permission to send" and "permission to write business data" would be the same,
--   and a single defect on the web side would directly become forgery of send records.
-- ------------------------------------------------------------------
-- schema_owner cannot create roles (it lacks CREATEROLE).
-- As 0050 does for management_web, switch back to the executor (admin) just here.
RESET ROLE;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='mail_worker') THEN
    CREATE ROLE mail_worker;
    COMMENT ON ROLE mail_worker IS 'created-by:isms-platform-migration';
  END IF;
  ALTER ROLE mail_worker LOGIN INHERIT NOSUPERUSER NOBYPASSRLS
    NOCREATEDB NOCREATEROLE NOREPLICATION;
END $$;
-- If a role with the same name already exists and inherits business roles, the boundary is meaningless
-- (inheriting app_rw would allow UPDATEing the send queue directly). ALTER ROLE only changes
-- attributes, so memberships are revoked explicitly, and we stop if any remain.
REVOKE app_rw, app_ro, auth_svc, management_web, schema_owner FROM mail_worker;
DO $$
DECLARE v_roles text;
BEGIN
  SELECT string_agg(r.rolname, ', ') INTO v_roles
    FROM pg_auth_members m
    JOIN pg_roles r ON r.oid = m.roleid
    JOIN pg_roles w ON w.oid = m.member
   WHERE w.rolname = 'mail_worker';
  IF v_roles IS NOT NULL THEN
    RAISE EXCEPTION 'mail_worker must not inherit other roles (still a member of: %)', v_roles;
  END IF;
END $$;
SET ROLE schema_owner;

GRANT USAGE ON SCHEMA app TO mail_worker;
GRANT EXECUTE ON FUNCTION app.set_tenant_context(text) TO mail_worker;
GRANT EXECUTE ON FUNCTION app.current_tenant() TO mail_worker;
GRANT SELECT ON app.mail_outbox TO mail_worker;
CREATE POLICY tenant_worker_read ON app.mail_outbox FOR SELECT TO mail_worker
  USING (tenant_id = app.current_tenant());

-- Advancing a questionnaire to "sent" is done from SECURITY DEFINER (schema_owner).
-- 0057 created no owner policy, so it is added here.
--
-- **Written so it does not throw when there is no context.** app.current_tenant() RAISEs when unset,
-- so an owner policy using it would make the validation scan of a later ALTER TABLE ... ADD FOREIGN KEY
-- (which runs as the owner) fail there (actually hit when adding template_id in 0060).
-- Comparing against a NULL-returning version means that without a context no rows are visible, and
-- nothing more = the same behavior as before the policy existed.
--
-- SELECT is needed too. An UPDATE with WHERE also uses the SELECT policy to scan rows,
-- so an UPDATE policy alone yields 0 rows (measured).
CREATE OR REPLACE FUNCTION app.current_tenant_or_null() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  RETURN app.current_tenant();
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END
$$;
ALTER FUNCTION app.current_tenant_or_null() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.current_tenant_or_null() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.current_tenant_or_null() TO app_rw, app_ro, mail_worker;

CREATE POLICY tenant_security_definer ON app.external_questionnaires FOR ALL TO schema_owner
  USING (tenant_id = app.current_tenant_or_null())
  WITH CHECK (tenant_id = app.current_tenant_or_null());

CREATE OR REPLACE FUNCTION app.require_mail_worker() RETURNS void
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, app AS $$
BEGIN
  -- session_user is a keyword, not a function, so it cannot be schema-qualified.
  IF session_user <> 'mail_worker' THEN
    RAISE EXCEPTION 'mail worker role required' USING ERRCODE='insufficient_privilege';
  END IF;
END
$$;
ALTER FUNCTION app.require_mail_worker() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.require_mail_worker() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.require_mail_worker() TO mail_worker;

-- Take the rows to send and advance them to sending at the same time. Contention is
-- resolved with FOR UPDATE SKIP LOCKED (two processes never send the same row).
CREATE OR REPLACE FUNCTION app.claim_mail_batch(
  p_limit integer, p_retry_failed boolean, p_retry_unconfirmed boolean
) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE v_result json;
BEGIN
  PERFORM app.require_mail_worker();
  WITH picked AS (
    SELECT id FROM app.mail_outbox
     WHERE tenant_id=app.current_tenant()
       AND (status='queued'
            OR (p_retry_failed AND status='failed'
                AND (p_retry_unconfirmed
                     OR coalesce(last_error,'') NOT LIKE '[unconfirmed]%')))
     ORDER BY queued_at
     LIMIT greatest(1, least(coalesce(p_limit, 50), 50))
     FOR UPDATE SKIP LOCKED
  ), claimed AS (
    UPDATE app.mail_outbox m
       SET status='sending', attempts=m.attempts+1, updated_at=now()
      FROM picked
     WHERE m.tenant_id=app.current_tenant() AND m.id=picked.id
    RETURNING m.id, m.purpose, m.to_email, m.to_name, m.subject,
              m.body_text, m.related_type, m.related_id
  )
  SELECT coalesce(json_agg(json_build_object(
           'id', id::text, 'purpose', purpose, 'to_email', to_email::text,
           'to_name', to_name, 'subject', subject, 'body_text', body_text,
           'related_type', coalesce(related_type,''),
           'related_id', coalesce(related_id::text,''))), '[]'::json)
    INTO v_result FROM claimed;
  RETURN v_result;
END
$$;
ALTER FUNCTION app.claim_mail_batch(integer,boolean,boolean) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.claim_mail_batch(integer,boolean,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.claim_mail_batch(integer,boolean,boolean) TO mail_worker;

-- Mark as sent only what actually went out. Advance the questionnaire at the same time.
CREATE OR REPLACE FUNCTION app.mark_mail_sent(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE v_purpose text; v_related_type text; v_related_id uuid;
BEGIN
  PERFORM app.require_mail_worker();
  UPDATE app.mail_outbox
     SET status='sent', sent_at=now(), last_error='', updated_at=now()
   WHERE tenant_id=app.current_tenant() AND id=p_id AND status='sending'
  RETURNING purpose, related_type, related_id
      INTO v_purpose, v_related_type, v_related_id;
  IF v_purpose IS NULL THEN
    RAISE EXCEPTION 'mail % is not in sending state', p_id;
  END IF;
  IF v_purpose='external_questionnaire' AND v_related_type='external_questionnaire' THEN
    UPDATE app.external_questionnaires
       SET status='sent', sent_at=now(), updated_at=now()
     WHERE tenant_id=app.current_tenant() AND id=v_related_id AND status='queued';
  END IF;
END
$$;
ALTER FUNCTION app.mark_mail_sent(uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.mark_mail_sent(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.mark_mail_sent(uuid) TO mail_worker;

CREATE OR REPLACE FUNCTION app.mark_mail_failed(p_id uuid, p_error text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  PERFORM app.require_mail_worker();
  UPDATE app.mail_outbox
     SET status='failed',
         last_error=left(regexp_replace(coalesce(p_error,''), '[[:cntrl:]]', ' ', 'g'), 500),
         updated_at=now()
   WHERE tenant_id=app.current_tenant() AND id=p_id AND status='sending';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'mail % is not in sending state', p_id;
  END IF;
END
$$;
ALTER FUNCTION app.mark_mail_failed(uuid,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.mark_mail_failed(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.mark_mail_failed(uuid,text) TO mail_worker;

-- Reclaim rows left in sending after a crash right after claiming. **No resend.**
-- Only this function sets the marker, and last_error cannot be written from outside the function, so
-- even the worker role cannot remove [unconfirmed] to put a row back into the resend set.
CREATE OR REPLACE FUNCTION app.reclaim_stale_mail(p_minutes integer) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE v_result json;
BEGIN
  PERFORM app.require_mail_worker();
  IF p_minutes IS NULL OR p_minutes < 60 THEN
    RAISE EXCEPTION 'reclaim threshold must be at least 60 minutes';
  END IF;
  WITH stale AS (
    UPDATE app.mail_outbox
       SET status='failed',
           last_error='[unconfirmed] 送信中のまま停止。実際に送られたか確認してから再送してください',
           updated_at=now()
     WHERE tenant_id=app.current_tenant() AND status='sending'
       AND updated_at < now() - make_interval(mins => p_minutes)
    RETURNING id
  )
  SELECT coalesce(json_agg(json_build_object('id', id::text)), '[]'::json)
    INTO v_result FROM stale;
  RETURN v_result;
END
$$;
ALTER FUNCTION app.reclaim_stale_mail(integer) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.reclaim_stale_mail(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.reclaim_stale_mail(integer) TO mail_worker;

RESET ROLE;

