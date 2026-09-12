-- Restore migration 0031's projection behavior before removing the hardening.

SET ROLE schema_owner;

CREATE OR REPLACE FUNCTION app.project_hr_identity(
  p_tenant uuid,
  p_email text,
  p_display_name text,
  p_hr_employee_id text,
  p_device_id uuid
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_identity_id uuid;
  v_existing_email text;
  v_existing_subject_type text;
  v_account_count integer;
  v_account_identity_id uuid;
  v_assigned_identity_id uuid;
BEGIN
  IF p_tenant IS NULL
     OR pg_catalog.btrim(coalesce(p_email, '')) = ''
     OR pg_catalog.btrim(coalesce(p_display_name, '')) = ''
     OR pg_catalog.btrim(coalesce(p_hr_employee_id, '')) = ''
     OR p_device_id IS NULL THEN
    RAISE EXCEPTION 'HR identity projection parameters are incomplete' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app.tenants WHERE id = p_tenant) THEN
    RAISE EXCEPTION 'HR identity projection tenant was not found' USING ERRCODE = 'foreign_key_violation';
  END IF;

  PERFORM pg_catalog.set_config('app.hr_projection_tenant', p_tenant::text, true);

  SELECT i.id, i.primary_email::text, i.subject_type
    INTO v_identity_id, v_existing_email, v_existing_subject_type
    FROM app.identities i
   WHERE i.tenant_id = p_tenant
     AND i.hr_employee_id = p_hr_employee_id
   FOR UPDATE;
  IF v_identity_id IS NOT NULL THEN
    IF v_existing_subject_type <> 'employee'
       OR lower(coalesce(v_existing_email, '')) <> lower(p_email) THEN
      RAISE EXCEPTION 'existing HR-linked identity conflicts with the backoffice person'
        USING ERRCODE = 'unique_violation';
    END IF;
  ELSE
    INSERT INTO app.identities
      (tenant_id, subject_type, display_name, primary_email, hr_employee_id, status)
    VALUES
      (p_tenant, 'employee', p_display_name, p_email::public.citext, p_hr_employee_id, 'active')
    RETURNING id INTO v_identity_id;
  END IF;

  SELECT count(*) INTO v_account_count
    FROM app.accounts a
   WHERE a.tenant_id = p_tenant
     AND a.connector = 'google_workspace'
     AND lower(a.email::text) = lower(p_email);
  IF v_account_count <> 1 THEN
    RAISE EXCEPTION 'HR identity projection requires exactly one matching Google account (got %)', v_account_count
      USING ERRCODE = 'cardinality_violation';
  END IF;

  SELECT a.identity_id INTO v_account_identity_id
    FROM app.accounts a
   WHERE a.tenant_id = p_tenant
     AND a.connector = 'google_workspace'
     AND lower(a.email::text) = lower(p_email)
   FOR UPDATE;
  IF v_account_identity_id IS NOT NULL AND v_account_identity_id <> v_identity_id THEN
    RAISE EXCEPTION 'matching Google account is already assigned to another identity'
      USING ERRCODE = 'unique_violation';
  END IF;

  UPDATE app.accounts
     SET identity_id = v_identity_id, updated_at = pg_catalog.now()
   WHERE tenant_id = p_tenant
   AND connector = 'google_workspace'
   AND lower(email::text) = lower(p_email);
  SELECT d.assigned_identity_id INTO v_assigned_identity_id
    FROM app.devices d
   WHERE d.tenant_id = p_tenant
     AND d.id = p_device_id
     AND d.source = 'agent'
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'assigned device was not found for this tenant' USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF v_assigned_identity_id IS NOT NULL AND v_assigned_identity_id <> v_identity_id THEN
    RAISE EXCEPTION 'assigned device is already linked to another identity'
      USING ERRCODE = 'unique_violation';
  END IF;
  UPDATE app.devices
     SET assigned_identity_id = v_identity_id,
         updated_at = pg_catalog.now()
   WHERE tenant_id = p_tenant AND id = p_device_id;
  RETURN v_identity_id;
END $$;
ALTER FUNCTION app.project_hr_identity(uuid,text,text,text,uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.project_hr_identity(uuid,text,text,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.project_hr_identity(uuid,text,text,text,uuid) TO provisioner;

DO $$
BEGIN
  IF to_regclass('app.identities_hr_employee_id_unique') IS NOT NULL
     AND pg_catalog.obj_description(
           'app.identities_hr_employee_id_unique'::regclass, 'pg_class'
         ) = 'created-by:0033_hr_identity_hardening' THEN
    EXECUTE 'DROP INDEX app.identities_hr_employee_id_unique';
  END IF;
END $$;

RESET ROLE;
