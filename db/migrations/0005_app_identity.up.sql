-- 0005 app: tenants, people, roles (design doc 2.3)
-- tenants → users → departments → memberships → sessions
-- The order differs from the design doc: departments is created before memberships (dependency order).

CREATE TABLE app.tenants (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  domain        text NOT NULL,                    -- primary domain
  fiscal_start_month smallint NOT NULL DEFAULT 4
                  CHECK (fiscal_start_month BETWEEN 1 AND 12),
  industry_preset text NOT NULL DEFAULT 'general',
  dom_version_id  uuid NOT NULL REFERENCES catalog.dom_versions(id),
  status        text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','suspended','closed')),
  created_at    timestamptz NOT NULL DEFAULT now()
);
-- app.tenants has no tenant_id of its own (id is that). 0015's bulk RLS application
-- targets only tables with a tenant_id column, so it is set explicitly here.
ALTER TABLE app.tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.tenants FOR ALL TO app_rw
  USING (id = app.current_tenant()) WITH CHECK (id = app.current_tenant());
CREATE POLICY tenant_read ON app.tenants FOR SELECT TO app_ro
  USING (id = app.current_tenant());

CREATE TABLE app.users (
  id           uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES app.tenants(id),
  email        citext NOT NULL,
  display_name text NOT NULL,
  status       text NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','suspended','left')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, email)
);

CREATE TABLE app.departments (
  id        uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  name      text NOT NULL,
  parent_id uuid,
  owner_user_id uuid,                              -- risk owner
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, parent_id)     REFERENCES app.departments(tenant_id, id),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id)
);

CREATE TABLE app.memberships (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL,
  user_id     uuid NOT NULL,
  role_key    text NOT NULL REFERENCES catalog.roles_default(key),
  department_id uuid,
  granted_by  uuid, granted_at timestamptz NOT NULL DEFAULT now(),
  revoked_at  timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, user_id)       REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, department_id) REFERENCES app.departments(tenant_id, id),
  UNIQUE (tenant_id, user_id, role_key)
);

-- Auditors cannot hold other roles (design doc 1.3 / acceptance #14)
CREATE OR REPLACE FUNCTION app.check_auditor_exclusivity() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM app.memberships m
    WHERE m.tenant_id = NEW.tenant_id AND m.user_id = NEW.user_id
      AND m.revoked_at IS NULL AND m.id <> NEW.id
      AND (m.role_key = 'auditor') <> (NEW.role_key = 'auditor')
  ) THEN
    RAISE EXCEPTION 'auditor role cannot be combined with other roles';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_auditor_exclusivity BEFORE INSERT OR UPDATE ON app.memberships
  FOR EACH ROW WHEN (NEW.revoked_at IS NULL)
  EXECUTE FUNCTION app.check_auditor_exclusivity();

-- ------------------------------------------------------------------
-- app.sessions
--
-- The design doc has only id (uuid), but then "anyone who knows another person's session UUID
-- can switch into another tenant". To tie set_tenant_context's argument to a secret held by the caller,
-- we store the hash of a bearer token (a deviation from the design doc;
-- rationale in docs/DECISIONS.md D-02). Raw tokens are never stored in the DB.
--
-- This table is "definer-only". app_rw / app_ro get no table privileges at all
-- (excluded from 0015's bulk GRANT). Reads/writes go only through the SECURITY DEFINER
-- functions in 0006. The owner schema_owner is also subject to FORCE RLS, so a dedicated policy
-- lets the definer read it (without it, set_tenant_context could not
-- validate its own argument: a chicken-and-egg problem).
-- ------------------------------------------------------------------
CREATE TABLE app.sessions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL,
  user_id    uuid NOT NULL,
  token_hash bytea NOT NULL UNIQUE
               CHECK (octet_length(token_hash) = 32),   -- sha256
  issued_at  timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  FOREIGN KEY (tenant_id, user_id) REFERENCES app.users(tenant_id, id),
  CHECK (expires_at > issued_at)
);
CREATE INDEX sessions_active ON app.sessions (tenant_id, user_id)
  WHERE revoked_at IS NULL;

ALTER TABLE app.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.sessions FORCE ROW LEVEL SECURITY;
-- Only the definer (schema_owner) can look up sessions across all tenants.
-- No policies for app_rw / app_ro (they get no table privileges at all).
CREATE POLICY ctx_session_lookup ON app.sessions FOR ALL TO schema_owner
  USING (true) WITH CHECK (true);

-- For the same reason, memberships / users / tenants are made readable by the definer before the context is established.
-- set_tenant_context and create_session in 0006 read these 3 tables to verify that the session owner and
-- the tenant are valid. FORCE RLS applies to the owner too, so
-- without policies the definer "sees nothing", and
-- even a correct token is judged to have "no valid membership" (hit in practice).
CREATE POLICY ctx_membership_lookup ON app.memberships FOR SELECT TO schema_owner
  USING (true);
CREATE POLICY ctx_user_lookup ON app.users FOR SELECT TO schema_owner
  USING (true);
CREATE POLICY ctx_tenant_lookup ON app.tenants FOR SELECT TO schema_owner
  USING (true);
