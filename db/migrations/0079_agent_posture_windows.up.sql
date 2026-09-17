-- 0079: posture の定義を OS ごとに持つ（Windows 対応。設計書 2026-09-11 §2.3(2)・D4）。
-- 定義表の platform を macos / windows に広げ、取り込み関数は「端末の OS の定義」で照合する。
-- Windows 固有の値は既存の payload jsonb に入る。正規化列は増やさない（設計書の `extra` 列は新設しない）。
-- 関数本体は 0026 と同じで、定義の照合（d.platform）だけを端末の os_family に替える。

SET ROLE schema_owner;

ALTER TABLE catalog.agent_definitions DROP CONSTRAINT agent_definitions_platform_check;
ALTER TABLE catalog.agent_definitions
  ADD CONSTRAINT agent_definitions_platform_check CHECK (platform IN ('macos', 'windows'));

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
  -- 端末の OS の定義で照合する（macOS の端末に Windows の定義を当てない、その逆も）。
  IF NOT EXISTS (
    SELECT 1 FROM catalog.agent_definitions d
     WHERE d.platform = v_os_family AND d.version = p_definition_version
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
