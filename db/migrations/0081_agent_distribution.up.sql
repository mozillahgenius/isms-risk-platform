-- Initial agent delivery is independent from enrollment activation.
-- The delivery token is short-lived and one-use for code enrollment; for GWS
-- enrollment it is only the installer capability and is never an enrollment
-- credential.

SET ROLE schema_owner;

ALTER TABLE app.mail_outbox
  DROP CONSTRAINT IF EXISTS mail_outbox_purpose_check;
ALTER TABLE app.mail_outbox
  ADD CONSTRAINT mail_outbox_purpose_check
  CHECK (purpose IN ('external_questionnaire','work_assignment','agent_distribution'));

CREATE TABLE app.agent_installations (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES app.tenants(id),
  delivery_token_hash bytea NOT NULL CHECK (octet_length(delivery_token_hash) = 32),
  target_email       citext NOT NULL,
  target_name        text NOT NULL DEFAULT '',
  os_family          text NOT NULL CHECK (os_family IN ('macos','windows','linux')),
  auth_method        text NOT NULL CHECK (auth_method IN ('code','gws')),
  status             text NOT NULL DEFAULT 'issued'
    CHECK (status IN ('issued','sent','downloaded','installed','activation_pending','active','failed','expired')),
  expires_at         timestamptz NOT NULL,
  installer_version  text NOT NULL CHECK (installer_version ~ '^[A-Za-z0-9._-]{1,64}$'),
  device_id          uuid,
  hardware_id        text,
  downloaded_at      timestamptz,
  installed_at       timestamptz,
  activated_at       timestamptz,
  failure_code       text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid,
  UNIQUE (delivery_token_hash),
  FOREIGN KEY (tenant_id, device_id) REFERENCES app.devices(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES app.users(tenant_id, id),
  CHECK (target_email = lower(target_email::text)),
  CHECK (length(target_email::text) BETWEEN 3 AND 254),
  CHECK (expires_at > created_at)
);
CREATE INDEX agent_installations_tenant_status
  ON app.agent_installations (tenant_id, status, created_at DESC);

ALTER TABLE app.agent_installations ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.agent_installations FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.agent_installations
  FOR ALL TO app_rw
  USING (tenant_id = app.current_tenant())
  WITH CHECK (tenant_id = app.current_tenant());
CREATE POLICY tenant_read ON app.agent_installations
  FOR SELECT TO app_ro
  USING (tenant_id = app.current_tenant());
CREATE POLICY management_definer_access ON app.agent_installations
  FOR ALL TO schema_owner USING (true) WITH CHECK (true);
REVOKE ALL ON app.agent_installations FROM PUBLIC, app_rw, app_ro;
GRANT SELECT ON app.agent_installations TO app_rw, app_ro;

CREATE OR REPLACE FUNCTION app.issue_agent_installation(
  p_token text,
  p_target_email text,
  p_target_name text,
  p_os_family text,
  p_auth_method text,
  p_installer_version text,
  p_ttl interval DEFAULT interval '24 hours'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant uuid := app.current_tenant();
  v_user uuid := app.current_session_user();
  v_id uuid := pg_catalog.gen_random_uuid();
  v_hash bytea;
  v_expires timestamptz := pg_catalog.now() + p_ttl;
BEGIN
  IF app.current_management_role() NOT IN ('owner','admin','manager') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_token IS NULL OR pg_catalog.length(p_token) < 32
     OR p_target_email IS NULL OR p_target_email !~ '^[^[:cntrl:][:space:]]+@[^[:cntrl:][:space:]]+$'
     OR p_os_family NOT IN ('macos','windows','linux')
     OR p_auth_method NOT IN ('code','gws')
     OR p_installer_version IS NULL OR p_installer_version !~ '^[A-Za-z0-9._-]{1,64}$'
     OR p_ttl IS NULL OR p_ttl <= interval '0' OR p_ttl > interval '7 days' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
  END IF;
  v_hash := public.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256');
  PERFORM pg_catalog.set_config('app.agent_tenant', v_tenant::text, true);

  IF p_auth_method = 'code' THEN
    INSERT INTO app.device_enrollment_tokens
      (tenant_id, token_hash, expires_at)
    VALUES (v_tenant, v_hash, v_expires);
  END IF;
  INSERT INTO app.agent_installations
    (id, tenant_id, delivery_token_hash, target_email, target_name, os_family,
     auth_method, expires_at, installer_version, created_by)
  VALUES
    (v_id, v_tenant, v_hash, pg_catalog.lower(pg_catalog.btrim(p_target_email)),
     pg_catalog.left(pg_catalog.btrim(coalesce(p_target_name, '')), 255), p_os_family,
     p_auth_method, v_expires, p_installer_version, v_user);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'expires_at', v_expires);
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'retry');
END $$;
ALTER FUNCTION app.issue_agent_installation(text,text,text,text,text,text,interval) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.issue_agent_installation(text,text,text,text,text,text,interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.issue_agent_installation(text,text,text,text,text,text,interval) TO management_web;

CREATE OR REPLACE FUNCTION app.lookup_agent_installation(p_token_hash bytea)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE r app.agent_installations;
BEGIN
  IF p_token_hash IS NULL OR pg_catalog.octet_length(p_token_hash) <> 32 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid');
  END IF;
  SELECT * INTO r FROM app.agent_installations
   WHERE delivery_token_hash = p_token_hash
     AND expires_at > pg_catalog.now()
     AND status NOT IN ('active','failed','expired');
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'expired_or_invalid');
  END IF;
  RETURN jsonb_build_object(
    'ok', true, 'id', r.id, 'os_family', r.os_family,
    'auth_method', r.auth_method, 'expires_at', r.expires_at,
    'installer_version', r.installer_version, 'status', r.status);
END $$;
ALTER FUNCTION app.lookup_agent_installation(bytea) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.lookup_agent_installation(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.lookup_agent_installation(bytea) TO app_rw, management_web;

CREATE OR REPLACE FUNCTION app.mark_agent_installation(
  p_token_hash bytea,
  p_stage text,
  p_hardware_id text DEFAULT NULL,
  p_device_id uuid DEFAULT NULL,
  p_failure_code text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  r app.agent_installations;
  v_status text;
BEGIN
  SELECT * INTO r FROM app.agent_installations
   WHERE delivery_token_hash = p_token_hash FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid'); END IF;
  IF r.expires_at <= pg_catalog.now() AND r.status NOT IN ('active','failed') THEN
    UPDATE app.agent_installations SET status='expired' WHERE id=r.id;
    RETURN jsonb_build_object('ok', false, 'reason', 'expired');
  END IF;
  v_status := CASE p_stage
    WHEN 'downloaded' THEN 'downloaded'
    WHEN 'installed' THEN 'installed'
    WHEN 'activation_pending' THEN 'activation_pending'
    WHEN 'active' THEN 'active'
    WHEN 'failed' THEN 'failed'
    ELSE NULL
  END;
  IF v_status IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_stage'); END IF;
  IF r.status = 'active' AND v_status <> 'active' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_active');
  END IF;
  IF v_status = 'active' AND p_device_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'device_required');
  END IF;
  UPDATE app.agent_installations
     SET status=v_status,
         hardware_id=coalesce(p_hardware_id, hardware_id),
         device_id=coalesce(p_device_id, device_id),
         downloaded_at=CASE WHEN v_status='downloaded' THEN coalesce(downloaded_at, pg_catalog.now()) ELSE downloaded_at END,
         installed_at=CASE WHEN v_status IN ('installed','activation_pending','active') THEN coalesce(installed_at, pg_catalog.now()) ELSE installed_at END,
         activated_at=CASE WHEN v_status='active' THEN coalesce(activated_at, pg_catalog.now()) ELSE activated_at END,
         failure_code=CASE WHEN v_status='failed' THEN pg_catalog.left(coalesce(p_failure_code,'failed'), 120) ELSE failure_code END
   WHERE id=r.id;
  RETURN jsonb_build_object('ok', true, 'status', v_status, 'id', r.id);
END $$;
ALTER FUNCTION app.mark_agent_installation(bytea,text,text,uuid,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.mark_agent_installation(bytea,text,text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.mark_agent_installation(bytea,text,text,uuid,text) TO app_rw, management_web;

-- Extend the mail worker's existing transition so the delivery ledger records
-- that the link really left the server.  The worker still remains the only
-- writer allowed to move mail_outbox to sent.
CREATE OR REPLACE FUNCTION app.mark_mail_sent(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_purpose text;
  v_related_type text;
  v_related_id uuid;
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
  ELSIF v_purpose='agent_distribution' AND v_related_type='agent_installation' THEN
    UPDATE app.agent_installations
       SET status=CASE WHEN status='issued' THEN 'sent' ELSE status END
     WHERE tenant_id=app.current_tenant() AND id=v_related_id
       AND status IN ('issued','sent');
  END IF;
END
$$;
ALTER FUNCTION app.mark_mail_sent(uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.mark_mail_sent(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.mark_mail_sent(uuid) TO mail_worker;

RESET ROLE;
