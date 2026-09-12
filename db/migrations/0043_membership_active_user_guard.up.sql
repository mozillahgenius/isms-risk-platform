-- 0043: Harden membership and department-owner assignment on the DB side as well
--
-- Background (Codex review 2026-09-03): the app layer in organization/actions.ts
-- was fixed to lock the target user row FOR UPDATE and reject role assignment to
-- retired/suspended users, but that only covers the web app's Server Action path.
-- If another path holding the app_rw role (direct SQL, a future separate app or batch, etc.)
-- INSERTs directly into app.memberships / app.departments, then:
--   1) the auditor mutual-exclusion trigger (0005 check_auditor_exclusivity) misses
--      uncommitted rows from concurrent INSERTs, so both can commit in a conflicting state
--   2) nothing stops assigning roles to, or naming as department owner, a retired/suspended user
-- These two holes remain with the app-layer fix alone. 0005 is already deployed to production
-- and cannot be edited directly (frozen), so the trigger bodies are replaced here
-- with CREATE OR REPLACE FUNCTION.
--
-- Note: no BEGIN/COMMIT here. scripts/migrate.sh already wraps the whole file
-- in a single transaction (for atomicity of DDL + ledger update).
--
-- Note (Codex review 2026-09-03, 5th round; confirmed by measurement): app.provision_tenant()
-- (0021, SECURITY DEFINER, owned by schema_owner) INSERTs the initial admin membership
-- when creating a new tenant, which also fires the triggers in this file.
-- However, schema_owner's RLS policies on app.users are only 0005's
-- ctx_user_lookup (SELECT only, USING(true)) and prov_user_insert (INSERT only);
-- there is no policy covering UPDATE/ALL. By PostgreSQL's rules,
-- SELECT ... FOR UPDATE is subject to the policies for the UPDATE command, so
-- even when the target row is visible to SELECT, FOR UPDATE filters it to 0 rows and the lock
-- silently misses (no error; confirmed by measurement: SET ROLE schema_owner;
-- SELECT ... FOR UPDATE returned 0 rows for an existing row). To make the lock effective
-- for schema_owner, add a narrowly scoped UPDATE-only policy
-- (following the same principle as 0005's ctx_user_lookup: "the definer sees only the minimum
-- needed to establish context and provision". schema_owner already has arbitrary INSERT into
-- app.users via prov_user_insert and is a trusted definer role, so adding UPDATE visibility
-- for locking does not materially change the trust boundary).
--
-- Note (Codex review 2026-09-03, 6th round; considered and rejected): the following two options
-- were considered and neither was adopted.
--   (a) Replacing it with an advisory lock (pg_advisory_xact_lock):
--       an approach already tested and rejected in this repository in 0018 -> 0019. An advisory lock
--       does not refresh the READ COMMITTED snapshot after the lock wait ends, so
--       even after waiting the other side's committed result is not visible and it does not
--       actually serialize (see the explanation in 0019_tenant_row_lock.up.sql). A row lock
--       is the correct approach.
--   (b) The idea that using FOR SHARE instead of FOR UPDATE would make an UPDATE-type policy
--       unnecessary: disproved by measurement. With ctx_user_lock removed,
--       running SET ROLE schema_owner; SELECT ... FOR SHARE against an existing row
--       returned 0 rows, just like FOR UPDATE. PostgreSQL RLS does not distinguish
--       FOR SHARE from FOR UPDATE; both require an UPDATE-type policy to be satisfied,
--       so this alternative does not avoid the problem.
-- Conclusion: as long as schema_owner takes row locks under RLS, granting UPDATE visibility
-- (ctx_user_lock) is the only option.
--
-- Note (Codex review 2026-09-03, 8th round; addressed): the grant did not need to extend to all tenants
-- and all rows, though. app.provisioning_target() (a STABLE function reading the SET LOCAL GUC
-- 'app.provisioning'), already used by 0021's prov_user_insert and others,
-- returns the ID of the tenant being created only while provision_tenant() is running
-- (in both the 0021 and 0022 redefinitions it is set_config'd before the INSERT into memberships).
-- The same narrowing is applied to ctx_user_lock's
-- USING/WITH CHECK, restricting it from "schema_owner can lock/update any row of any tenant"
-- to "only rows of the tenant currently being created"
-- (the same trust boundary as prov_user_insert).
CREATE POLICY ctx_user_lock ON app.users FOR UPDATE TO schema_owner
  USING (tenant_id = app.provisioning_target())
  WITH CHECK (tenant_id = app.provisioning_target());

-- (1) Close the concurrency race in the auditor mutual-exclusion check (0005).
-- Lock the target user row (app.users) FOR UPDATE before checking exclusivity.
-- Concurrent INSERT/UPDATE for the same user are serialized by this lock, so the later
-- transaction always sees the earlier transaction's committed result before
-- deciding (without the lock, each misses the other's uncommitted rows).
CREATE OR REPLACE FUNCTION app.check_auditor_exclusivity() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  PERFORM 1 FROM app.users WHERE tenant_id = NEW.tenant_id AND id = NEW.user_id FOR UPDATE;
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

-- (2) Reject role assignment to retired/suspended users on the DB side as well.
-- This trigger also locks FOR UPDATE on its own. Relying on trg_auditor_exclusivity
-- (which fires first by trigger-name order and locks the same user row)
-- would close the gap by accident, but that depends on the implicit assumption of firing order
-- and is fragile. Keep the function self-contained (Codex review 2026-09-03
-- 4th round: the comment "unified on the lock pattern" contradicted the
-- implementation).
CREATE OR REPLACE FUNCTION app.check_membership_active_user() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  PERFORM 1 FROM app.users WHERE tenant_id = NEW.tenant_id AND id = NEW.user_id FOR UPDATE;
  IF NOT EXISTS (
    SELECT 1 FROM app.users WHERE tenant_id = NEW.tenant_id AND id = NEW.user_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'membership cannot be granted to a non-active user';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_membership_active_user BEFORE INSERT OR UPDATE ON app.memberships
  FOR EACH ROW WHEN (NEW.revoked_at IS NULL)
  EXECUTE FUNCTION app.check_membership_active_user();

-- (3) Likewise, department owners (owner_user_id) cannot be set to inactive users.
-- Lock the target user row FOR UPDATE before checking. Without the lock,
-- "transaction A checks active -> transaction B updates the same user to
-- suspended and commits -> A commits the department" -- a TOCTOU that would
-- remain in this DB-side trigger itself (Codex review 2026-09-03, 3rd round).
CREATE OR REPLACE FUNCTION app.check_department_owner_active() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.owner_user_id IS NOT NULL THEN
    PERFORM 1 FROM app.users WHERE tenant_id = NEW.tenant_id AND id = NEW.owner_user_id FOR UPDATE;
    IF NOT EXISTS (
      SELECT 1 FROM app.users WHERE tenant_id = NEW.tenant_id AND id = NEW.owner_user_id AND status = 'active'
    ) THEN
      RAISE EXCEPTION 'department owner must be an active user';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_department_owner_active BEFORE INSERT OR UPDATE ON app.departments
  FOR EACH ROW EXECUTE FUNCTION app.check_department_owner_active();
