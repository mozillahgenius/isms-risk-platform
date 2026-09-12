-- @run-as: admin
-- 0001 initialization (design doc 2.2). Extensions, schemas, roles, provisional tenant-context functions.
--
-- Only this file runs as superuser. CREATE EXTENSION and CREATE ROLE do not
-- work with schema_owner privileges. From 0002 on, SET ROLE schema_owner.

CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_uuid(), hmac(), digest()
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- for uuid equality in EXCLUDE constraints
CREATE EXTENSION IF NOT EXISTS citext;      -- case-insensitive comparison of email addresses

CREATE SCHEMA IF NOT EXISTS catalog;        -- DOM (shared master; no tenant_id)
CREATE SCHEMA IF NOT EXISTS app;            -- tenant data
CREATE SCHEMA IF NOT EXISTS audit;          -- audit log

-- Roles (design doc 9.1). None of them get BYPASSRLS.
-- schema_owner is DDL-only and also owns SECURITY DEFINER functions, so
-- it has no LOGIN (and no path to SET ROLE into it from app_rw/app_ro is created).
-- In environments where roles of the same name already exist (reused dev machines, etc.), attributes may not match the design.
-- CREATE alone leaves an existing role's SUPERUSER / BYPASSRLS in place, so always pin them with ALTER.
DO $$
DECLARE
  r record;
  -- auth_svc is an extra role not in design doc 9.1. It only issues sessions.
  -- If app_rw had issuing privileges, app_rw could create a session for any tenant,
  -- establish context with that token, and tenant isolation would be void entirely (docs/DECISIONS.md D-12).
  roles constant text[] := ARRAY['schema_owner','app_rw','app_ro','auth_svc',
                                 'auditlogd','audit_verifier'];
  logins constant text[] := ARRAY['app_rw','app_ro','auth_svc','auditlogd','audit_verifier'];
  name text;
BEGIN
  FOREACH name IN ARRAY roles LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = name) THEN
      EXECUTE format('CREATE ROLE %I', name);
      -- Leave a marker that this is "a role created by this migration".
      -- down drops only roles with this marker, so as not to delete a pre-existing role
      -- and take its owned objects down with it (DROP OWNED BY is destructive).
      EXECUTE format('COMMENT ON ROLE %I IS %L', name, 'created-by:isms-platform-migration');
    END IF;
    -- Pin attributes explicitly every time (idempotent and corrective)
    EXECUTE format(
      'ALTER ROLE %I NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION %s',
      name,
      CASE WHEN name = ANY(logins) THEN 'LOGIN' ELSE 'NOLOGIN' END);
  END LOOP;

  -- Design 9.1 "no role gets BYPASSRLS": measure it at this point and fail if violated
  FOR r IN SELECT rolname FROM pg_roles
            WHERE rolname = ANY(roles) AND (rolsuper OR rolbypassrls) LOOP
    RAISE EXCEPTION 'role % still has SUPERUSER or BYPASSRLS', r.rolname;
  END LOOP;
END $$;

ALTER SCHEMA catalog OWNER TO schema_owner;
ALTER SCHEMA app     OWNER TO schema_owner;
ALTER SCHEMA audit   OWNER TO schema_owner;

GRANT USAGE ON SCHEMA catalog TO app_rw, app_ro;
GRANT USAGE ON SCHEMA app     TO app_rw, app_ro;
-- Granting audit USAGE to app_rw/app_ro as well is as intended by design doc 2.2 / 8.3.
-- Viewing the audit log is a CISO / secretariat / auditor privilege (9.5 permission matrix);
-- on the table side it is SELECT only, tenant-scoped by RLS, and UPDATE/DELETE are REVOKEd (0014).
GRANT USAGE ON SCHEMA audit   TO app_rw, app_ro, auditlogd, audit_verifier;

-- Prevent anyone from creating objects in the public schema (a default pitfall)
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- ALTER DEFAULT PRIVILEGES only affects "objects that role creates from now on"
-- and is not retroactive. Effective privileges are GRANTed explicitly in 0015, and CI inspects the real objects directly.
ALTER DEFAULT PRIVILEGES FOR ROLE schema_owner IN SCHEMA catalog
  GRANT SELECT ON TABLES TO app_rw, app_ro;

-- ------------------------------------------------------------------
-- Tenant context (provisional definition)
--
-- Using the design doc 2.2 / 9.2 implementation as-is would let app_rw SET the GUC app.tenant_id
-- itself, failing acceptance #7. 0006 does CREATE OR REPLACE with a version that verifies an HMAC signature.
-- The key table does not exist yet here, so a provisional implementation is used.
-- For "the scope of properties that can be proven", see docs/DECISIONS.md.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.current_tenant() RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE v text := current_setting('app.tenant_id', true);
BEGIN
  IF v IS NULL OR v = '' THEN
    RAISE EXCEPTION 'tenant context is not set' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v::uuid;
END $$;

ALTER FUNCTION app.current_tenant() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.current_tenant() FROM PUBLIC;
-- app_ro also calls this function when evaluating RLS policy expressions, so it needs EXECUTE
-- (Codex finding: the per-function execute-privilege table is in docs/DECISIONS.md).
GRANT EXECUTE ON FUNCTION app.current_tenant() TO app_rw, app_ro;
