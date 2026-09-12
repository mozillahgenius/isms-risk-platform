-- @run-as: admin
-- 0021 Tenant creation path, and the pass gate for checks.
--
-- Run as admin. CREATE ROLE does not work as schema_owner (NOCREATEROLE).
-- Everything other than role creation is done via SET ROLE schema_owner, keeping ownership consistent.
--
-- What this adds:
--   (A) app.provision_tenant() - creates the tenant, initial user, membership, and expanded standard policies
--       as one unit. Without it, not a single tenant can be created, so
--       operational data stays empty forever (the UI can say nothing beyond "cannot read").
--   (B) A pass gate on app.check_runs - **checks that have not been confirmed to fail when broken
--       cannot be recorded as pass**. This is a DB constraint, not an operational good intention.
--
-- Why put (B) in the DB:
--   A check becomes a check only by "failing when it should", not by "passing".
--   If it relies on human confirmation, it gets skipped on busy days and green rows pile up.
--   If the recording side has no choice but to obey a constraint, skipping means it cannot be recorded.

SET ROLE schema_owner;

-- ============================================================ (A) creation path

-- Marker set only during creation. The provisioning policy below lets through only rows matching this value.
-- Narrowed from "schema_owner can insert anything" to "only rows of the tenant currently being created".
CREATE OR REPLACE FUNCTION app.provisioning_target() RETURNS uuid
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT NULLIF(pg_catalog.current_setting('app.provisioning', true), '')::uuid
$$;
ALTER FUNCTION app.provisioning_target() OWNER TO schema_owner;

-- INSERT policy for the definer (schema_owner).
-- schema_owner is NOLOGIN; only SECURITY DEFINER functions written by the owner can pass here.
-- Even so, do not make it "can insert rows for any tenant".
CREATE POLICY prov_tenant_insert ON app.tenants
  FOR INSERT TO schema_owner WITH CHECK (id = app.provisioning_target());
CREATE POLICY prov_user_insert ON app.users
  FOR INSERT TO schema_owner WITH CHECK (tenant_id = app.provisioning_target());
CREATE POLICY prov_membership_insert ON app.memberships
  FOR INSERT TO schema_owner WITH CHECK (tenant_id = app.provisioning_target());
CREATE POLICY prov_policy_insert ON app.policies
  FOR INSERT TO schema_owner WITH CHECK (tenant_id = app.provisioning_target());
CREATE POLICY prov_policy_version_insert ON app.policy_versions
  FOR INSERT TO schema_owner WITH CHECK (tenant_id = app.provisioning_target());

-- The only path for creating a tenant.
-- Expands the 12 standard policies as-is (the foundation of acceptance #1 "standards active right after tenant creation").
CREATE OR REPLACE FUNCTION app.provision_tenant(
  p_name text, p_domain text, p_admin_email text, p_admin_name text,
  p_fiscal_start_month smallint DEFAULT 4, p_industry_preset text DEFAULT 'general'
) RETURNS TABLE (tenant_id uuid, user_id uuid, policies_expanded int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  v_tenant uuid := public.gen_random_uuid();
  v_user   uuid := public.gen_random_uuid();
  v_dom    uuid;
  v_count  int;
BEGIN
  IF coalesce(pg_catalog.btrim(p_name), '') = '' OR coalesce(pg_catalog.btrim(p_domain), '') = ''
     OR coalesce(pg_catalog.btrim(p_admin_email), '') = '' THEN
    RAISE EXCEPTION '名称・ドメイン・管理者メールは必須です';
  END IF;

  SELECT id INTO v_dom FROM catalog.dom_versions WHERE is_current;
  IF v_dom IS NULL THEN
    RAISE EXCEPTION '現行 DOM がありません。先に DOM を投入してください';
  END IF;

  -- Creation marker. Effective only within the transaction (third argument of set_config is true).
  PERFORM pg_catalog.set_config('app.provisioning', v_tenant::text, true);

  INSERT INTO app.tenants (id, name, domain, fiscal_start_month, industry_preset, dom_version_id)
  VALUES (v_tenant, p_name, p_domain, p_fiscal_start_month, p_industry_preset, v_dom);

  INSERT INTO app.users (id, tenant_id, email, display_name)
  VALUES (v_user, v_tenant, p_admin_email, p_admin_name);

  -- The first user is the executive (CISO). Never create an organization with no one to make acceptance decisions and approvals.
  INSERT INTO app.memberships (tenant_id, user_id, role_key) VALUES (v_tenant, v_user, 'ciso');

  -- Expand standard policies. Bodies are copied as-is from the DOM standard.
  -- Differences are the tenant's decision, and those differences are recorded as deviations (design doc 1.6).
  --
  -- **Do not use INSERT ... RETURNING.** RETURNING requires a SELECT policy on the returned rows,
  -- and the definer has no read policy, so it fails there (measured).
  -- Working around it by widening reads would give the definer visibility into all tenants just for creation.
  -- Deciding the id up front removes the need to read it back.
  WITH src AS MATERIALIZED (
    -- gen_random_uuid() is volatile. It is referenced twice, so fix it exactly once.
    SELECT public.gen_random_uuid() AS policy_id, d.key, d.title_ja, d.body_md
      FROM catalog.policies_default d
      JOIN catalog.dom_versions v ON v.id = d.dom_version_id AND v.is_current
  ), ins AS (
    INSERT INTO app.policies (id, tenant_id, catalog_key, title)
    SELECT policy_id, v_tenant, key, title_ja FROM src
  )
  INSERT INTO app.policy_versions (tenant_id, policy_id, version, body_md, diff_clause_count)
  SELECT v_tenant, policy_id, 1, body_md, 0 FROM src;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  PERFORM pg_catalog.set_config('app.provisioning', '', true);

  tenant_id := v_tenant; user_id := v_user; policies_expanded := v_count;
  RETURN NEXT;
END $$;
ALTER FUNCTION app.provision_tenant(text, text, text, text, smallint, text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.provision_tenant(text, text, text, text, smallint, text) FROM PUBLIC;

-- Role dedicated to creation. It gets no table privileges (it can only call this function).
-- Giving this to app_rw would let the business connection create tenants.
-- CREATE ROLE does not work as schema_owner, so only here do we switch back to admin.
RESET ROLE;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provisioner') THEN
    CREATE ROLE provisioner;
    COMMENT ON ROLE provisioner IS 'created-by:isms-platform-migration';
  END IF;
END $$;
ALTER ROLE provisioner NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION LOGIN;
GRANT USAGE ON SCHEMA app TO provisioner;
GRANT EXECUTE ON FUNCTION app.provision_tenant(text, text, text, text, smallint, text) TO provisioner;

-- ============================================================ (B) pass gate

SET ROLE schema_owner;

-- negative_verified: whether running the check's negative_fixture confirmed that **the check actually
--   detected a violation**.
-- verified_digest: fingerprint of query_sql and negative_fixture at the time of confirmation.
--   If the check's contents are rewritten, the earlier confirmation no longer counts.
ALTER TABLE app.check_runs
  ADD COLUMN negative_verified boolean NOT NULL DEFAULT false,
  ADD COLUMN verified_digest   text;

ALTER TABLE app.check_runs
  ADD CONSTRAINT check_runs_pass_requires_negative_verification
  CHECK (result <> 'pass' OR (negative_verified AND verified_digest IS NOT NULL));

ALTER TABLE app.check_runs
  ADD CONSTRAINT check_runs_digest_shape
  CHECK (verified_digest IS NULL OR verified_digest ~ '^[0-9a-f]{64}$');

COMMENT ON COLUMN app.check_runs.negative_verified IS
  '壊して落ちることを確かめたか。false のまま pass では記録できない（制約で強制）。';
COMMENT ON COLUMN app.check_runs.verified_digest IS
  '確認した時点の query_sql と negative_fixture の SHA-256。中身が変われば確認はやり直し。';

RESET ROLE;
