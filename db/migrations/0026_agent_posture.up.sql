-- Phase 3a: macOS isms-agent enrollment, signed posture, and definition catalog.
-- The existing devices/device_snapshots tables remain the normalized landing
-- zone. Secrets are never stored in plaintext.

SET ROLE schema_owner;

ALTER TABLE app.devices ADD COLUMN public_key bytea;
ALTER TABLE app.device_snapshots ADD COLUMN signature bytea;
ALTER TABLE app.device_snapshots ADD COLUMN payload jsonb;
CREATE UNIQUE INDEX device_snapshots_idempotency
  ON app.device_snapshots (tenant_id, device_id, raw_hash);

CREATE TABLE catalog.agent_definitions (
  version       int NOT NULL,
  platform      text NOT NULL CHECK (platform = 'macos'),
  definition    jsonb NOT NULL,
  definition_hash bytea NOT NULL CHECK (octet_length(definition_hash) = 32),
  active        boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (version, platform)
);
REVOKE ALL ON catalog.agent_definitions FROM PUBLIC;
GRANT SELECT ON catalog.agent_definitions TO app_rw, app_ro;

-- The API performs Ed25519 verification. This second, DB-local MAC prevents
-- an app_rw caller from bypassing that boundary by invoking the landing
-- function directly with arbitrary posture data.
CREATE TABLE app.agent_ingest_keys (
  id         smallint PRIMARY KEY CHECK (id = 1),
  secret     bytea NOT NULL CHECK (octet_length(secret) = 32),
  updated_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON app.agent_ingest_keys FROM PUBLIC, app_rw, app_ro;

CREATE TABLE app.device_enrollment_tokens (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL,
  token_hash  bytea NOT NULL CHECK (octet_length(token_hash) = 32),
  expires_at  timestamptz NOT NULL,
  used_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  UNIQUE (token_hash),
  FOREIGN KEY (tenant_id) REFERENCES app.tenants(id)
);
ALTER TABLE app.device_enrollment_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.device_enrollment_tokens FORCE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION app.agent_tenant_target() RETURNS uuid
LANGUAGE sql VOLATILE SET search_path = pg_catalog AS $$
  SELECT NULLIF(pg_catalog.current_setting('app.agent_tenant', true), '')::uuid
$$;
ALTER FUNCTION app.agent_tenant_target() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.agent_tenant_target() FROM PUBLIC;

CREATE POLICY tenant_isolation ON app.device_enrollment_tokens FOR ALL TO app_rw
  USING (tenant_id = app.current_tenant())
  WITH CHECK (tenant_id = app.current_tenant());
CREATE POLICY tenant_read ON app.device_enrollment_tokens FOR SELECT TO app_ro
  USING (tenant_id = app.current_tenant());
CREATE POLICY agent_token_access ON app.device_enrollment_tokens FOR ALL TO schema_owner
  USING (true) WITH CHECK (true);
REVOKE ALL ON app.device_enrollment_tokens FROM PUBLIC, app_rw, app_ro;

-- FORCE RLS also applies to SECURITY DEFINER functions owned by schema_owner.
-- These policies are reachable only by the no-login definer and are paired
-- with strict tenant checks inside the functions below.
CREATE POLICY agent_device_definer_read ON app.devices FOR SELECT TO schema_owner
  USING (true);
CREATE POLICY agent_device_definer_insert ON app.devices FOR INSERT TO schema_owner
  WITH CHECK (tenant_id = app.agent_tenant_target());
CREATE POLICY agent_device_definer_update ON app.devices FOR UPDATE TO schema_owner
  USING (true) WITH CHECK (tenant_id = app.agent_tenant_target());
CREATE POLICY agent_snapshot_definer_read ON app.device_snapshots FOR SELECT TO schema_owner
  USING (true);
CREATE POLICY agent_snapshot_definer_insert ON app.device_snapshots FOR INSERT TO schema_owner
  WITH CHECK (tenant_id = app.agent_tenant_target());

CREATE OR REPLACE FUNCTION app.enroll_device(
  p_token text,
  p_external_id text,
  p_hostname text,
  p_model text,
  p_os_family text,
  p_off_premise boolean,
  p_public_key bytea
) RETURNS TABLE (device_id uuid, tenant_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_token_id uuid;
  v_tenant uuid;
  v_device uuid := pg_catalog.gen_random_uuid();
BEGIN
  IF p_token IS NULL OR pg_catalog.length(p_token) < 32 THEN
    RAISE EXCEPTION 'invalid enrollment token' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF pg_catalog.btrim(coalesce(p_external_id, '')) = ''
     OR pg_catalog.btrim(coalesce(p_hostname, '')) = ''
     OR pg_catalog.btrim(coalesce(p_model, '')) = ''
     OR pg_catalog.btrim(coalesce(p_os_family, '')) = '' THEN
    RAISE EXCEPTION 'device identity is incomplete' USING ERRCODE = 'check_violation';
  END IF;
  IF p_public_key IS NULL OR pg_catalog.octet_length(p_public_key) <> 32 THEN
    RAISE EXCEPTION 'device public key is invalid' USING ERRCODE = 'check_violation';
  END IF;

  SELECT t.id, t.tenant_id INTO v_token_id, v_tenant
    FROM app.device_enrollment_tokens t
   WHERE t.token_hash = public.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256')
     AND t.used_at IS NULL AND t.expires_at > pg_catalog.now()
   FOR UPDATE;
  IF v_token_id IS NULL THEN
    RAISE EXCEPTION 'invalid or expired enrollment token' USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM pg_catalog.set_config('app.agent_tenant', v_tenant::text, true);
  INSERT INTO app.devices
    (id, tenant_id, source, external_id, hostname, model, os_family,
     is_offpremise, enrolled_at, public_key)
  VALUES
    (v_device, v_tenant, 'agent', p_external_id, p_hostname, p_model, p_os_family,
     coalesce(p_off_premise, false), pg_catalog.now(), p_public_key);

  UPDATE app.device_enrollment_tokens
     SET used_at = pg_catalog.now()
   WHERE app.device_enrollment_tokens.tenant_id = v_tenant
     AND app.device_enrollment_tokens.id = v_token_id
     AND app.device_enrollment_tokens.used_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'enrollment token was already consumed' USING ERRCODE = 'serialization_failure';
  END IF;

  device_id := v_device;
  tenant_id := v_tenant;
  RETURN NEXT;
END $$;
ALTER FUNCTION app.enroll_device(text,text,text,text,text,boolean,bytea) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.enroll_device(text,text,text,text,text,boolean,bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.enroll_device(text,text,text,text,text,boolean,bytea) TO app_rw;

CREATE OR REPLACE FUNCTION app.set_agent_ingest_key(p_secret bytea) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF p_secret IS NULL OR pg_catalog.octet_length(p_secret) <> 32 THEN
    RAISE EXCEPTION 'agent ingest key must be 32 bytes' USING ERRCODE = 'check_violation';
  END IF;
  INSERT INTO app.agent_ingest_keys (id, secret, updated_at)
  VALUES (1, p_secret, pg_catalog.now())
  ON CONFLICT (id) DO UPDATE SET secret = EXCLUDED.secret, updated_at = EXCLUDED.updated_at;
END $$;
ALTER FUNCTION app.set_agent_ingest_key(bytea) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.set_agent_ingest_key(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.set_agent_ingest_key(bytea) TO provisioner;

CREATE OR REPLACE FUNCTION app.issue_device_enrollment_token(
  p_tenant uuid, p_token text, p_ttl interval DEFAULT interval '24 hours'
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_id uuid := pg_catalog.gen_random_uuid();
BEGIN
  IF p_tenant IS NULL OR p_token IS NULL OR pg_catalog.length(p_token) < 32
     OR p_ttl IS NULL OR p_ttl <= interval '0' OR p_ttl > interval '7 days' THEN
    RAISE EXCEPTION 'invalid enrollment token parameters' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app.tenants WHERE id = p_tenant) THEN
    RAISE EXCEPTION 'tenant not found' USING ERRCODE = 'foreign_key_violation';
  END IF;
  PERFORM pg_catalog.set_config('app.agent_tenant', p_tenant::text, true);
  INSERT INTO app.device_enrollment_tokens (id, tenant_id, token_hash, expires_at)
  VALUES (v_id, p_tenant,
          public.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256'),
          pg_catalog.now() + p_ttl);
  RETURN v_id;
END $$;
ALTER FUNCTION app.issue_device_enrollment_token(uuid,text,interval) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.issue_device_enrollment_token(uuid,text,interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.issue_device_enrollment_token(uuid,text,interval) TO provisioner;

CREATE OR REPLACE FUNCTION app.get_device_verification_key(p_device_id uuid)
RETURNS TABLE (tenant_id uuid, public_key bytea)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  RETURN QUERY SELECT d.tenant_id, d.public_key
    FROM app.devices d WHERE d.id = p_device_id AND d.source = 'agent';
END $$;
ALTER FUNCTION app.get_device_verification_key(uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.get_device_verification_key(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.get_device_verification_key(uuid) TO app_rw;

DROP FUNCTION IF EXISTS app.ingest_device_snapshot(uuid,timestamptz,text,int,bytea,jsonb,bytea,bytea);
CREATE OR REPLACE FUNCTION app.ingest_device_snapshot(
  p_device_id uuid,
  p_collected_at timestamptz,
  p_agent_version text,
  p_definition_version int,
  p_definition_hash bytea,
  p_payload jsonb,
  p_signature bytea,
  p_raw_hash bytea,
  p_ingest_mac bytea
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant uuid;
  v_external_id text;
  v_os_family text;
  v_offpremise boolean;
  v_secret bytea;
  v_expected_mac bytea;
BEGIN
  IF p_device_id IS NULL OR p_collected_at IS NULL OR pg_catalog.btrim(coalesce(p_agent_version,'')) = ''
     OR p_definition_version IS NULL OR p_definition_hash IS NULL
     OR pg_catalog.octet_length(p_definition_hash) <> 32
     OR p_payload IS NULL OR p_signature IS NULL OR pg_catalog.octet_length(p_signature) <> 64
     OR p_raw_hash IS NULL OR pg_catalog.octet_length(p_raw_hash) <> 32
     OR p_ingest_mac IS NULL OR pg_catalog.octet_length(p_ingest_mac) <> 32 THEN
    RAISE EXCEPTION 'signed posture is incomplete' USING ERRCODE = 'check_violation';
  END IF;

  SELECT d.tenant_id, d.external_id, d.os_family, d.is_offpremise
    INTO v_tenant, v_external_id, v_os_family, v_offpremise
    FROM app.devices d WHERE d.id = p_device_id AND d.source = 'agent';
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'agent device not found' USING ERRCODE = 'foreign_key_violation';
  END IF;
  PERFORM pg_catalog.set_config('app.agent_tenant', v_tenant::text, true);

  SELECT k.secret INTO v_secret FROM app.agent_ingest_keys k WHERE k.id = 1;
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'agent ingest key is not configured' USING ERRCODE = 'configuration_limit_exceeded';
  END IF;
  v_expected_mac := public.hmac(
    p_raw_hash || p_signature || pg_catalog.convert_to(p_device_id::text, 'UTF8'),
    v_secret, 'sha256');
  IF v_expected_mac IS DISTINCT FROM p_ingest_mac THEN
    RAISE EXCEPTION 'agent ingest verification receipt is invalid' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_payload->>'device_id' IS DISTINCT FROM p_device_id::text THEN
    RAISE EXCEPTION 'posture device_id does not match enrollment' USING ERRCODE = 'check_violation';
  END IF;
  IF p_payload->>'external_id' IS DISTINCT FROM v_external_id THEN
    RAISE EXCEPTION 'posture external_id does not match enrollment' USING ERRCODE = 'check_violation';
  END IF;
  IF p_payload->>'os_family' IS DISTINCT FROM v_os_family THEN
    RAISE EXCEPTION 'posture os_family does not match enrollment' USING ERRCODE = 'check_violation';
  END IF;
  IF (p_payload->>'off_premise')::boolean IS DISTINCT FROM v_offpremise THEN
    RAISE EXCEPTION 'posture off_premise does not match enrollment' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM catalog.agent_definitions d
     WHERE d.platform = 'macos' AND d.version = p_definition_version
       AND d.active AND d.definition_hash = p_definition_hash
  ) THEN
    RAISE EXCEPTION 'posture definition is not active' USING ERRCODE = 'check_violation';
  END IF;
  IF p_collected_at > pg_catalog.now() + interval '10 minutes' THEN
    RAISE EXCEPTION 'posture collected_at is in the future' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (
    SELECT 1 FROM app.device_snapshots s
     WHERE s.tenant_id = v_tenant AND s.device_id = p_device_id AND s.raw_hash = p_raw_hash
  ) THEN
    RETURN true;
  END IF;
  IF p_collected_at < pg_catalog.now() - interval '7 days'
     OR p_collected_at < coalesce((
       SELECT max(s.collected_at) FROM app.device_snapshots s
        WHERE s.tenant_id = v_tenant AND s.device_id = p_device_id
     ), p_collected_at) THEN
    RAISE EXCEPTION 'stale posture replay rejected' USING ERRCODE = 'check_violation';
  END IF;

  BEGIN
    INSERT INTO app.device_snapshots
      (tenant_id, device_id, collected_at, agent_version, definition_version,
       definition_hash, disk_encrypted, screen_lock_enabled, screen_lock_delay_sec,
       os_version, patch_current, auto_update_enabled, firewall_enabled, edr_running,
       admin_account_count, password_manager_installed, unapproved_apps,
       raw_hash, signature, payload)
    VALUES
      (v_tenant, p_device_id, p_collected_at, p_agent_version, p_definition_version::text,
       p_definition_hash,
       NULLIF(p_payload->>'disk_encrypted','')::boolean,
       NULLIF(p_payload->>'screen_lock_enabled','')::boolean,
       NULLIF(p_payload->>'screen_lock_delay_sec','')::int,
       NULLIF(p_payload->>'os_version',''),
       NULLIF(p_payload->>'patch_current','')::boolean,
       NULLIF(p_payload->>'auto_update_enabled','')::boolean,
       NULLIF(p_payload->>'firewall_enabled','')::boolean,
       NULLIF(p_payload->>'edr_running','')::boolean,
       NULLIF(p_payload->>'admin_account_count','')::int,
       NULLIF(p_payload->>'password_manager_installed','')::boolean,
       ARRAY(SELECT jsonb_array_elements_text(coalesce(p_payload->'unapproved_apps','[]'::jsonb))),
       p_raw_hash, p_signature, p_payload);
  EXCEPTION WHEN unique_violation THEN
    -- Retries of the same signed payload are accepted without a duplicate row.
    NULL;
  END;

  UPDATE app.devices
     SET last_seen_at = greatest(coalesce(last_seen_at, p_collected_at), p_collected_at),
         hostname = coalesce(nullif(p_payload->>'hostname',''), hostname),
         model = coalesce(nullif(p_payload->>'model',''), model),
         os_family = coalesce(nullif(p_payload->>'os_family',''), os_family),
         updated_at = pg_catalog.now()
   WHERE tenant_id = v_tenant AND id = p_device_id;
  RETURN true;
END $$;
ALTER FUNCTION app.ingest_device_snapshot(uuid,timestamptz,text,int,bytea,jsonb,bytea,bytea,bytea) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.ingest_device_snapshot(uuid,timestamptz,text,int,bytea,jsonb,bytea,bytea,bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.ingest_device_snapshot(uuid,timestamptz,text,int,bytea,jsonb,bytea,bytea,bytea) TO app_rw;

RESET ROLE;
