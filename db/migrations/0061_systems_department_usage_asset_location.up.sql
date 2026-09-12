-- 0061: register of systems in use / per-department usage / location of information assets
--
-- Background (measured):
--   - Information assets had no column equivalent to "location". Scanning all of
--     db/migrations for "location" (or its Japanese equivalents) finds nothing (the comment in 0020
--     and the external file reference in 0040 are different things).
--   - Meanwhile app.assets.owner_department_id already has both the column and the FK
--     since 0027, yet it is never used by any screen or query (0 hits with grep).
--   - app.application_catalog (0045) is only SELECTed; there is no INSERT/UPDATE
--     path. It sat empty as the parent for ID/license integration.
--
-- Policy: **do not create a 4th "system-like thing".**
--   There are already three: app.application_catalog (parent for ID integration),
--   app.vendors (outsourcees = business counterparties) and app.assets.asset_type
--   (free text). Adding yet another systems table here would list the same SaaS in
--   4 places under different names, and nobody could say which is authoritative.
--   Promote application_catalog to the source of truth for "systems in use" and give
--   it a write path. Do not reconcile it with vendors (systems in use and
--   counterparties are different axes).
--
--   So the only new table is app.department_systems.
--   It records "systems a department uses that are not yet registered as
--   information assets" and "how they are used", which cannot be expressed via assets.

SET ROLE schema_owner;

-- ------------------------------------------------------------------
-- (1) Every member can write systems in use
--
--   Write permission on the asset register (app.assets) stays with 0058's
--   require_work_permission. **Only the list of systems in use is relaxed.** What only
--   the front line knows is "which system is used for what", not the classification
--   of information assets or the assignment of ISO frameworks.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.require_system_edit_permission() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE v_role text := app.current_management_role();
BEGIN
  -- Auditors do not modify business data (same arrangement as the dual-role ban in 0005).
  -- Users with no membership (none) cannot write either.
  IF v_role IN ('none','auditor') THEN
    RAISE EXCEPTION 'system edit permission required' USING ERRCODE='insufficient_privilege';
  END IF;
END
$$;
ALTER FUNCTION app.require_system_edit_permission() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.require_system_edit_permission() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.require_system_edit_permission() TO app_rw;

-- **0045 explicitly revokes INSERT/UPDATE/DELETE on application_catalog from app_rw**
-- ("do not let provider-derived state be forged with ordinary DML ... write only after
-- adding a dedicated RPC and a provider worker role"). That control stays in place.
-- As 0045 foreshadowed, **add dedicated RPCs** and let only them write.
-- Provisioning (identity_principals / entitlement_assignments /
-- provisioning_requests) stays read-only and is left untouched.
--
-- 0045's CHECK constraints (regexes for app_key / provider, the provisioning_mode enum)
-- are not changed either. Rather than intruding on an already-applied table, callers
-- produce values that satisfy the constraints (derive app_key from the name, default provider to unknown).

-- SECURITY DEFINER runs as schema_owner. application_catalog is FORCE RLS,
-- so the owner needs a policy too. Compare with the variant that does not raise
-- when there is no context (same reason as 0059: keep the behavior from before the policy).
CREATE POLICY tenant_security_definer ON app.application_catalog FOR ALL TO schema_owner
  USING (tenant_id = app.current_tenant_or_null())
  WITH CHECK (tenant_id = app.current_tenant_or_null());

CREATE OR REPLACE FUNCTION app.create_system(
  p_app_key text, p_name text, p_provider text, p_status text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM app.require_system_edit_permission();
  INSERT INTO app.application_catalog
    (tenant_id, app_key, name, provider, status, created_by, updated_by)
  VALUES (app.current_tenant(), p_app_key, p_name, p_provider, p_status,
          app.current_session_user(), app.current_session_user())
  RETURNING id INTO v_id;
  RETURN v_id;
END
$$;
ALTER FUNCTION app.create_system(text,text,text,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.create_system(text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.create_system(text,text,text,text) TO app_rw;

-- app.assets is FORCE RLS and only has policies for app_rw / app_ro (0015).
-- Without one for the owner, the function below running as SECURITY DEFINER
-- (schema_owner) sees no asset rows at all, and the "used as a location" check is always false
-- (the same trap hit by 0057's assignment_target_exists; reproduced in acceptance tests).
-- Only reading is needed, so limit it to SELECT. Compare with the variant that does not raise
-- when there is no context, keeping the behavior from before the policy (0 rows).
CREATE POLICY tenant_security_definer_read ON app.assets FOR SELECT TO schema_owner
  USING (tenant_id = app.current_tenant_or_null());

CREATE OR REPLACE FUNCTION app.update_system(
  p_id uuid, p_name text, p_provider text, p_status text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  PERFORM app.require_system_edit_permission();
  -- Do not retire a system that is used as a location.
  -- Retiring it while still referenced yields a register saying "information lives in a place that no longer exists".
  IF p_status = 'retired' AND EXISTS (
    SELECT 1 FROM app.assets
     WHERE tenant_id = app.current_tenant() AND status = 'active'
       AND location_system_id = p_id
  ) THEN
    RAISE EXCEPTION 'system is still used as an asset location';
  END IF;
  UPDATE app.application_catalog
     SET name = p_name, provider = p_provider, status = p_status,
         updated_at = now(), updated_by = app.current_session_user()
   WHERE tenant_id = app.current_tenant() AND id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'system % not found', p_id;
  END IF;
END
$$;
ALTER FUNCTION app.update_system(uuid,text,text,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.update_system(uuid,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.update_system(uuid,text,text,text) TO app_rw;

CREATE OR REPLACE FUNCTION app.guard_application_catalog() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  -- Paths without context (migration scripts, connectors, tests) pass through.
  -- has_actor_context() rejects a tenant context with no actor (0059).
  IF NOT app.has_actor_context() THEN RETURN coalesce(NEW, OLD); END IF;
  PERFORM app.require_system_edit_permission();
  IF TG_OP <> 'DELETE' THEN
    NEW.updated_at := now();
    NEW.updated_by := app.current_session_user();
    -- Do not let the caller decide who the author is. With coalesce, the passed value
    -- would remain as-is, allowing forged audit info by writing another same-tenant user's ID.
    IF TG_OP = 'INSERT' THEN
      NEW.created_at := now();
      NEW.created_by := app.current_session_user();
    ELSE
      NEW.created_at := OLD.created_at;
      NEW.created_by := OLD.created_by;
    END IF;
  END IF;
  RETURN coalesce(NEW, OLD);
END
$$;
ALTER FUNCTION app.guard_application_catalog() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_application_catalog() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_application_catalog() TO app_rw;
CREATE TRIGGER trg_guard_application_catalog
  BEFORE INSERT OR UPDATE OR DELETE ON app.application_catalog
  FOR EACH ROW EXECUTE FUNCTION app.guard_application_catalog();

COMMENT ON TABLE app.application_catalog IS
  '利用システムの正本。ID・ライセンス連携の親であると同時に、各メンバーが登録する「うちが使っているシステム」の一覧。委託先の台帳（app.vendors）とは別の軸で、名寄せしない';

-- ------------------------------------------------------------------
-- (2) Which systems a department uses and how
--
--   "What information is handled" gets no separate register on the department side.
--   Once information assets (app.assets) have owner_department_id and a location,
--   department x system x information comes out by aggregation. A free-text information
--   register here would duplicate the asset register and inevitably diverge.
--   This table holds only "how it is used".
-- ------------------------------------------------------------------
CREATE TABLE app.department_systems (
  tenant_id      uuid NOT NULL,
  department_id  uuid NOT NULL,
  application_id uuid NOT NULL,
  usage_note     text NOT NULL DEFAULT '',
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid,
  PRIMARY KEY (tenant_id, department_id, application_id),
  FOREIGN KEY (tenant_id, department_id)  REFERENCES app.departments(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, application_id) REFERENCES app.application_catalog(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, created_by)     REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, updated_by)     REFERENCES app.users(tenant_id, id)
);

CREATE INDEX department_systems_application_idx
  ON app.department_systems (tenant_id, application_id);

COMMENT ON TABLE app.department_systems IS
  '部門がどのシステムをどう使っているか。扱っている情報そのものは書かない（情報資産台帳が正本）';

CREATE OR REPLACE FUNCTION app.guard_department_systems() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF NOT app.has_actor_context() THEN RETURN coalesce(NEW, OLD); END IF;
  PERFORM app.require_system_edit_permission();
  IF TG_OP <> 'DELETE' THEN
    NEW.updated_at := now();
    NEW.updated_by := app.current_session_user();
    -- Do not let the caller decide who the author is. With coalesce, the passed value
    -- would remain as-is, allowing forged audit info by writing another same-tenant user's ID.
    IF TG_OP = 'INSERT' THEN
      NEW.created_at := now();
      NEW.created_by := app.current_session_user();
    ELSE
      NEW.created_at := OLD.created_at;
      NEW.created_by := OLD.created_by;
    END IF;
  END IF;
  RETURN coalesce(NEW, OLD);
END
$$;
ALTER FUNCTION app.guard_department_systems() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_department_systems() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_department_systems() TO app_rw;
CREATE TRIGGER trg_guard_department_systems
  BEFORE INSERT OR UPDATE OR DELETE ON app.department_systems
  FOR EACH ROW EXECUTE FUNCTION app.guard_department_systems();

ALTER TABLE app.department_systems ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.department_systems FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.department_systems FOR ALL TO app_rw
  USING (tenant_id = app.current_tenant())
  WITH CHECK (tenant_id = app.current_tenant());
CREATE POLICY tenant_read ON app.department_systems FOR SELECT TO app_ro
  USING (tenant_id = app.current_tenant());
CREATE POLICY tenant_security_definer ON app.department_systems FOR ALL TO schema_owner
  USING (tenant_id = app.current_tenant_or_null())
  WITH CHECK (tenant_id = app.current_tenant_or_null());
REVOKE ALL ON app.department_systems FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.department_systems TO app_rw;
GRANT SELECT ON app.department_systems TO app_ro;

-- ------------------------------------------------------------------
-- (3) Location of information assets
--
--   The system is chosen via FK. With free text only, the same system gets written many
--   ways, and "which information is in this system" can no longer be looked up.
--   However, a location is not always a system (paper, safe, device, mail), so
--   location_note is kept alongside for locations the FK cannot express.
-- ------------------------------------------------------------------
ALTER TABLE app.assets
  ADD COLUMN location_system_id uuid,
  ADD COLUMN location_note text NOT NULL DEFAULT '';

ALTER TABLE app.assets
  ADD CONSTRAINT assets_location_system_fk
    FOREIGN KEY (tenant_id, location_system_id)
    REFERENCES app.application_catalog(tenant_id, id);

CREATE INDEX assets_location_system_idx
  ON app.assets (tenant_id, location_system_id)
  WHERE location_system_id IS NOT NULL;

COMMENT ON COLUMN app.assets.location_system_id IS
  '所在場所のうち、利用システム（app.application_catalog）で表せるもの';
COMMENT ON COLUMN app.assets.location_note IS
  '所在場所のうち、システムでは表せないもの（紙・保管庫・端末・郵送物など）';

RESET ROLE;
