DROP FUNCTION IF EXISTS app.detach_device(uuid);
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
  -- 同じ機体（組織・source・external_id）がすでに登録済みなら、行を新しく作らず、鍵とホスト名などを更新する
  -- （登録し直し。0085）。登録し直しにも、管理者が発行した未使用・期限内の登録トークンが要る（上で確認済み）。
  INSERT INTO app.devices AS d
    (id, tenant_id, source, external_id, hostname, model, os_family,
     is_offpremise, enrolled_at, public_key)
  VALUES
    (v_device, v_tenant, 'agent', p_external_id, p_hostname, p_model, p_os_family,
     coalesce(p_off_premise, false), pg_catalog.now(), p_public_key)
  ON CONFLICT ON CONSTRAINT devices_tenant_id_source_external_id_key DO UPDATE
    SET hostname = EXCLUDED.hostname,
        model = EXCLUDED.model,
        os_family = EXCLUDED.os_family,
        is_offpremise = EXCLUDED.is_offpremise,
        enrolled_at = pg_catalog.now(),
        public_key = EXCLUDED.public_key
  RETURNING d.id INTO v_device;

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
ALTER TABLE app.devices DROP COLUMN IF EXISTS detached_at;
