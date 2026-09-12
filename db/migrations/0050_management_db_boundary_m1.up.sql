-- @run-as: admin
-- M1 closes the app-role bypasses left by 0046-0049.  Framework membership is
-- changed through fixed functions; active records must retain RISK-MANAGEMENT.

UPDATE catalog.frameworks
   SET name_ja = 'リソースマネジメント',
       source_note = 'リソース、リスク、施策を同一台帳で管理する自社システムの呼称。規格本文ではない。'
 WHERE key = 'RISK-MANAGEMENT';

-- Browser-originated writes use a separate login boundary.  It inherits the
-- ordinary app_rw grants, but app_rw cannot assume this role; only this role
-- may turn a trusted reverse-proxy identity into the audited DB actor.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='management_web') THEN
    CREATE ROLE management_web;
    COMMENT ON ROLE management_web IS 'created-by:isms-platform-migration';
  END IF;
  ALTER ROLE management_web LOGIN INHERIT NOSUPERUSER NOBYPASSRLS
    NOCREATEROLE NOCREATEDB NOREPLICATION;
END $$;
GRANT app_rw TO management_web;

ALTER TABLE app.framework_relation_origins
  DROP CONSTRAINT framework_relation_origins_entity_type_check,
  ADD CONSTRAINT framework_relation_origins_entity_type_check
    CHECK (entity_type IN ('asset','risk_scenario','measure'));
ALTER TABLE app.framework_relation_events
  DROP CONSTRAINT framework_relation_events_entity_type_check,
  ADD CONSTRAINT framework_relation_events_entity_type_check
    CHECK (entity_type IN ('asset','risk_scenario','measure'));
ALTER TABLE app.framework_backfill_provenance
  DROP CONSTRAINT framework_backfill_provenance_entity_type_check,
  ADD CONSTRAINT framework_backfill_provenance_entity_type_check
    CHECK (entity_type IN ('asset','risk_scenario','measure'));

-- 0046-0049 objects are owned by the migration role, while their FK parents
-- are owned by schema_owner.  A non-superuser migration role therefore needs
-- temporary SELECT solely for PostgreSQL's FK checks during the backfill.
CREATE TEMP TABLE m1_migrator_select_state (
  table_name text PRIMARY KEY,
  had_select boolean NOT NULL
) ON COMMIT DROP;
INSERT INTO m1_migrator_select_state VALUES
  ('assets',has_table_privilege(current_user,'app.assets','SELECT')),
  ('risk_scenarios',has_table_privilege(current_user,'app.risk_scenarios','SELECT')),
  ('measures',has_table_privilege(current_user,'app.measures','SELECT'));
GRANT SELECT ON app.assets,app.risk_scenarios,app.measures TO CURRENT_USER;

-- Every relation has exactly one origin.  Relations without one predate M1;
-- recording that fact must not claim that M1 created the relation itself.
INSERT INTO app.framework_relation_origins
  (tenant_id,entity_type,entity_id,framework_key,generation_id,origin_kind,origin_id)
SELECT tenant_id,entity_type,entity_id,framework_key,gen_random_uuid(),'legacy','pre-0050'
  FROM (
    SELECT tenant_id,'asset'::text AS entity_type,asset_id AS entity_id,framework_key FROM app.asset_frameworks
    UNION ALL
    SELECT tenant_id,'risk_scenario',risk_scenario_id,framework_key FROM app.risk_scenario_frameworks
    UNION ALL
    SELECT tenant_id,'measure',measure_id,framework_key FROM app.measure_frameworks
  ) relation
ON CONFLICT (tenant_id,entity_type,entity_id,framework_key) DO NOTHING;
INSERT INTO app.framework_relation_events
  (tenant_id,entity_type,entity_id,framework_key,generation_id,event_kind)
SELECT tenant_id,entity_type,entity_id,framework_key,generation_id,'created'
  FROM app.framework_relation_origins
 WHERE origin_kind='legacy' AND origin_id='pre-0050'
   AND NOT EXISTS (
     SELECT 1 FROM app.framework_relation_events e
      WHERE e.tenant_id=framework_relation_origins.tenant_id
        AND e.entity_type=framework_relation_origins.entity_type
        AND e.entity_id=framework_relation_origins.entity_id
        AND e.framework_key=framework_relation_origins.framework_key
        AND e.generation_id=framework_relation_origins.generation_id
   );

-- Backfill only the absent mandatory relation and record that this migration,
-- rather than a historical user/service action, created it.
WITH missing AS (
  SELECT m.tenant_id,m.id AS entity_id,gen_random_uuid() AS generation_id
    FROM app.measures m
   WHERE m.status <> 'retired'
     AND NOT EXISTS (SELECT 1 FROM app.measure_frameworks mf
                       WHERE mf.tenant_id=m.tenant_id AND mf.measure_id=m.id
                         AND mf.framework_key='RISK-MANAGEMENT')
), inserted AS (
  INSERT INTO app.measure_frameworks (tenant_id,measure_id,framework_key)
  SELECT tenant_id,entity_id,'RISK-MANAGEMENT' FROM missing
  RETURNING tenant_id,measure_id
), origins AS (
  INSERT INTO app.framework_relation_origins
    (tenant_id,entity_type,entity_id,framework_key,generation_id,origin_kind,origin_id)
  SELECT m.tenant_id,'measure',m.entity_id,'RISK-MANAGEMENT',m.generation_id,
         'migration','0050_management_db_boundary_m1'
    FROM missing m JOIN inserted i ON i.tenant_id=m.tenant_id AND i.measure_id=m.entity_id
  RETURNING tenant_id,entity_type,entity_id,framework_key,generation_id
), provenance AS (
  INSERT INTO app.framework_backfill_provenance
    (migration_key,tenant_id,entity_type,entity_id,framework_key,generation_id,
     relation_existed_before,relation_created_by_migration)
  SELECT '0050_management_db_boundary_m1',tenant_id,entity_type,entity_id,framework_key,
         generation_id,false,true FROM origins
  RETURNING tenant_id,entity_type,entity_id,framework_key,generation_id
)
INSERT INTO app.framework_relation_events
  (tenant_id,entity_type,entity_id,framework_key,generation_id,event_kind)
SELECT tenant_id,entity_type,entity_id,framework_key,generation_id,'created' FROM provenance;

WITH missing AS (
  SELECT a.tenant_id,a.id AS entity_id,gen_random_uuid() AS generation_id
    FROM app.assets a WHERE a.status='active'
      AND NOT EXISTS (SELECT 1 FROM app.asset_frameworks af WHERE af.tenant_id=a.tenant_id AND af.asset_id=a.id AND af.framework_key='RISK-MANAGEMENT')
), inserted AS (
  INSERT INTO app.asset_frameworks (tenant_id,asset_id,framework_key)
  SELECT tenant_id,entity_id,'RISK-MANAGEMENT' FROM missing RETURNING tenant_id,asset_id
), origins AS (
  INSERT INTO app.framework_relation_origins (tenant_id,entity_type,entity_id,framework_key,generation_id,origin_kind,origin_id)
  SELECT m.tenant_id,'asset',m.entity_id,'RISK-MANAGEMENT',m.generation_id,'migration','0050_management_db_boundary_m1'
    FROM missing m JOIN inserted i ON i.tenant_id=m.tenant_id AND i.asset_id=m.entity_id
  RETURNING tenant_id,entity_type,entity_id,framework_key,generation_id
), provenance AS (
  INSERT INTO app.framework_backfill_provenance (migration_key,tenant_id,entity_type,entity_id,framework_key,generation_id,relation_existed_before,relation_created_by_migration)
  SELECT '0050_management_db_boundary_m1',tenant_id,entity_type,entity_id,framework_key,generation_id,false,true FROM origins
  RETURNING tenant_id,entity_type,entity_id,framework_key,generation_id
)
INSERT INTO app.framework_relation_events (tenant_id,entity_type,entity_id,framework_key,generation_id,event_kind)
SELECT tenant_id,entity_type,entity_id,framework_key,generation_id,'created' FROM provenance;

WITH missing AS (
  SELECT r.tenant_id,r.id AS entity_id,gen_random_uuid() AS generation_id
    FROM app.risk_scenarios r WHERE r.status='active'
      AND NOT EXISTS (SELECT 1 FROM app.risk_scenario_frameworks rf WHERE rf.tenant_id=r.tenant_id AND rf.risk_scenario_id=r.id AND rf.framework_key='RISK-MANAGEMENT')
), inserted AS (
  INSERT INTO app.risk_scenario_frameworks (tenant_id,risk_scenario_id,framework_key)
  SELECT tenant_id,entity_id,'RISK-MANAGEMENT' FROM missing RETURNING tenant_id,risk_scenario_id
), origins AS (
  INSERT INTO app.framework_relation_origins (tenant_id,entity_type,entity_id,framework_key,generation_id,origin_kind,origin_id)
  SELECT m.tenant_id,'risk_scenario',m.entity_id,'RISK-MANAGEMENT',m.generation_id,'migration','0050_management_db_boundary_m1'
    FROM missing m JOIN inserted i ON i.tenant_id=m.tenant_id AND i.risk_scenario_id=m.entity_id
  RETURNING tenant_id,entity_type,entity_id,framework_key,generation_id
), provenance AS (
  INSERT INTO app.framework_backfill_provenance (migration_key,tenant_id,entity_type,entity_id,framework_key,generation_id,relation_existed_before,relation_created_by_migration)
  SELECT '0050_management_db_boundary_m1',tenant_id,entity_type,entity_id,framework_key,generation_id,false,true FROM origins
  RETURNING tenant_id,entity_type,entity_id,framework_key,generation_id
)
INSERT INTO app.framework_relation_events (tenant_id,entity_type,entity_id,framework_key,generation_id,event_kind)
SELECT tenant_id,entity_type,entity_id,framework_key,generation_id,'created' FROM provenance;

-- Internal actions are service-originated, while requester_actor_id preserves
-- the initiating human/service identity.  Legacy rows keep unknown approval
-- metadata NULL rather than inventing evidence.
ALTER TABLE app.internal_management_operations
  ADD COLUMN actor_id uuid,
  ADD COLUMN requester_actor_id uuid,
  ADD COLUMN origin_kind text NOT NULL DEFAULT 'service'
    CHECK (origin_kind IN ('human','service')),
  ADD COLUMN approval_id uuid,
  ADD COLUMN policy_version_id uuid,
  ADD COLUMN policy_version_sha256 text
    CHECK (policy_version_sha256 IS NULL OR policy_version_sha256 ~ '^[a-f0-9]{64}$'),
  ADD COLUMN acceptance_reason text,
  ADD COLUMN acceptance_expires_at timestamptz;
UPDATE app.internal_management_operations o
   SET actor_id=a.actor_id, requester_actor_id=a.requester_actor_id
  FROM app.internal_management_audit_events a
 WHERE a.tenant_id=o.tenant_id AND a.operation_id=o.operation_id;
ALTER TABLE app.internal_management_operations
  ALTER COLUMN actor_id SET NOT NULL,
  ALTER COLUMN requester_actor_id SET NOT NULL,
  ADD CONSTRAINT internal_management_operations_actor_fk
    FOREIGN KEY (tenant_id,actor_id) REFERENCES app.users(tenant_id,id),
  ADD CONSTRAINT internal_management_operations_requester_fk
    FOREIGN KEY (tenant_id,requester_actor_id) REFERENCES app.users(tenant_id,id);
ALTER TABLE app.internal_management_audit_events
  ADD COLUMN origin_kind text NOT NULL DEFAULT 'service'
    CHECK (origin_kind IN ('human','service')),
  ADD COLUMN approval_id uuid,
  ADD COLUMN policy_version_id uuid,
  ADD COLUMN policy_version_sha256 text
    CHECK (policy_version_sha256 IS NULL OR policy_version_sha256 ~ '^[a-f0-9]{64}$'),
  ADD COLUMN acceptance_reason text,
  ADD COLUMN acceptance_expires_at timestamptz;

CREATE TABLE app.internal_management_service_principals (
  tenant_id uuid NOT NULL,
  user_id uuid NOT NULL,
  purpose text NOT NULL CHECK (length(btrim(purpose)) > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id,user_id),
  FOREIGN KEY (tenant_id,user_id) REFERENCES app.users(tenant_id,id)
);
CREATE TABLE app.internal_management_acceptance_approvals (
  tenant_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  operation_id text NOT NULL CHECK (operation_id ~ '^[a-f0-9]{12,64}$'),
  requester_actor_id uuid NOT NULL,
  risk_scenario_id uuid NOT NULL,
  evaluation_snapshot_id uuid NOT NULL,
  evaluation_snapshot_sha256 text NOT NULL CHECK (evaluation_snapshot_sha256 ~ '^[a-f0-9]{64}$'),
  inherent_snapshot_id uuid NOT NULL,
  inherent_snapshot_sha256 text NOT NULL CHECK (inherent_snapshot_sha256 ~ '^[a-f0-9]{64}$'),
  policy_version_id uuid NOT NULL,
  policy_version_sha256 text NOT NULL CHECK (policy_version_sha256 ~ '^[a-f0-9]{64}$'),
  acceptance_reason text NOT NULL CHECK (length(btrim(acceptance_reason)) > 0),
  acceptance_expires_at timestamptz NOT NULL,
  binding_sha256 text NOT NULL CHECK (binding_sha256 ~ '^[a-f0-9]{64}$'),
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id,id),
  UNIQUE (tenant_id,operation_id),
  FOREIGN KEY (tenant_id,requester_actor_id) REFERENCES app.users(tenant_id,id),
  FOREIGN KEY (tenant_id,risk_scenario_id) REFERENCES app.risk_scenarios(tenant_id,id),
  FOREIGN KEY (tenant_id,evaluation_snapshot_id) REFERENCES app.risk_evaluation_snapshots(tenant_id,id),
  FOREIGN KEY (tenant_id,inherent_snapshot_id) REFERENCES app.risk_evaluation_snapshots(tenant_id,id),
  FOREIGN KEY (tenant_id,policy_version_id) REFERENCES app.policy_versions(tenant_id,id)
);
ALTER TABLE app.internal_management_service_principals ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.internal_management_service_principals FORCE ROW LEVEL SECURITY;
ALTER TABLE app.internal_management_acceptance_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.internal_management_acceptance_approvals FORCE ROW LEVEL SECURITY;
ALTER TABLE app.internal_management_service_principals OWNER TO schema_owner;
ALTER TABLE app.internal_management_acceptance_approvals OWNER TO schema_owner;
ALTER TABLE app.internal_management_operations
  ADD CONSTRAINT internal_management_operations_approval_fk
    FOREIGN KEY (tenant_id,approval_id)
    REFERENCES app.internal_management_acceptance_approvals(tenant_id,id),
  ADD CONSTRAINT internal_management_operations_policy_version_fk
    FOREIGN KEY (tenant_id,policy_version_id) REFERENCES app.policy_versions(tenant_id,id),
  ADD CONSTRAINT internal_management_operations_acceptance_evidence_check
    CHECK (action <> 'accept_risk' OR
      (approval_id IS NOT NULL AND policy_version_id IS NOT NULL AND policy_version_sha256 IS NOT NULL
       AND length(btrim(coalesce(acceptance_reason,''))) > 0 AND acceptance_expires_at IS NOT NULL));
ALTER TABLE app.internal_management_audit_events
  ADD CONSTRAINT internal_management_audit_events_approval_fk
    FOREIGN KEY (tenant_id,approval_id)
    REFERENCES app.internal_management_acceptance_approvals(tenant_id,id),
  ADD CONSTRAINT internal_management_audit_events_policy_version_fk
    FOREIGN KEY (tenant_id,policy_version_id) REFERENCES app.policy_versions(tenant_id,id),
  ADD CONSTRAINT internal_management_audit_events_acceptance_evidence_check
    CHECK (action <> 'accept_risk' OR
      (approval_id IS NOT NULL AND policy_version_id IS NOT NULL AND policy_version_sha256 IS NOT NULL
       AND length(btrim(coalesce(acceptance_reason,''))) > 0 AND acceptance_expires_at IS NOT NULL));

CREATE FUNCTION app.reject_immutable_management_evidence() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION '% is immutable',TG_TABLE_NAME USING ERRCODE='55000';
END $$;
CREATE TRIGGER internal_management_operations_immutable
BEFORE UPDATE OR DELETE ON app.internal_management_operations
FOR EACH ROW EXECUTE FUNCTION app.reject_immutable_management_evidence();
CREATE TRIGGER internal_management_audit_events_immutable
BEFORE UPDATE OR DELETE ON app.internal_management_audit_events
FOR EACH ROW EXECUTE FUNCTION app.reject_immutable_management_evidence();
CREATE TRIGGER framework_relation_events_immutable
BEFORE UPDATE OR DELETE ON app.framework_relation_events
FOR EACH ROW EXECUTE FUNCTION app.reject_immutable_management_evidence();
CREATE TRIGGER risk_acceptances_immutable
BEFORE UPDATE OR DELETE ON app.risk_acceptances
FOR EACH ROW EXECUTE FUNCTION app.reject_immutable_management_evidence();
CREATE TRIGGER internal_management_acceptance_approvals_immutable
BEFORE UPDATE OR DELETE ON app.internal_management_acceptance_approvals
FOR EACH ROW EXECUTE FUNCTION app.reject_immutable_management_evidence();

CREATE OR REPLACE FUNCTION app.assert_active_management_framework() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE row_data jsonb:=coalesce(to_jsonb(NEW),to_jsonb(OLD)); t uuid:=(row_data->>'tenant_id')::uuid;
        e uuid; is_active boolean; has_management boolean;
BEGIN
  e:=coalesce((row_data->>'id')::uuid,(row_data->>'asset_id')::uuid,
              (row_data->>'risk_scenario_id')::uuid,(row_data->>'measure_id')::uuid);
  IF TG_ARGV[0]='asset' THEN
    SELECT status='active' INTO is_active FROM app.assets WHERE tenant_id=t AND id=e;
    SELECT EXISTS (SELECT 1 FROM app.asset_frameworks
                    WHERE tenant_id=t AND asset_id=e AND framework_key='RISK-MANAGEMENT')
      INTO has_management;
  ELSIF TG_ARGV[0]='risk_scenario' THEN
    SELECT status='active' INTO is_active FROM app.risk_scenarios WHERE tenant_id=t AND id=e;
    SELECT EXISTS (SELECT 1 FROM app.risk_scenario_frameworks
                    WHERE tenant_id=t AND risk_scenario_id=e AND framework_key='RISK-MANAGEMENT')
      INTO has_management;
  ELSE
    SELECT status <> 'retired' INTO is_active FROM app.measures WHERE tenant_id=t AND id=e;
    SELECT EXISTS (SELECT 1 FROM app.measure_frameworks
                    WHERE tenant_id=t AND measure_id=e AND framework_key='RISK-MANAGEMENT')
      INTO has_management;
  END IF;
  IF coalesce(is_active,false) AND NOT has_management THEN
    RAISE EXCEPTION 'RISK-MANAGEMENT is required for active %', TG_ARGV[0];
  END IF;
  RETURN NULL;
END $$;
CREATE POLICY management_service_principal_read
  ON app.internal_management_service_principals FOR SELECT TO schema_owner
  USING (true);
CREATE POLICY management_service_principal_provision
  ON app.internal_management_service_principals FOR INSERT TO schema_owner
  WITH CHECK (true);
ALTER FUNCTION app.assert_active_management_framework() OWNER TO schema_owner;

CREATE CONSTRAINT TRIGGER active_asset_requires_management
AFTER INSERT OR UPDATE OR DELETE ON app.assets DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION app.assert_active_management_framework('asset');
CREATE CONSTRAINT TRIGGER active_risk_requires_management
AFTER INSERT OR UPDATE OR DELETE ON app.risk_scenarios DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION app.assert_active_management_framework('risk_scenario');
CREATE CONSTRAINT TRIGGER active_measure_requires_management
AFTER INSERT OR UPDATE OR DELETE ON app.measures DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION app.assert_active_management_framework('measure');
CREATE CONSTRAINT TRIGGER asset_management_relation_required
AFTER INSERT OR UPDATE OR DELETE ON app.asset_frameworks DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION app.assert_active_management_framework('asset');
CREATE CONSTRAINT TRIGGER risk_management_relation_required
AFTER INSERT OR UPDATE OR DELETE ON app.risk_scenario_frameworks DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION app.assert_active_management_framework('risk_scenario');
CREATE CONSTRAINT TRIGGER measure_management_relation_required
AFTER INSERT OR UPDATE OR DELETE ON app.measure_frameworks DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION app.assert_active_management_framework('measure');

-- SECURITY DEFINER functions remain tenant-bound by these owner-only policies.
-- schema_owner has NOLOGIN; app_rw cannot invoke this path except through the
-- explicitly granted functions below.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['asset_frameworks','risk_scenario_frameworks','measure_frameworks',
                            'framework_relation_origins','framework_relation_events',
                            'framework_backfill_provenance','iso_framework_removal_requests',
                            'risk_acceptances','risk_evaluation_snapshots','memberships','users',
                            'risk_scenarios','approvals','policy_versions',
                            'internal_management_operations','internal_management_audit_events',
                            'internal_management_acceptance_approvals'] LOOP
    EXECUTE format('CREATE POLICY management_definer_access ON app.%I FOR ALL TO schema_owner USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())', t);
  END LOOP;
END $$;
GRANT SELECT,INSERT,UPDATE,DELETE ON app.asset_frameworks,app.risk_scenario_frameworks,
  app.measure_frameworks,app.framework_relation_origins,app.framework_relation_events,
  app.framework_backfill_provenance,app.iso_framework_removal_requests,
  app.risk_acceptances,app.internal_management_operations,
  app.internal_management_audit_events TO schema_owner;
GRANT SELECT ON app.internal_management_service_principals TO schema_owner;
GRANT SELECT,INSERT ON app.internal_management_acceptance_approvals TO schema_owner;
GRANT SELECT,UPDATE ON app.risk_scenarios TO schema_owner;
GRANT SELECT ON app.risk_evaluation_snapshots,app.memberships,app.users,
  app.approvals,app.policy_versions TO schema_owner;
GRANT INSERT ON app.approvals TO schema_owner;
CREATE OR REPLACE FUNCTION app.approve_policy_version(
  p_policy_version_id uuid, p_comment text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE
  v_tenant uuid:=app.current_tenant(); v_user uuid:=app.current_session_user();
  v_body text; v_already_approved timestamptz;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM app.memberships m JOIN app.users u
      ON u.tenant_id=m.tenant_id AND u.id=m.user_id
     WHERE m.tenant_id=v_tenant AND m.user_id=v_user AND m.role_key='ciso'
       AND m.revoked_at IS NULL AND u.status='active'
  ) THEN
    RAISE EXCEPTION 'executive role required' USING ERRCODE='insufficient_privilege';
  END IF;
  SELECT body_md,approved_at INTO v_body,v_already_approved
    FROM app.policy_versions WHERE tenant_id=v_tenant AND id=p_policy_version_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'policy version not found'; END IF;
  IF v_already_approved IS NOT NULL THEN RAISE EXCEPTION 'policy version is already approved'; END IF;
  PERFORM pg_catalog.set_config('app.policy_approval_in_progress','true',true);
  UPDATE app.policy_versions
     SET approved_by=v_user,approved_at=pg_catalog.now(),updated_at=pg_catalog.now(),updated_by=v_user
   WHERE tenant_id=v_tenant AND id=p_policy_version_id;
  INSERT INTO app.approvals
    (tenant_id,target_type,target_id,target_version_hash,approver_user_id,comment,created_by)
  VALUES (v_tenant,'policy_version',p_policy_version_id,
    public.digest(pg_catalog.convert_to(v_body,'UTF8'),'sha256'),v_user,p_comment,v_user);
END $$;
ALTER FUNCTION app.approve_policy_version(uuid,text) OWNER TO schema_owner;

CREATE FUNCTION app.register_internal_management_service_principal(
  p_tenant uuid,p_user uuid,p_purpose text
) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
  INSERT INTO app.internal_management_service_principals(tenant_id,user_id,purpose)
  VALUES(p_tenant,p_user,p_purpose)
  ON CONFLICT (tenant_id,user_id) DO NOTHING
$$;
ALTER FUNCTION app.register_internal_management_service_principal(uuid,uuid,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.register_internal_management_service_principal(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.register_internal_management_service_principal(uuid,uuid,text) TO auth_svc;

-- A trusted application proxy may authenticate its own header separately, but
-- this boundary derives both tenant and actor from a live server-held session.
CREATE FUNCTION app.set_tenant_context_for_proxy(p_tenant_token text,p_email citext) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE v_tenant uuid; v_proxy_user uuid; v_user uuid; v_count integer;
BEGIN
  IF session_user <> 'management_web' THEN
    RAISE EXCEPTION 'proxy identity role required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF p_tenant_token IS NULL OR pg_catalog.length(p_tenant_token)<32
     OR p_email IS NULL OR length(btrim(p_email::text))=0 THEN
    RAISE EXCEPTION 'invalid session or identity' USING ERRCODE='insufficient_privilege';
  END IF;
  SELECT s.tenant_id,s.user_id INTO v_tenant,v_proxy_user
    FROM app.sessions s
    JOIN app.memberships m ON m.tenant_id=s.tenant_id AND m.user_id=s.user_id AND m.revoked_at IS NULL
    JOIN app.users u ON u.tenant_id=s.tenant_id AND u.id=s.user_id AND u.status='active'
    JOIN app.tenants t ON t.id=s.tenant_id AND t.status='active'
   WHERE s.token_hash=public.digest(pg_catalog.convert_to(p_tenant_token,'UTF8'),'sha256')
     AND s.expires_at>pg_catalog.now() AND s.revoked_at IS NULL
   LIMIT 1;
  IF v_tenant IS NULL OR v_proxy_user IS NULL THEN
    RAISE EXCEPTION 'invalid session or identity' USING ERRCODE='insufficient_privilege';
  END IF;
  SELECT count(*),(array_agg(id))[1] INTO v_count,v_user FROM (
    SELECT DISTINCT u.id FROM app.users u JOIN app.memberships m
      ON m.tenant_id=u.tenant_id AND m.user_id=u.id AND m.revoked_at IS NULL
     WHERE u.tenant_id=v_tenant AND u.status='active'
       AND lower(u.email::text)=lower(btrim(p_email::text))
  ) active_identity;
  IF v_count<>1 OR v_user IS NULL THEN
    RAISE EXCEPTION 'invalid session or identity' USING ERRCODE='insufficient_privilege';
  END IF;
  PERFORM pg_catalog.set_config('app.tenant_id',v_tenant::text,true);
  PERFORM pg_catalog.set_config('app.tenant_sig',app.tenant_context_signature(v_tenant),true);
  PERFORM pg_catalog.set_config('app.session_user_id',v_user::text,true);
  PERFORM pg_catalog.set_config('app.session_user_sig',app.session_context_signature(v_tenant,v_user),true);
  RETURN v_tenant;
END $$;
ALTER FUNCTION app.set_tenant_context_for_proxy(text,citext) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.set_tenant_context_for_proxy(text,citext) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.set_tenant_context_for_proxy(text,citext) TO management_web;

CREATE FUNCTION app.management_proxy_healthcheck() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user();
BEGIN
  IF session_user <> 'management_web' OR NOT EXISTS (
    SELECT 1 FROM app.memberships m JOIN app.users usr
      ON usr.tenant_id=m.tenant_id AND usr.id=m.user_id
     WHERE m.tenant_id=t AND m.user_id=u
       AND m.role_key IN ('ciso','secretariat','risk_owner')
       AND m.revoked_at IS NULL AND usr.status='active'
  ) THEN
    RAISE EXCEPTION 'management proxy health role required' USING ERRCODE='insufficient_privilege';
  END IF;
  RETURN jsonb_build_object('tenant_id',t,'actor_id',u,'db_role',session_user);
END $$;
ALTER FUNCTION app.management_proxy_healthcheck() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.management_proxy_healthcheck() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.management_proxy_healthcheck() TO management_web;

CREATE FUNCTION app.set_management_frameworks_v2(p_entity_type text,p_entity uuid,p_keys text[],p_origin_kind text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user(); k text; g uuid;
        old app.framework_relation_origins%ROWTYPE;
BEGIN
 IF p_entity_type NOT IN ('asset','risk_scenario','measure')
    OR NOT ('RISK-MANAGEMENT'=ANY(coalesce(p_keys,ARRAY[]::text[]))) THEN
   RAISE EXCEPTION 'management framework required';
 END IF;
 IF p_origin_kind NOT IN ('human','service') THEN
   RAISE EXCEPTION 'invalid framework origin';
 END IF;
 IF p_entity_type='asset' AND EXISTS (SELECT 1 FROM app.asset_frameworks WHERE tenant_id=t AND asset_id=p_entity AND framework_key='ISO27001:2022' AND NOT ('ISO27001:2022'=ANY(p_keys))) THEN RAISE EXCEPTION 'ISO removal requires approval'; END IF;
 IF p_entity_type='risk_scenario' AND EXISTS (SELECT 1 FROM app.risk_scenario_frameworks WHERE tenant_id=t AND risk_scenario_id=p_entity AND framework_key='ISO27001:2022' AND NOT ('ISO27001:2022'=ANY(p_keys))) THEN RAISE EXCEPTION 'ISO removal requires approval'; END IF;
 IF p_entity_type='measure' AND EXISTS (SELECT 1 FROM app.measure_frameworks WHERE tenant_id=t AND measure_id=p_entity AND framework_key='ISO27001:2022' AND NOT ('ISO27001:2022'=ANY(p_keys))) THEN RAISE EXCEPTION 'ISO removal requires approval'; END IF;
 FOR old IN SELECT * FROM app.framework_relation_origins WHERE tenant_id=t AND entity_type=p_entity_type AND entity_id=p_entity AND NOT (framework_key=ANY(p_keys)) LOOP
   IF old.origin_kind='migration' THEN UPDATE app.framework_backfill_provenance SET ownership_released_at=now() WHERE migration_key=old.origin_id AND tenant_id=t AND entity_type=p_entity_type AND entity_id=p_entity AND framework_key=old.framework_key AND generation_id=old.generation_id; END IF;
   INSERT INTO app.framework_relation_events(tenant_id,entity_type,entity_id,framework_key,generation_id,event_kind,actor_id) VALUES(t,p_entity_type,p_entity,old.framework_key,old.generation_id,'deleted',u);
   DELETE FROM app.framework_relation_origins WHERE tenant_id=t AND entity_type=p_entity_type AND entity_id=p_entity AND framework_key=old.framework_key;
   IF p_entity_type='asset' THEN DELETE FROM app.asset_frameworks WHERE tenant_id=t AND asset_id=p_entity AND framework_key=old.framework_key;
   ELSIF p_entity_type='risk_scenario' THEN DELETE FROM app.risk_scenario_frameworks WHERE tenant_id=t AND risk_scenario_id=p_entity AND framework_key=old.framework_key;
   ELSE DELETE FROM app.measure_frameworks WHERE tenant_id=t AND measure_id=p_entity AND framework_key=old.framework_key; END IF;
 END LOOP;
 FOREACH k IN ARRAY p_keys LOOP
   g:=gen_random_uuid();
   IF p_entity_type='asset' THEN INSERT INTO app.asset_frameworks VALUES(t,p_entity,k) ON CONFLICT DO NOTHING;
   ELSIF p_entity_type='risk_scenario' THEN INSERT INTO app.risk_scenario_frameworks VALUES(t,p_entity,k) ON CONFLICT DO NOTHING;
   ELSE INSERT INTO app.measure_frameworks VALUES(t,p_entity,k) ON CONFLICT DO NOTHING; END IF;
   IF FOUND THEN
     INSERT INTO app.framework_relation_origins VALUES(t,p_entity_type,p_entity,k,g,p_origin_kind,'0050_management_db_boundary_m1');
     INSERT INTO app.framework_relation_events(tenant_id,entity_type,entity_id,framework_key,generation_id,event_kind,actor_id) VALUES(t,p_entity_type,p_entity,k,g,'created',u);
   END IF;
 END LOOP;
END $$;
ALTER FUNCTION app.set_management_frameworks_v2(text,uuid,text[],text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.set_management_frameworks_v2(text,uuid,text[],text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.set_management_frameworks(text,uuid,text[]) FROM app_rw;

CREATE FUNCTION app.set_management_frameworks_human(
  p_entity_type text,p_entity uuid,p_keys text[]
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user();
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM app.memberships m JOIN app.users usr
      ON usr.tenant_id=m.tenant_id AND usr.id=m.user_id
     WHERE m.tenant_id=t AND m.user_id=u
       AND m.role_key IN ('ciso','secretariat','risk_owner')
       AND m.revoked_at IS NULL AND usr.status='active'
  ) THEN
    RAISE EXCEPTION 'management framework role required' USING ERRCODE='insufficient_privilege';
  END IF;
  PERFORM app.set_management_frameworks_v2(p_entity_type,p_entity,p_keys,'human');
END $$;
ALTER FUNCTION app.set_management_frameworks_human(text,uuid,text[]) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.set_management_frameworks_human(text,uuid,text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.set_management_frameworks_human(text,uuid,text[]) TO app_rw;

CREATE FUNCTION app.execute_iso_framework_removal_v2(p_request uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user(); r app.iso_framework_removal_requests%ROWTYPE;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM app.memberships m JOIN app.users usr ON usr.tenant_id=m.tenant_id AND usr.id=m.user_id
                WHERE m.tenant_id=t AND m.user_id=u AND m.role_key IN ('ciso','secretariat')
                  AND m.revoked_at IS NULL AND usr.status='active') THEN
   RAISE EXCEPTION 'ISO removal executor role required' USING ERRCODE='insufficient_privilege';
 END IF;
 SELECT * INTO r FROM app.iso_framework_removal_requests WHERE tenant_id=t AND id=p_request FOR UPDATE;
 IF NOT FOUND OR r.status<>'approved' OR r.expires_at<=now() THEN RAISE EXCEPTION 'removal request unavailable'; END IF;
 IF NOT EXISTS(SELECT 1 FROM app.framework_relation_origins o WHERE o.tenant_id=t AND o.entity_type=r.entity_type AND o.entity_id=r.entity_id AND o.framework_key='ISO27001:2022' AND o.generation_id=r.expected_generation_id) THEN RAISE EXCEPTION 'framework generation conflict'; END IF;
 IF r.entity_type='asset' THEN DELETE FROM app.asset_frameworks WHERE tenant_id=t AND asset_id=r.entity_id AND framework_key='ISO27001:2022';
 ELSIF r.entity_type='risk_scenario' THEN DELETE FROM app.risk_scenario_frameworks WHERE tenant_id=t AND risk_scenario_id=r.entity_id AND framework_key='ISO27001:2022';
 ELSE DELETE FROM app.measure_frameworks WHERE tenant_id=t AND measure_id=r.entity_id AND framework_key='ISO27001:2022'; END IF;
 DELETE FROM app.framework_relation_origins WHERE tenant_id=t AND entity_type=r.entity_type AND entity_id=r.entity_id AND framework_key='ISO27001:2022' AND generation_id=r.expected_generation_id;
 INSERT INTO app.framework_relation_events(tenant_id,entity_type,entity_id,framework_key,generation_id,event_kind,actor_id) VALUES(t,r.entity_type,r.entity_id,'ISO27001:2022',r.expected_generation_id,'deleted',app.current_session_user());
 UPDATE app.iso_framework_removal_requests SET status='executed' WHERE tenant_id=t AND id=p_request;
END $$;
ALTER FUNCTION app.execute_iso_framework_removal_v2(uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.execute_iso_framework_removal_v2(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.execute_iso_framework_removal_v2(uuid) TO app_rw;
REVOKE EXECUTE ON FUNCTION app.execute_iso_framework_removal(uuid) FROM app_rw;
CREATE OR REPLACE FUNCTION app.request_iso_framework_removal(p_entity_type text,p_entity uuid,p_generation uuid,p_before bytea,p_after bytea,p_reason text,p_alternate text,p_expires timestamptz) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user(); x uuid; actual bytea; expected_after bytea;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM app.memberships m JOIN app.users usr ON usr.tenant_id=m.tenant_id AND usr.id=m.user_id
                WHERE m.tenant_id=t AND m.user_id=u AND m.role_key IN ('ciso','secretariat','risk_owner')
                  AND m.revoked_at IS NULL AND usr.status='active') THEN
   RAISE EXCEPTION 'ISO removal requester role required' USING ERRCODE='insufficient_privilege';
 END IF;
 IF p_expires<=now() THEN RAISE EXCEPTION 'expiry required'; END IF;
 IF NOT EXISTS(SELECT 1 FROM app.framework_relation_origins WHERE tenant_id=t AND entity_type=p_entity_type AND entity_id=p_entity AND framework_key='ISO27001:2022' AND generation_id=p_generation) THEN RAISE EXCEPTION 'framework generation conflict'; END IF;
 SELECT public.digest(convert_to(p_entity_type||':'||p_entity::text||':ISO27001:2022:'||p_generation::text,'UTF8'),'sha256') INTO actual;
 IF p_before IS DISTINCT FROM actual THEN RAISE EXCEPTION 'framework snapshot hash mismatch'; END IF;
 SELECT public.digest(convert_to(p_entity_type||':'||p_entity::text||':WITHOUT:ISO27001:2022:'||p_generation::text,'UTF8'),'sha256') INTO expected_after;
 IF p_after IS DISTINCT FROM expected_after OR p_after=p_before THEN RAISE EXCEPTION 'framework after hash mismatch'; END IF;
 INSERT INTO app.iso_framework_removal_requests(tenant_id,entity_type,entity_id,expected_generation_id,before_hash,after_hash,reason,alternate_control,expires_at,requested_by) VALUES(t,p_entity_type,p_entity,p_generation,p_before,p_after,p_reason,p_alternate,p_expires,u) RETURNING id INTO x;
 RETURN x;
END $$;
CREATE OR REPLACE FUNCTION app.approve_iso_framework_removal(p_request uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user(); r app.iso_framework_removal_requests%ROWTYPE;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM app.memberships m JOIN app.users usr ON usr.tenant_id=m.tenant_id AND usr.id=m.user_id
                WHERE m.tenant_id=t AND m.user_id=u AND m.role_key='ciso'
                  AND m.revoked_at IS NULL AND usr.status='active') THEN
   RAISE EXCEPTION 'executive role required' USING ERRCODE='insufficient_privilege';
 END IF;
 SELECT * INTO r FROM app.iso_framework_removal_requests WHERE tenant_id=t AND id=p_request FOR UPDATE;
 IF NOT FOUND OR r.status<>'requested' OR r.expires_at<=now() THEN RAISE EXCEPTION 'removal request unavailable'; END IF;
 IF r.requested_by=u THEN RAISE EXCEPTION 'self approval prohibited' USING ERRCODE='insufficient_privilege'; END IF;
 UPDATE app.iso_framework_removal_requests SET status='approved',approved_by=u,approved_at=now() WHERE tenant_id=t AND id=p_request;
END $$;
ALTER FUNCTION app.request_iso_framework_removal(text,uuid,uuid,bytea,bytea,text,text,timestamptz) OWNER TO schema_owner;
ALTER FUNCTION app.approve_iso_framework_removal(uuid) OWNER TO schema_owner;
ALTER TABLE app.iso_framework_removal_requests
  DROP CONSTRAINT iso_framework_removal_requests_entity_type_check,
  ADD CONSTRAINT iso_framework_removal_requests_entity_type_check
    CHECK (entity_type IN ('asset','risk_scenario','measure'));

CREATE OR REPLACE FUNCTION app.accept_risk_snapshot(
  p_risk uuid, p_evaluation uuid, p_evaluation_hash text, p_inherent uuid, p_inherent_hash text, p_reason text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user(); residual app.risk_evaluation_snapshots%ROWTYPE; inherent app.risk_evaluation_snapshots%ROWTYPE; out_id uuid; v_version integer;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM app.memberships m JOIN app.users usr ON usr.tenant_id=m.tenant_id AND usr.id=m.user_id WHERE m.tenant_id=t AND m.user_id=u AND m.role_key='ciso' AND m.revoked_at IS NULL AND usr.status='active') THEN RAISE EXCEPTION 'executive role required' USING ERRCODE='insufficient_privilege'; END IF;
  LOCK TABLE app.risk_evaluation_snapshots IN SHARE MODE;
  SELECT * INTO residual FROM app.risk_evaluation_snapshots
   WHERE tenant_id=t AND risk_scenario_id=p_risk AND stage='after_measure'
     AND assessed_on<=(now() AT TIME ZONE 'Asia/Tokyo')::date
   ORDER BY assessed_on DESC,created_at DESC,id DESC LIMIT 1;
  IF residual.id IS NULL THEN RAISE EXCEPTION 'risk snapshot unavailable'; END IF;
  SELECT * INTO inherent FROM app.risk_evaluation_snapshots
   WHERE tenant_id=t AND risk_scenario_id=p_risk AND stage='inherent'
     AND assessed_on=residual.assessed_on
   ORDER BY created_at DESC,id DESC LIMIT 1;
  IF inherent.id IS NULL OR residual.id<>p_evaluation OR inherent.id<>p_inherent THEN
    RAISE EXCEPTION 'stale or invalid risk snapshot evidence';
  END IF;
  IF app.risk_evaluation_snapshot_sha256(residual)<>p_evaluation_hash OR app.risk_evaluation_snapshot_sha256(inherent)<>p_inherent_hash THEN RAISE EXCEPTION 'risk snapshot hash mismatch'; END IF;
  IF residual.risk_level>inherent.risk_level THEN RAISE EXCEPTION 'residual exceeds inherent'; END IF;
  SELECT count(*)::integer INTO v_version FROM app.risk_evaluation_snapshots WHERE tenant_id=t AND risk_scenario_id=p_risk;
  INSERT INTO app.risk_acceptances(tenant_id,risk_scenario_id,expected_version,residual_level,inherent_level,reason,accepted_by,evaluation_snapshot_id,evaluation_snapshot_sha256,inherent_snapshot_id,inherent_snapshot_sha256)
  VALUES(t,p_risk,v_version,residual.risk_level,inherent.risk_level,p_reason,u,residual.id,p_evaluation_hash,inherent.id,p_inherent_hash) RETURNING id INTO out_id;
  RETURN out_id;
END $$;
ALTER FUNCTION app.accept_risk_snapshot(uuid,uuid,text,uuid,text,text) OWNER TO schema_owner;

CREATE FUNCTION app.accept_risk_snapshot_human(
  p_risk uuid,p_evaluation uuid,p_evaluation_hash text,
  p_inherent uuid,p_inherent_hash text,p_reason text
) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
  SELECT app.accept_risk_snapshot(
    p_risk,p_evaluation,p_evaluation_hash,p_inherent,p_inherent_hash,p_reason
  )
$$;
ALTER FUNCTION app.accept_risk_snapshot_human(uuid,uuid,text,uuid,text,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.accept_risk_snapshot_human(uuid,uuid,text,uuid,text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.accept_risk_snapshot_human(uuid,uuid,text,uuid,text,text) FROM app_rw;

CREATE FUNCTION app.internal_acceptance_binding_sha256(
  p_operation_id text,p_requester uuid,p_risk uuid,p_evaluation uuid,
  p_evaluation_hash text,p_inherent uuid,p_inherent_hash text,
  p_policy_version_id uuid,p_policy_version_hash text,p_reason text,p_expires_at timestamptz
) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
  SELECT encode(public.digest(convert_to(jsonb_build_array(
    p_operation_id,p_requester,p_risk,p_evaluation,p_evaluation_hash,
    p_inherent,p_inherent_hash,p_policy_version_id,p_policy_version_hash,p_reason,p_expires_at
  )::text,'UTF8'),'sha256'),'hex')
$$;
ALTER FUNCTION app.internal_acceptance_binding_sha256(text,uuid,uuid,uuid,text,uuid,text,uuid,text,text,timestamptz) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.internal_acceptance_binding_sha256(text,uuid,uuid,uuid,text,uuid,text,uuid,text,text,timestamptz) FROM PUBLIC;

CREATE FUNCTION app.approve_internal_risk_acceptance(
  p_operation_id text,p_risk uuid,p_evaluation uuid,p_evaluation_hash text,
  p_inherent uuid,p_inherent_hash text,p_policy_version_id uuid,
  p_policy_version_hash text,p_reason text,p_expires_at timestamptz
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE
  t uuid:=app.current_tenant(); requester uuid:=app.current_session_user();
  residual app.risk_evaluation_snapshots%ROWTYPE;
  inherent app.risk_evaluation_snapshots%ROWTYPE;
  actual_policy_hash text; binding_hash text; approval_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM app.memberships m JOIN app.users u
      ON u.tenant_id=m.tenant_id AND u.id=m.user_id
     WHERE m.tenant_id=t AND m.user_id=requester AND m.role_key='ciso'
       AND m.revoked_at IS NULL AND u.status='active'
  ) THEN RAISE EXCEPTION 'MANAGEMENT_REQUESTER_FORBIDDEN' USING ERRCODE='insufficient_privilege'; END IF;
  IF length(btrim(coalesce(p_reason,'')))=0 OR p_expires_at IS NULL OR p_expires_at<=now() THEN
    RAISE EXCEPTION 'MANAGEMENT_ACCEPTANCE_PAYLOAD_INVALID';
  END IF;
  LOCK TABLE app.risk_evaluation_snapshots IN SHARE MODE;
  -- Deterministic latest order: business date, write time, then UUID.
  SELECT * INTO residual FROM app.risk_evaluation_snapshots
   WHERE tenant_id=t AND risk_scenario_id=p_risk AND stage='after_measure'
     AND assessed_on<=(now() AT TIME ZONE 'Asia/Tokyo')::date
   ORDER BY assessed_on DESC,created_at DESC,id DESC LIMIT 1;
  SELECT * INTO inherent FROM app.risk_evaluation_snapshots
   WHERE tenant_id=t AND risk_scenario_id=p_risk AND stage='inherent'
     AND assessed_on=residual.assessed_on
   ORDER BY created_at DESC,id DESC LIMIT 1;
  IF residual.id IS NULL OR inherent.id IS NULL OR residual.id<>p_evaluation OR inherent.id<>p_inherent
     OR app.risk_evaluation_snapshot_sha256(residual)<>p_evaluation_hash
     OR app.risk_evaluation_snapshot_sha256(inherent)<>p_inherent_hash THEN
    RAISE EXCEPTION 'MANAGEMENT_SNAPSHOT_STALE';
  END IF;
  SELECT encode(public.digest(convert_to(pv.body_md,'UTF8'),'sha256'),'hex')
    INTO actual_policy_hash FROM app.policy_versions pv
   WHERE pv.tenant_id=t AND pv.id=p_policy_version_id AND pv.approved_at IS NOT NULL
     AND pv.effective_from <= (now() AT TIME ZONE 'Asia/Tokyo')::date
     AND (pv.superseded_at IS NULL OR pv.superseded_at > now());
  IF actual_policy_hash IS NULL OR actual_policy_hash<>p_policy_version_hash THEN
    RAISE EXCEPTION 'MANAGEMENT_POLICY_INVALID';
  END IF;
  binding_hash:=app.internal_acceptance_binding_sha256(
    p_operation_id,requester,p_risk,p_evaluation,p_evaluation_hash,
    p_inherent,p_inherent_hash,p_policy_version_id,p_policy_version_hash,p_reason,p_expires_at);
  PERFORM pg_advisory_xact_lock(hashtextextended('approval:'||p_operation_id,0));
  SELECT id INTO approval_id FROM app.internal_management_acceptance_approvals
   WHERE tenant_id=t AND operation_id=p_operation_id
     AND requester_actor_id=requester AND risk_scenario_id=p_risk
     AND evaluation_snapshot_id=p_evaluation
     AND evaluation_snapshot_sha256=p_evaluation_hash
     AND inherent_snapshot_id=p_inherent
     AND inherent_snapshot_sha256=p_inherent_hash
     AND policy_version_id=p_policy_version_id
     AND policy_version_sha256=p_policy_version_hash
     AND acceptance_reason=p_reason AND acceptance_expires_at=p_expires_at
     AND binding_sha256=binding_hash;
  IF FOUND THEN RETURN approval_id; END IF;
  IF EXISTS (SELECT 1 FROM app.internal_management_acceptance_approvals
              WHERE tenant_id=t AND operation_id=p_operation_id) THEN
    RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT';
  END IF;
  INSERT INTO app.internal_management_acceptance_approvals(
    tenant_id,operation_id,requester_actor_id,risk_scenario_id,
    evaluation_snapshot_id,evaluation_snapshot_sha256,
    inherent_snapshot_id,inherent_snapshot_sha256,
    policy_version_id,policy_version_sha256,acceptance_reason,acceptance_expires_at,binding_sha256
  ) VALUES (
    t,p_operation_id,requester,p_risk,p_evaluation,p_evaluation_hash,
    p_inherent,p_inherent_hash,p_policy_version_id,p_policy_version_hash,p_reason,p_expires_at,binding_hash
  ) RETURNING id INTO approval_id;
  RETURN approval_id;
END $$;
ALTER FUNCTION app.approve_internal_risk_acceptance(text,uuid,uuid,text,uuid,text,uuid,text,text,timestamptz) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.approve_internal_risk_acceptance(text,uuid,uuid,text,uuid,text,uuid,text,text,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.approve_internal_risk_acceptance(text,uuid,uuid,text,uuid,text,uuid,text,text,timestamptz) TO app_rw;

-- These are deliberately action-specific: no caller can manufacture a receipt
-- without the matching domain mutation and its authorization checks.
CREATE FUNCTION app.internal_tag_iso(
  p_operation_id text,p_request_sha256 text,p_requester uuid,p_role text,p_risk uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); actor uuid:=app.current_session_user(); audit_id uuid; receipt jsonb; keys text[];
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM app.internal_management_service_principals sp JOIN app.users u
      ON u.tenant_id=sp.tenant_id AND u.id=sp.user_id
     WHERE sp.tenant_id=t AND sp.user_id=actor AND u.status='active'
  ) THEN RAISE EXCEPTION 'MANAGEMENT_SERVICE_FORBIDDEN' USING ERRCODE='insufficient_privilege'; END IF;
  IF p_role NOT IN ('ciso','secretariat') OR NOT EXISTS (
    SELECT 1 FROM app.memberships m JOIN app.users u
      ON u.tenant_id=m.tenant_id AND u.id=m.user_id
     WHERE m.tenant_id=t AND m.user_id=p_requester AND m.role_key=p_role
       AND m.revoked_at IS NULL AND u.status='active'
  ) THEN RAISE EXCEPTION 'MANAGEMENT_REQUESTER_FORBIDDEN' USING ERRCODE='insufficient_privilege'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_operation_id,0));
  SELECT o.receipt INTO receipt FROM app.internal_management_operations o
   WHERE o.tenant_id=t AND o.operation_id=p_operation_id;
  IF FOUND THEN
    IF (SELECT request_sha256 FROM app.internal_management_operations WHERE tenant_id=t AND operation_id=p_operation_id) <> p_request_sha256 THEN RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT'; END IF;
    RETURN receipt;
  END IF;
  PERFORM 1 FROM app.risk_scenarios WHERE tenant_id=t AND id=p_risk FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RISK_NOT_FOUND'; END IF;
  SELECT array_agg(DISTINCT framework_key ORDER BY framework_key)
    INTO keys FROM (
      SELECT framework_key FROM app.risk_scenario_frameworks
       WHERE tenant_id=t AND risk_scenario_id=p_risk
      UNION ALL SELECT 'RISK-MANAGEMENT'
      UNION ALL SELECT 'ISO27001:2022'
    ) framework_keys;
  PERFORM app.set_management_frameworks_v2('risk_scenario',p_risk,keys,'service');
  INSERT INTO app.internal_management_audit_events(tenant_id,operation_id,action,actor_id,requester_actor_id,risk_scenario_id,origin_kind)
  VALUES(t,p_operation_id,'tag_iso',actor,p_requester,p_risk,'service') RETURNING id INTO audit_id;
  receipt:=jsonb_build_object('risk_id',p_risk,'audit_event_id',audit_id);
  INSERT INTO app.internal_management_operations(tenant_id,operation_id,action,request_sha256,receipt,actor_id,requester_actor_id,origin_kind)
  VALUES(t,p_operation_id,'tag_iso',p_request_sha256,receipt,actor,p_requester,'service');
  RETURN receipt;
END $$;

CREATE FUNCTION app.internal_accept_risk(
  p_operation_id text,p_request_sha256 text,p_requester uuid,p_role text,
  p_approval_id uuid,p_policy_version_id uuid,p_policy_version_hash text,
  p_risk uuid,p_evaluation uuid,
  p_evaluation_hash text,p_inherent uuid,p_inherent_hash text,p_reason text,p_expires_at timestamptz
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); actor uuid:=app.current_session_user(); residual app.risk_evaluation_snapshots%ROWTYPE; inherent app.risk_evaluation_snapshots%ROWTYPE; approval app.internal_management_acceptance_approvals%ROWTYPE; acceptance_id uuid; audit_id uuid; receipt jsonb; expected_version integer; expected_binding text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM app.internal_management_service_principals sp JOIN app.users u
      ON u.tenant_id=sp.tenant_id AND u.id=sp.user_id
     WHERE sp.tenant_id=t AND sp.user_id=actor AND u.status='active'
  ) THEN RAISE EXCEPTION 'MANAGEMENT_SERVICE_FORBIDDEN' USING ERRCODE='insufficient_privilege'; END IF;
  IF p_role <> 'ciso' OR NOT EXISTS (
    SELECT 1 FROM app.memberships m JOIN app.users u
      ON u.tenant_id=m.tenant_id AND u.id=m.user_id
     WHERE m.tenant_id=t AND m.user_id=p_requester AND m.role_key='ciso'
       AND m.revoked_at IS NULL AND u.status='active'
  ) THEN RAISE EXCEPTION 'MANAGEMENT_REQUESTER_FORBIDDEN' USING ERRCODE='insufficient_privilege'; END IF;
  SELECT * INTO approval FROM app.internal_management_acceptance_approvals
   WHERE tenant_id=t AND id=p_approval_id FOR KEY SHARE;
  expected_binding:=app.internal_acceptance_binding_sha256(
    p_operation_id,p_requester,p_risk,p_evaluation,p_evaluation_hash,
    p_inherent,p_inherent_hash,p_policy_version_id,p_policy_version_hash,p_reason,p_expires_at);
  IF approval.id IS NULL OR approval.operation_id<>p_operation_id
     OR approval.requester_actor_id<>p_requester OR approval.risk_scenario_id<>p_risk
     OR approval.evaluation_snapshot_id<>p_evaluation
     OR approval.evaluation_snapshot_sha256<>p_evaluation_hash
     OR approval.inherent_snapshot_id<>p_inherent
     OR approval.inherent_snapshot_sha256<>p_inherent_hash
     OR approval.policy_version_id<>p_policy_version_id
     OR approval.policy_version_sha256<>p_policy_version_hash
     OR approval.acceptance_reason<>p_reason
     OR approval.acceptance_expires_at<>p_expires_at
     OR approval.binding_sha256<>expected_binding THEN
    RAISE EXCEPTION 'MANAGEMENT_APPROVAL_INVALID';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app.policy_versions pv
                  WHERE pv.tenant_id=t AND pv.id=p_policy_version_id
                    AND pv.approved_at IS NOT NULL
                    AND pv.effective_from <= (now() AT TIME ZONE 'Asia/Tokyo')::date
                    AND (pv.superseded_at IS NULL OR pv.superseded_at > now())) THEN
    RAISE EXCEPTION 'MANAGEMENT_POLICY_INVALID';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_operation_id,0));
  SELECT o.receipt INTO receipt FROM app.internal_management_operations o
   WHERE o.tenant_id=t AND o.operation_id=p_operation_id;
  IF FOUND THEN
    IF (SELECT request_sha256 FROM app.internal_management_operations WHERE tenant_id=t AND operation_id=p_operation_id) <> p_request_sha256 THEN RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT'; END IF;
    RETURN receipt;
  END IF;
  PERFORM 1 FROM app.risk_scenarios WHERE tenant_id=t AND id=p_risk FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RISK_NOT_FOUND'; END IF;
  LOCK TABLE app.risk_evaluation_snapshots IN SHARE MODE;
  SELECT * INTO residual FROM app.risk_evaluation_snapshots
   WHERE tenant_id=t AND risk_scenario_id=p_risk AND stage='after_measure'
     AND assessed_on<=(now() AT TIME ZONE 'Asia/Tokyo')::date
   ORDER BY assessed_on DESC,created_at DESC,id DESC LIMIT 1;
  IF residual.id IS NULL THEN RAISE EXCEPTION 'risk snapshot unavailable'; END IF;
  SELECT * INTO inherent FROM app.risk_evaluation_snapshots
   WHERE tenant_id=t AND risk_scenario_id=p_risk AND stage='inherent' AND assessed_on=residual.assessed_on
   ORDER BY created_at DESC,id DESC LIMIT 1;
  IF inherent.id IS NULL OR residual.id<>p_evaluation OR inherent.id<>p_inherent
     OR app.risk_evaluation_snapshot_sha256(residual)<>p_evaluation_hash
     OR app.risk_evaluation_snapshot_sha256(inherent)<>p_inherent_hash THEN RAISE EXCEPTION 'MANAGEMENT_SNAPSHOT_STALE'; END IF;
  IF residual.risk_level>inherent.risk_level THEN RAISE EXCEPTION 'residual exceeds inherent'; END IF;
  SELECT count(*)::integer INTO expected_version FROM app.risk_evaluation_snapshots WHERE tenant_id=t AND risk_scenario_id=p_risk;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
              WHERE a.attrelid='app.risk_acceptances'::regclass AND a.attname='expires_at'
                AND NOT a.attisdropped) THEN
    EXECUTE 'INSERT INTO app.risk_acceptances(tenant_id,risk_scenario_id,expected_version,residual_level,inherent_level,reason,accepted_by,evaluation_snapshot_id,evaluation_snapshot_sha256,inherent_snapshot_id,inherent_snapshot_sha256,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) RETURNING id'
      INTO acceptance_id USING t,p_risk,expected_version,residual.risk_level,inherent.risk_level,p_reason,p_requester,residual.id,p_evaluation_hash,inherent.id,p_inherent_hash,p_expires_at;
  ELSE
    INSERT INTO app.risk_acceptances(tenant_id,risk_scenario_id,expected_version,residual_level,inherent_level,reason,accepted_by,evaluation_snapshot_id,evaluation_snapshot_sha256,inherent_snapshot_id,inherent_snapshot_sha256)
    VALUES(t,p_risk,expected_version,residual.risk_level,inherent.risk_level,p_reason,p_requester,residual.id,p_evaluation_hash,inherent.id,p_inherent_hash) RETURNING id INTO acceptance_id;
  END IF;
  INSERT INTO app.internal_management_audit_events(tenant_id,operation_id,action,actor_id,requester_actor_id,risk_scenario_id,evaluation_snapshot_id,evaluation_snapshot_sha256,inherent_snapshot_id,inherent_snapshot_sha256,origin_kind,approval_id,policy_version_id,policy_version_sha256,acceptance_reason,acceptance_expires_at)
  VALUES(t,p_operation_id,'accept_risk',actor,p_requester,p_risk,residual.id,p_evaluation_hash,inherent.id,p_inherent_hash,'service',p_approval_id,p_policy_version_id,p_policy_version_hash,p_reason,p_expires_at) RETURNING id INTO audit_id;
  receipt:=jsonb_build_object('risk_id',p_risk,'acceptance_id',acceptance_id,'audit_event_id',audit_id);
  INSERT INTO app.internal_management_operations(tenant_id,operation_id,action,request_sha256,receipt,actor_id,requester_actor_id,origin_kind,approval_id,policy_version_id,policy_version_sha256,acceptance_reason,acceptance_expires_at)
  VALUES(t,p_operation_id,'accept_risk',p_request_sha256,receipt,actor,p_requester,'service',p_approval_id,p_policy_version_id,p_policy_version_hash,p_reason,p_expires_at);
  RETURN receipt;
END $$;
ALTER FUNCTION app.internal_tag_iso(text,text,uuid,text,uuid) OWNER TO schema_owner;
ALTER FUNCTION app.internal_accept_risk(text,text,uuid,text,uuid,uuid,text,uuid,uuid,text,uuid,text,text,timestamptz) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.internal_tag_iso(text,text,uuid,text,uuid),app.internal_accept_risk(text,text,uuid,text,uuid,uuid,text,uuid,uuid,text,uuid,text,text,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.internal_tag_iso(text,text,uuid,text,uuid),app.internal_accept_risk(text,text,uuid,text,uuid,uuid,text,uuid,uuid,text,uuid,text,text,timestamptz) TO app_rw;
REVOKE EXECUTE ON FUNCTION app.accept_risk_snapshot(uuid,uuid,text,uuid,text,text),app.set_management_frameworks_v2(text,uuid,text[],text) FROM app_rw;

REVOKE INSERT,UPDATE,DELETE ON app.asset_frameworks,app.risk_scenario_frameworks,app.measure_frameworks,
  app.framework_relation_origins,app.framework_relation_events,app.framework_backfill_provenance,
  app.risk_acceptances,app.iso_framework_removal_requests,app.internal_management_operations,
  app.internal_management_audit_events FROM app_rw;
REVOKE INSERT,UPDATE,DELETE ON app.approvals FROM app_rw;
REVOKE EXECUTE ON FUNCTION app.accept_risk(uuid,integer,smallint,smallint,text) FROM app_rw;
REVOKE ALL ON FUNCTION app.accept_risk(uuid,integer,smallint,smallint,text) FROM PUBLIC;

DO $$
DECLARE row record;
BEGIN
  FOR row IN SELECT table_name FROM m1_migrator_select_state WHERE NOT had_select LOOP
    EXECUTE format('REVOKE SELECT ON app.%I FROM %I',row.table_name,current_user);
  END LOOP;
END $$;
