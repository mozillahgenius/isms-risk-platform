-- The GWS target user may approve only the distributed request addressed to
-- that user's verified Management session. The administrator approval path
-- remains available for non-distributed login enrollment.

SET ROLE schema_owner;

ALTER TABLE app.device_login_requests
  ADD COLUMN distribution_token_hash bytea
    CHECK (distribution_token_hash IS NULL OR octet_length(distribution_token_hash) = 32);
CREATE INDEX device_login_requests_distribution_token
  ON app.device_login_requests (distribution_token_hash, created_at DESC);

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
  p_source text,
  p_distribution_token_hash bytea
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_installation app.agent_installations;
  v_result jsonb;
  v_request_id uuid;
BEGIN
  IF p_distribution_token_hash IS NULL THEN
    RETURN app.start_device_login_enrollment(
      p_device_code_hash, p_user_code_hash, p_public_key, p_hardware_id,
      p_hostname, p_model, p_os_family, p_off_premise, p_notice_version, p_source
    );
  END IF;
  IF p_distribution_token_hash IS NULL
     OR pg_catalog.octet_length(p_distribution_token_hash) <> 32 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_distribution');
  END IF;
  SELECT * INTO v_installation
    FROM app.agent_installations
   WHERE delivery_token_hash = p_distribution_token_hash
     AND auth_method = 'gws'
     AND expires_at > pg_catalog.now()
     AND status NOT IN ('failed', 'expired', 'active')
     AND (hardware_id IS NULL OR hardware_id = p_hardware_id)
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_distribution');
  END IF;
  v_result := app.start_device_login_enrollment(
    p_device_code_hash, p_user_code_hash, p_public_key, p_hardware_id,
    p_hostname, p_model, p_os_family, p_off_premise, p_notice_version, p_source
  );
  IF coalesce((v_result ->> 'ok')::boolean, false) IS NOT TRUE THEN
    RETURN v_result;
  END IF;
  v_request_id := (v_result ->> 'request_id')::uuid;
  UPDATE app.device_login_requests
     SET distribution_token_hash = p_distribution_token_hash
   WHERE id = v_request_id AND distribution_token_hash IS NULL;
  UPDATE app.agent_installations
     SET hardware_id = coalesce(hardware_id, p_hardware_id),
         status = CASE WHEN status IN ('issued','sent','downloaded','installed')
                       THEN 'activation_pending' ELSE status END,
         installed_at = coalesce(installed_at, pg_catalog.now())
   WHERE id = v_installation.id;
  RETURN v_result;
END $$;
ALTER FUNCTION app.start_device_login_enrollment(bytea,bytea,bytea,text,text,text,text,boolean,text,text,bytea) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.start_device_login_enrollment(bytea,bytea,bytea,text,text,text,text,boolean,text,text,bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.start_device_login_enrollment(bytea,bytea,bytea,text,text,text,text,boolean,text,text,bytea) TO app_rw, management_web;

CREATE OR REPLACE FUNCTION app.activate_device_login_enrollment_for_target(
  p_distribution_token_hash bytea
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant uuid := app.current_tenant();
  v_user uuid := app.current_session_user();
  v_email text;
  v_request app.device_login_requests;
  v_installation app.agent_installations;
BEGIN
  IF v_tenant IS NULL OR v_user IS NULL
     OR p_distribution_token_hash IS NULL
     OR pg_catalog.octet_length(p_distribution_token_hash) <> 32 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT lower(u.email) INTO v_email
    FROM app.users u
   WHERE u.tenant_id = v_tenant AND u.id = v_user AND u.status = 'active';
  IF v_email IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT * INTO v_installation
    FROM app.agent_installations i
   WHERE i.delivery_token_hash = p_distribution_token_hash
     AND i.tenant_id = v_tenant
     AND i.auth_method = 'gws'
     AND i.target_email = v_email
     AND i.expires_at > pg_catalog.now()
     AND i.status NOT IN ('failed', 'expired', 'active')
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_target');
  END IF;
  SELECT req.*
    INTO v_request
    FROM app.device_login_requests req
   WHERE req.distribution_token_hash = p_distribution_token_hash
     AND req.expires_at > pg_catalog.now()
     AND req.status IN ('pending', 'approved')
   ORDER BY req.created_at DESC
   LIMIT 1
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_target');
  END IF;
  IF v_request.status = 'approved' THEN
    RETURN jsonb_build_object('ok', true, 'status', 'approved');
  END IF;
  UPDATE app.device_login_requests
     SET status = 'approved', tenant_id = v_tenant, approved_by = v_user,
         approved_at = pg_catalog.now(), closed_at = pg_catalog.now()
   WHERE id = v_request.id AND status = 'pending';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_pending');
  END IF;
  RETURN jsonb_build_object('ok', true, 'status', 'approved');
END $$;
ALTER FUNCTION app.activate_device_login_enrollment_for_target(bytea) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.activate_device_login_enrollment_for_target(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.activate_device_login_enrollment_for_target(bytea) TO management_web;

RESET ROLE;
