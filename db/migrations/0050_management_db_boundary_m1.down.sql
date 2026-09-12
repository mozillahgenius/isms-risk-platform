-- @run-as: admin
-- 0049 cannot encode M1's actor/provenance/audit evidence.  Only the initial
-- legacy-origin and migration-backfill rows may be removed by this rollback.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM app.framework_relation_origins WHERE origin_kind IN ('human','service'))
     OR EXISTS (SELECT 1 FROM app.framework_relation_events WHERE actor_id IS NOT NULL)
     OR EXISTS (SELECT 1 FROM app.iso_framework_removal_requests WHERE entity_type='measure')
     OR EXISTS (SELECT 1 FROM app.internal_management_service_principals)
     OR EXISTS (SELECT 1 FROM app.internal_management_acceptance_approvals)
     OR EXISTS (SELECT 1 FROM app.internal_management_operations)
     OR EXISTS (SELECT 1 FROM app.internal_management_audit_events) THEN
    RAISE EXCEPTION '0050 rollback blocked by non-representable management evidence';
  END IF;
END $$;
UPDATE catalog.frameworks
   SET name_ja = 'リスクマネジメント＋ISMS',
       source_note = '自社のリスク台帳・ISMS運用を横断して見るための枠組みタグ。規格本文ではない。'
 WHERE key = 'RISK-MANAGEMENT';

DROP FUNCTION IF EXISTS app.internal_accept_risk(text,text,uuid,text,uuid,uuid,text,uuid,uuid,text,uuid,text,text,timestamptz);
DROP FUNCTION IF EXISTS app.internal_tag_iso(text,text,uuid,text,uuid);
DROP FUNCTION IF EXISTS app.approve_internal_risk_acceptance(text,uuid,uuid,text,uuid,text,uuid,text,text,timestamptz);
DROP FUNCTION IF EXISTS app.internal_acceptance_binding_sha256(text,uuid,uuid,uuid,text,uuid,text,uuid,text,text,timestamptz);
DROP FUNCTION IF EXISTS app.register_internal_management_service_principal(uuid,uuid,text);
DROP FUNCTION IF EXISTS app.set_tenant_context_for_proxy(text,citext);
DROP FUNCTION IF EXISTS app.management_proxy_healthcheck();
DROP FUNCTION IF EXISTS app.accept_risk_snapshot_human(uuid,uuid,text,uuid,text,text);
DROP FUNCTION IF EXISTS app.set_management_frameworks_human(text,uuid,text[]);
DROP TRIGGER IF EXISTS risk_acceptances_immutable ON app.risk_acceptances;
DROP TRIGGER IF EXISTS internal_management_acceptance_approvals_immutable ON app.internal_management_acceptance_approvals;
DROP TRIGGER IF EXISTS framework_relation_events_immutable ON app.framework_relation_events;
DROP TRIGGER IF EXISTS internal_management_audit_events_immutable ON app.internal_management_audit_events;
DROP TRIGGER IF EXISTS internal_management_operations_immutable ON app.internal_management_operations;
DROP FUNCTION IF EXISTS app.reject_immutable_management_evidence();
DROP TRIGGER IF EXISTS measure_management_relation_required ON app.measure_frameworks;
DROP TRIGGER IF EXISTS risk_management_relation_required ON app.risk_scenario_frameworks;
DROP TRIGGER IF EXISTS asset_management_relation_required ON app.asset_frameworks;
DROP TRIGGER IF EXISTS active_measure_requires_management ON app.measures;
DROP TRIGGER IF EXISTS active_risk_requires_management ON app.risk_scenarios;
DROP TRIGGER IF EXISTS active_asset_requires_management ON app.assets;
DROP FUNCTION IF EXISTS app.assert_active_management_framework();
DROP POLICY IF EXISTS management_definer_access ON app.memberships;
DROP POLICY IF EXISTS management_definer_access ON app.users;
DROP POLICY IF EXISTS management_definer_access ON app.risk_scenarios;
DROP POLICY IF EXISTS management_definer_access ON app.approvals;
DROP POLICY IF EXISTS management_definer_access ON app.policy_versions;
DROP POLICY IF EXISTS management_definer_access ON app.risk_evaluation_snapshots;
DROP POLICY IF EXISTS management_definer_access ON app.risk_acceptances;
DROP POLICY IF EXISTS management_definer_access ON app.iso_framework_removal_requests;
DROP POLICY IF EXISTS management_definer_access ON app.framework_backfill_provenance;
DROP POLICY IF EXISTS management_definer_access ON app.framework_relation_events;
DROP POLICY IF EXISTS management_definer_access ON app.framework_relation_origins;
DROP POLICY IF EXISTS management_definer_access ON app.measure_frameworks;
DROP POLICY IF EXISTS management_definer_access ON app.risk_scenario_frameworks;
DROP POLICY IF EXISTS management_definer_access ON app.asset_frameworks;
DROP POLICY IF EXISTS management_definer_access ON app.internal_management_operations;
DROP POLICY IF EXISTS management_definer_access ON app.internal_management_audit_events;
DROP POLICY IF EXISTS management_definer_access ON app.internal_management_service_principals;
DROP POLICY IF EXISTS management_definer_access ON app.internal_management_acceptance_approvals;
DROP POLICY IF EXISTS management_service_principal_provision ON app.internal_management_service_principals;
DROP POLICY IF EXISTS management_service_principal_read ON app.internal_management_service_principals;
-- 0049 cannot represent measure origins or measure ISO-removal requests.  Do
-- not silently discard post-M1 human/service evidence just to complete a down.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM app.framework_relation_origins
     WHERE entity_type='measure' AND origin_kind IN ('human','service')
  ) OR EXISTS (
    SELECT 1 FROM app.iso_framework_removal_requests WHERE entity_type='measure'
  ) THEN
    RAISE EXCEPTION '0050 rollback blocked by measure management evidence';
  END IF;
END $$;
DELETE FROM app.framework_relation_events e USING app.framework_relation_origins o
 WHERE o.origin_kind='legacy' AND o.origin_id='pre-0050'
   AND e.tenant_id=o.tenant_id AND e.entity_type=o.entity_type AND e.entity_id=o.entity_id
   AND e.framework_key=o.framework_key AND e.generation_id=o.generation_id;
DELETE FROM app.framework_relation_events WHERE generation_id IN (
  SELECT generation_id FROM app.framework_backfill_provenance WHERE migration_key='0050_management_db_boundary_m1'
);
DELETE FROM app.asset_frameworks af USING app.framework_backfill_provenance p
 WHERE p.migration_key='0050_management_db_boundary_m1' AND p.entity_type='asset'
   AND p.relation_created_by_migration AND p.ownership_released_at IS NULL
   AND af.tenant_id=p.tenant_id AND af.asset_id=p.entity_id AND af.framework_key=p.framework_key;
DELETE FROM app.risk_scenario_frameworks rf USING app.framework_backfill_provenance p
 WHERE p.migration_key='0050_management_db_boundary_m1' AND p.entity_type='risk_scenario'
   AND p.relation_created_by_migration AND p.ownership_released_at IS NULL
   AND rf.tenant_id=p.tenant_id AND rf.risk_scenario_id=p.entity_id AND rf.framework_key=p.framework_key;
DELETE FROM app.measure_frameworks mf USING app.framework_backfill_provenance p
 WHERE p.migration_key='0050_management_db_boundary_m1' AND p.entity_type='measure'
   AND p.relation_created_by_migration AND p.ownership_released_at IS NULL
   AND mf.tenant_id=p.tenant_id AND mf.measure_id=p.entity_id AND mf.framework_key=p.framework_key;
DELETE FROM app.framework_relation_origins WHERE origin_kind='migration' AND origin_id='0050_management_db_boundary_m1';
DELETE FROM app.framework_backfill_provenance WHERE migration_key='0050_management_db_boundary_m1';
-- The legacy rows are provenance introduced by M1 and must not survive its rollback.
DELETE FROM app.framework_relation_origins WHERE origin_kind='legacy' AND origin_id='pre-0050';
ALTER TABLE app.iso_framework_removal_requests DROP CONSTRAINT iso_framework_removal_requests_entity_type_check;
ALTER TABLE app.iso_framework_removal_requests ADD CONSTRAINT iso_framework_removal_requests_entity_type_check CHECK(entity_type IN ('asset','risk_scenario'));
ALTER TABLE app.framework_backfill_provenance DROP CONSTRAINT framework_backfill_provenance_entity_type_check;
ALTER TABLE app.framework_backfill_provenance ADD CONSTRAINT framework_backfill_provenance_entity_type_check CHECK (entity_type IN ('asset','risk_scenario'));
ALTER TABLE app.framework_relation_events DROP CONSTRAINT framework_relation_events_entity_type_check;
ALTER TABLE app.framework_relation_events ADD CONSTRAINT framework_relation_events_entity_type_check CHECK (entity_type IN ('asset','risk_scenario'));
ALTER TABLE app.framework_relation_origins DROP CONSTRAINT framework_relation_origins_entity_type_check;
ALTER TABLE app.framework_relation_origins ADD CONSTRAINT framework_relation_origins_entity_type_check CHECK (entity_type IN ('asset','risk_scenario'));
ALTER TABLE app.internal_management_audit_events
  DROP CONSTRAINT internal_management_audit_events_acceptance_evidence_check,
  DROP CONSTRAINT internal_management_audit_events_policy_version_fk,
  DROP CONSTRAINT internal_management_audit_events_approval_fk;
ALTER TABLE app.internal_management_operations
  DROP CONSTRAINT internal_management_operations_acceptance_evidence_check,
  DROP CONSTRAINT internal_management_operations_policy_version_fk,
  DROP CONSTRAINT internal_management_operations_approval_fk;
DROP TABLE app.internal_management_acceptance_approvals;
DROP TABLE app.internal_management_service_principals;
ALTER TABLE app.internal_management_operations
  DROP CONSTRAINT internal_management_operations_requester_fk,
  DROP CONSTRAINT internal_management_operations_actor_fk,
  DROP COLUMN policy_version_sha256,
  DROP COLUMN policy_version_id,
  DROP COLUMN approval_id,
  DROP COLUMN acceptance_expires_at,
  DROP COLUMN acceptance_reason,
  DROP COLUMN origin_kind,
  DROP COLUMN requester_actor_id,
  DROP COLUMN actor_id;
ALTER TABLE app.internal_management_audit_events
  DROP COLUMN policy_version_sha256,
  DROP COLUMN policy_version_id,
  DROP COLUMN approval_id,
  DROP COLUMN acceptance_expires_at,
  DROP COLUMN acceptance_reason,
  DROP COLUMN origin_kind;
REVOKE app_rw FROM management_web;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_roles
     WHERE rolname='management_web'
       AND shobj_description(oid,'pg_authid')='created-by:isms-platform-migration'
  ) THEN
    ALTER ROLE management_web NOLOGIN NOINHERIT;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION app.accept_risk_snapshot(
  p_risk uuid,p_evaluation uuid,p_evaluation_hash text,
  p_inherent uuid,p_inherent_hash text,p_reason text
) RETURNS uuid
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user(); residual app.risk_evaluation_snapshots%ROWTYPE; inherent app.risk_evaluation_snapshots%ROWTYPE; out_id uuid; v_version integer;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM app.memberships WHERE tenant_id=t AND user_id=u AND role_key='ciso' AND revoked_at IS NULL) THEN RAISE EXCEPTION 'executive role required' USING ERRCODE='insufficient_privilege'; END IF;
  SELECT * INTO residual FROM app.risk_evaluation_snapshots WHERE tenant_id=t AND id=p_evaluation AND risk_scenario_id=p_risk FOR KEY SHARE;
  SELECT * INTO inherent FROM app.risk_evaluation_snapshots WHERE tenant_id=t AND id=p_inherent AND risk_scenario_id=p_risk FOR KEY SHARE;
  IF NOT FOUND OR residual.id IS NULL OR inherent.id IS NULL OR residual.stage<>'after_measure' OR inherent.stage<>'inherent' THEN RAISE EXCEPTION 'risk snapshot unavailable'; END IF;
  IF app.risk_evaluation_snapshot_sha256(residual)<>p_evaluation_hash OR app.risk_evaluation_snapshot_sha256(inherent)<>p_inherent_hash THEN RAISE EXCEPTION 'risk snapshot hash mismatch'; END IF;
  IF residual.risk_level>inherent.risk_level THEN RAISE EXCEPTION 'residual exceeds inherent'; END IF;
  SELECT count(*)::integer INTO v_version FROM app.risk_evaluation_snapshots WHERE tenant_id=t AND risk_scenario_id=p_risk;
  INSERT INTO app.risk_acceptances(tenant_id,risk_scenario_id,expected_version,residual_level,inherent_level,reason,accepted_by,evaluation_snapshot_id,evaluation_snapshot_sha256,inherent_snapshot_id,inherent_snapshot_sha256)
  VALUES(t,p_risk,v_version,residual.risk_level,inherent.risk_level,p_reason,u,residual.id,p_evaluation_hash,inherent.id,p_inherent_hash) RETURNING id INTO out_id;
  RETURN out_id;
END $$;
ALTER FUNCTION app.accept_risk_snapshot(uuid,uuid,text,uuid,text,text) OWNER TO schema_owner;
CREATE OR REPLACE FUNCTION app.approve_policy_version(
  p_policy_version_id uuid, p_comment text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,app AS $$
DECLARE
  v_tenant uuid:=app.current_tenant(); v_user uuid:=app.current_session_user();
  v_body text; v_already_approved timestamptz;
BEGIN
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
DROP FUNCTION app.execute_iso_framework_removal_v2(uuid);
ALTER FUNCTION app.approve_iso_framework_removal(uuid) SECURITY INVOKER;
ALTER FUNCTION app.request_iso_framework_removal(text,uuid,uuid,bytea,bytea,text,text,timestamptz) SECURITY INVOKER;
DROP FUNCTION app.set_management_frameworks_v2(text,uuid,text[],text);
REVOKE ALL ON app.asset_frameworks,app.risk_scenario_frameworks,app.measure_frameworks,
  app.framework_relation_origins,app.framework_relation_events,app.framework_backfill_provenance,
  app.iso_framework_removal_requests,app.risk_acceptances,
  app.internal_management_operations,app.internal_management_audit_events FROM schema_owner;
GRANT INSERT,UPDATE,DELETE ON app.asset_frameworks,app.risk_scenario_frameworks,app.measure_frameworks,
  app.framework_relation_origins,app.framework_relation_events,app.framework_backfill_provenance,
  app.risk_acceptances,app.iso_framework_removal_requests,app.internal_management_operations,
  app.internal_management_audit_events TO app_rw;
GRANT INSERT,UPDATE,DELETE ON app.approvals TO app_rw;
GRANT EXECUTE ON FUNCTION app.accept_risk(uuid,integer,smallint,smallint,text) TO app_rw;
GRANT EXECUTE ON FUNCTION app.set_management_frameworks(text,uuid,text[]),app.execute_iso_framework_removal(uuid) TO app_rw;
GRANT EXECUTE ON FUNCTION app.accept_risk_snapshot(uuid,uuid,text,uuid,text,text) TO app_rw;
