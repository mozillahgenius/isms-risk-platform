-- Management owns its own agent enrollment state.
-- This migration intentionally does not call Kaname or Codzilla.

SET ROLE schema_owner;

ALTER TABLE app.device_enrollment_tokens
  ADD COLUMN issued_by uuid,
  ADD COLUMN method text NOT NULL DEFAULT 'code'
    CHECK (method = 'code'),
  ADD CONSTRAINT device_enrollment_tokens_issued_by_fk
    FOREIGN KEY (tenant_id, issued_by) REFERENCES app.users(tenant_id, id);

CREATE TABLE app.device_login_requests (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  device_code_hash bytea NOT NULL CHECK (octet_length(device_code_hash) = 32),
  user_code_hash   bytea NOT NULL CHECK (octet_length(user_code_hash) = 32),
  public_key       bytea NOT NULL CHECK (octet_length(public_key) = 32),
  hardware_id      text NOT NULL CHECK (hardware_id ~ '^[A-Za-z0-9._:-]{1,200}$'),
  hostname         text NOT NULL CHECK (length(btrim(hostname)) BETWEEN 1 AND 255),
  model            text NOT NULL CHECK (length(btrim(model)) BETWEEN 1 AND 255),
  os_family        text NOT NULL CHECK (os_family IN ('macos','windows','linux','dsm','other')),
  off_premise      boolean NOT NULL DEFAULT false,
  notice_version   text NOT NULL CHECK (notice_version ~ '^[A-Za-z0-9._-]{1,32}$'),
  source           text NOT NULL DEFAULT 'unknown',
  status           text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','denied','redeemed','failed')),
  tenant_id       uuid,
  approved_by     uuid,
  approved_at     timestamptz,
  closed_reason   text,
  closed_at       timestamptz,
  device_id       uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL,
  last_polled_at  timestamptz,
  redeemed_at     timestamptz,
  UNIQUE (device_code_hash),
  UNIQUE (user_code_hash),
  FOREIGN KEY (tenant_id) REFERENCES app.tenants(id),
  FOREIGN KEY (tenant_id, approved_by) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES app.devices(tenant_id, id),
  CHECK (expires_at > created_at),
  CHECK ((status IN ('approved','denied','redeemed','failed')) = (closed_at IS NOT NULL OR status = 'redeemed'))
);
CREATE INDEX device_login_requests_pending_expiry
  ON app.device_login_requests (status, expires_at);
CREATE INDEX device_login_requests_source_time
  ON app.device_login_requests (source, created_at DESC);

CREATE TABLE app.device_login_request_nonces (
  request_id uuid NOT NULL REFERENCES app.device_login_requests(id) ON DELETE CASCADE,
  nonce      text NOT NULL CHECK (nonce ~ '^[A-Za-z0-9_-]{16,128}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, nonce)
);

ALTER TABLE app.device_login_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.device_login_requests FORCE ROW LEVEL SECURITY;
ALTER TABLE app.device_login_request_nonces ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.device_login_request_nonces FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.device_login_requests
  FOR ALL TO app_rw
  USING (tenant_id = app.current_tenant())
  WITH CHECK (tenant_id = app.current_tenant());
CREATE POLICY tenant_read ON app.device_login_requests
  FOR SELECT TO app_ro
  USING (tenant_id = app.current_tenant());
CREATE POLICY management_definer_access ON app.device_login_requests
  FOR ALL TO schema_owner USING (true) WITH CHECK (true);
CREATE POLICY management_definer_access ON app.device_login_request_nonces
  FOR ALL TO schema_owner USING (true) WITH CHECK (true);
REVOKE ALL ON app.device_login_requests, app.device_login_request_nonces FROM PUBLIC, app_rw, app_ro;

CREATE OR REPLACE FUNCTION app.issue_device_enrollment_token_for_management(
  p_token text, p_ttl interval DEFAULT interval '24 hours'
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant uuid := app.current_tenant();
  v_user uuid := app.current_session_user();
  v_id uuid := pg_catalog.gen_random_uuid();
BEGIN
  IF app.current_management_role() NOT IN ('owner','admin','manager') THEN
    RAISE EXCEPTION 'management device enrollment permission required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_token IS NULL OR pg_catalog.length(p_token) < 32
     OR p_ttl IS NULL OR p_ttl <= interval '0' OR p_ttl > interval '7 days' THEN
    RAISE EXCEPTION 'invalid enrollment token parameters' USING ERRCODE = 'check_violation';
  END IF;
  PERFORM pg_catalog.set_config('app.agent_tenant', v_tenant::text, true);
  INSERT INTO app.device_enrollment_tokens
    (id, tenant_id, token_hash, expires_at, issued_by, method)
  VALUES
    (v_id, v_tenant, public.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256'),
     pg_catalog.now() + p_ttl, v_user, 'code');
  RETURN v_id;
END $$;
ALTER FUNCTION app.issue_device_enrollment_token_for_management(text, interval) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.issue_device_enrollment_token_for_management(text, interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.issue_device_enrollment_token_for_management(text, interval) TO management_web;

CREATE OR REPLACE FUNCTION app.start_device_login_enrollment(
  p_device_code_hash bytea,
  p_user_code_hash bytea,
  p_public_key bytea,
  p_hardware_id text,
  p_hostname text,
  p_model text,
  p_os_family text,
  p_off_premise boolean,
  p_notice_version text,
  p_source text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_id uuid;
  v_expires timestamptz := pg_catalog.now() + interval '10 minutes';
  v_source text := left(coalesce(nullif(pg_catalog.btrim(p_source), ''), 'unknown'), 100);
BEGIN
  IF p_device_code_hash IS NULL OR pg_catalog.octet_length(p_device_code_hash) <> 32
     OR p_user_code_hash IS NULL OR pg_catalog.octet_length(p_user_code_hash) <> 32
     OR p_public_key IS NULL OR pg_catalog.octet_length(p_public_key) <> 32
     OR p_hardware_id !~ '^[A-Za-z0-9._:-]{1,200}$'
     OR pg_catalog.length(pg_catalog.btrim(coalesce(p_hostname, ''))) NOT BETWEEN 1 AND 255
     OR pg_catalog.length(pg_catalog.btrim(coalesce(p_model, ''))) NOT BETWEEN 1 AND 255
     OR p_os_family NOT IN ('macos','windows','linux','dsm','other')
     OR p_notice_version !~ '^[A-Za-z0-9._-]{1,32}$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
  END IF;
  IF (SELECT count(*) FROM app.device_login_requests r
       WHERE r.source = v_source AND r.created_at > pg_catalog.now() - interval '15 minutes') >= 10
     OR (SELECT count(*) FROM app.device_login_requests r
       WHERE r.created_at > pg_catalog.now() - interval '15 minutes') >= 100 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rate_limited');
  END IF;
  INSERT INTO app.device_login_requests
    (device_code_hash, user_code_hash, public_key, hardware_id, hostname, model,
     os_family, off_premise, notice_version, source, expires_at)
  VALUES
    (p_device_code_hash, p_user_code_hash, p_public_key, p_hardware_id,
     pg_catalog.btrim(p_hostname), pg_catalog.btrim(p_model), p_os_family, coalesce(p_off_premise, false),
     p_notice_version, v_source, v_expires)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'request_id', v_id, 'expires_at', v_expires);
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'retry');
END $$;
ALTER FUNCTION app.start_device_login_enrollment(bytea,bytea,bytea,text,text,text,text,boolean,text,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.start_device_login_enrollment(bytea,bytea,bytea,text,text,text,text,boolean,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.start_device_login_enrollment(bytea,bytea,bytea,text,text,text,text,boolean,text,text) TO app_rw;

CREATE OR REPLACE FUNCTION app.lookup_device_login_enrollment(p_user_code_hash bytea)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  r app.device_login_requests;
  v_tenant uuid := app.current_tenant();
BEGIN
  IF app.current_management_role() NOT IN ('owner','admin','manager') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT * INTO r FROM app.device_login_requests
   WHERE user_code_hash = p_user_code_hash
     AND expires_at > pg_catalog.now()
     AND (tenant_id IS NULL OR tenant_id = v_tenant);
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid'); END IF;
  RETURN jsonb_build_object(
    'ok', true, 'request_id', r.id, 'status', r.status, 'tenant_id', r.tenant_id,
    'hostname', r.hostname, 'model', r.model, 'os_family', r.os_family,
    'hardware_id', r.hardware_id, 'created_at', r.created_at, 'expires_at', r.expires_at);
END $$;
ALTER FUNCTION app.lookup_device_login_enrollment(bytea) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.lookup_device_login_enrollment(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.lookup_device_login_enrollment(bytea) TO management_web;

CREATE OR REPLACE FUNCTION app.decide_device_login_enrollment(
  p_request_id uuid, p_user_code_hash bytea, p_approve boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  r app.device_login_requests;
  v_tenant uuid := app.current_tenant();
  v_user uuid := app.current_session_user();
BEGIN
  IF app.current_management_role() NOT IN ('owner','admin','manager') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT * INTO r FROM app.device_login_requests
   WHERE id = p_request_id AND user_code_hash = p_user_code_hash FOR UPDATE;
  IF NOT FOUND OR r.expires_at <= pg_catalog.now()
     OR (r.tenant_id IS NOT NULL AND r.tenant_id <> v_tenant) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid');
  END IF;
  IF r.status NOT IN ('pending','approved') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_pending');
  END IF;
  IF p_approve THEN
    UPDATE app.device_login_requests
       SET status = 'approved', tenant_id = v_tenant, approved_by = v_user,
           approved_at = pg_catalog.now(), closed_at = pg_catalog.now()
     WHERE id = r.id AND status = 'pending';
  ELSE
    UPDATE app.device_login_requests
       SET status = 'denied', tenant_id = v_tenant, approved_by = v_user,
           approved_at = pg_catalog.now(), closed_reason = 'denied', closed_at = pg_catalog.now()
     WHERE id = r.id AND status IN ('pending','approved');
  END IF;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_pending'); END IF;
  RETURN jsonb_build_object('ok', true, 'status', CASE WHEN p_approve THEN 'approved' ELSE 'denied' END);
END $$;
ALTER FUNCTION app.decide_device_login_enrollment(uuid,bytea,boolean) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.decide_device_login_enrollment(uuid,bytea,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.decide_device_login_enrollment(uuid,bytea,boolean) TO management_web;

CREATE OR REPLACE FUNCTION app.device_login_enrollment_key(p_device_code_hash bytea)
RETURNS bytea
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
  SELECT public_key FROM app.device_login_requests
   WHERE device_code_hash = p_device_code_hash AND expires_at > pg_catalog.now()
$$;
ALTER FUNCTION app.device_login_enrollment_key(bytea) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.device_login_enrollment_key(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.device_login_enrollment_key(bytea) TO app_rw;

CREATE OR REPLACE FUNCTION app.redeem_device_login_enrollment(
  p_device_code_hash bytea,
  p_public_key bytea,
  p_nonce text,
  p_issued_at timestamptz
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  r app.device_login_requests;
  d app.devices;
  v_device uuid := pg_catalog.gen_random_uuid();
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('app.management_device_enrollment', 0));
  SELECT * INTO r FROM app.device_login_requests WHERE device_code_hash = p_device_code_hash FOR UPDATE;
  IF NOT FOUND OR r.public_key IS DISTINCT FROM p_public_key THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid');
  END IF;
  IF r.expires_at <= pg_catalog.now() THEN RETURN jsonb_build_object('ok', false, 'reason', 'expired'); END IF;
  IF r.status = 'denied' THEN RETURN jsonb_build_object('ok', false, 'reason', 'denied'); END IF;
  IF r.status = 'failed' THEN RETURN jsonb_build_object('ok', false, 'reason', coalesce(r.closed_reason, 'failed')); END IF;
  IF p_issued_at IS NULL OR p_nonce !~ '^[A-Za-z0-9_-]{16,128}$'
     OR abs(extract(epoch FROM (pg_catalog.now() - p_issued_at))) > 300
     OR EXISTS (SELECT 1 FROM app.device_login_request_nonces n
                WHERE n.request_id = r.id AND n.nonce = p_nonce) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid');
  END IF;
  INSERT INTO app.device_login_request_nonces (request_id, nonce) VALUES (r.id, p_nonce);
  IF r.status = 'pending' THEN
    IF r.last_polled_at IS NOT NULL AND r.last_polled_at > pg_catalog.now() - interval '5 seconds' THEN
      UPDATE app.device_login_requests SET last_polled_at = pg_catalog.now() WHERE id = r.id;
      RETURN jsonb_build_object('ok', false, 'reason', 'slow_down');
    END IF;
    UPDATE app.device_login_requests SET last_polled_at = pg_catalog.now() WHERE id = r.id;
    RETURN jsonb_build_object('ok', false, 'reason', 'authorization_pending');
  END IF;
  IF r.status = 'redeemed' THEN
    UPDATE app.device_login_requests SET last_polled_at = pg_catalog.now() WHERE id = r.id;
    RETURN jsonb_build_object('ok', true, 'tenant_id', r.tenant_id, 'device_id', r.device_id);
  END IF;
  IF r.status <> 'approved' OR r.tenant_id IS NULL OR r.approved_by IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'denied');
  END IF;
  PERFORM pg_catalog.set_config('app.agent_tenant', r.tenant_id::text, true);
  SELECT * INTO d FROM app.devices
   WHERE tenant_id = r.tenant_id AND source = 'agent' AND external_id = r.hardware_id;
  IF FOUND AND (d.public_key IS DISTINCT FROM r.public_key
                OR d.hostname IS DISTINCT FROM r.hostname
                OR d.model IS DISTINCT FROM r.model
                OR d.os_family IS DISTINCT FROM r.os_family) THEN
    UPDATE app.device_login_requests
       SET status = 'failed', closed_reason = 'ENROLLMENT_INCONSISTENT', closed_at = pg_catalog.now(), last_polled_at = pg_catalog.now()
     WHERE id = r.id;
    RETURN jsonb_build_object('ok', false, 'reason', 'ENROLLMENT_INCONSISTENT');
  END IF;
  IF FOUND THEN
    UPDATE app.device_login_requests
       SET status = 'failed', closed_reason = 'already_enrolled', closed_at = pg_catalog.now(), last_polled_at = pg_catalog.now()
     WHERE id = r.id;
    RETURN jsonb_build_object('ok', false, 'reason', 'already_enrolled');
  END IF;
  INSERT INTO app.devices
    (id, tenant_id, source, external_id, hostname, model, os_family,
     is_offpremise, enrolled_at, created_by, public_key)
  VALUES
    (v_device, r.tenant_id, 'agent', r.hardware_id, r.hostname, r.model, r.os_family,
     r.off_premise, pg_catalog.now(), r.approved_by, r.public_key);
  UPDATE app.device_login_requests
     SET status = 'redeemed', device_id = v_device, redeemed_at = pg_catalog.now(), last_polled_at = pg_catalog.now()
   WHERE id = r.id AND status = 'approved';
  IF NOT FOUND THEN RAISE EXCEPTION 'device login request state changed' USING ERRCODE = 'serialization_failure'; END IF;
  RETURN jsonb_build_object('ok', true, 'tenant_id', r.tenant_id, 'device_id', v_device);
END $$;
ALTER FUNCTION app.redeem_device_login_enrollment(bytea,bytea,text,timestamptz) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.redeem_device_login_enrollment(bytea,bytea,text,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.redeem_device_login_enrollment(bytea,bytea,text,timestamptz) TO app_rw;
