-- @run-as: admin
-- 0046: Management / ISO views share one asset and risk register.
-- Backfill ownership is explicit so a rollback never removes a relation a user owns.
CREATE TABLE app.framework_relation_origins (
  tenant_id uuid NOT NULL, entity_type text NOT NULL CHECK (entity_type IN ('asset','risk_scenario')),
  entity_id uuid NOT NULL, framework_key text NOT NULL REFERENCES catalog.frameworks(key),
  generation_id uuid NOT NULL, origin_kind text NOT NULL CHECK (origin_kind IN ('legacy','human','service','migration')),
  origin_id text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, entity_type, entity_id, framework_key)
);
CREATE TABLE app.framework_relation_events (
  event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
  entity_type text NOT NULL CHECK (entity_type IN ('asset','risk_scenario')), entity_id uuid NOT NULL,
  framework_key text NOT NULL REFERENCES catalog.frameworks(key), generation_id uuid NOT NULL,
  event_kind text NOT NULL CHECK (event_kind IN ('created','deleted')), actor_id uuid, occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE app.framework_backfill_provenance (
  migration_key text NOT NULL, tenant_id uuid NOT NULL,
  entity_type text NOT NULL CHECK (entity_type IN ('asset','risk_scenario')), entity_id uuid NOT NULL,
  framework_key text NOT NULL REFERENCES catalog.frameworks(key), generation_id uuid NOT NULL,
  relation_existed_before boolean NOT NULL, relation_created_by_migration boolean NOT NULL,
  ownership_released_at timestamptz, recorded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (migration_key, tenant_id, entity_type, entity_id, framework_key)
);

-- Relations that predate this migration are evidence, never migration-owned.
INSERT INTO app.framework_relation_origins (tenant_id,entity_type,entity_id,framework_key,generation_id,origin_kind,origin_id)
SELECT tenant_id,'asset',asset_id,framework_key,gen_random_uuid(),'legacy','pre-0046' FROM app.asset_frameworks
ON CONFLICT (tenant_id,entity_type,entity_id,framework_key) DO NOTHING;
INSERT INTO app.framework_relation_origins (tenant_id,entity_type,entity_id,framework_key,generation_id,origin_kind,origin_id)
SELECT tenant_id,'risk_scenario',risk_scenario_id,framework_key,gen_random_uuid(),'legacy','pre-0046' FROM app.risk_scenario_frameworks
ON CONFLICT (tenant_id,entity_type,entity_id,framework_key) DO NOTHING;
INSERT INTO app.framework_relation_events (tenant_id,entity_type,entity_id,framework_key,generation_id,event_kind)
SELECT tenant_id,entity_type,entity_id,framework_key,generation_id,'created' FROM app.framework_relation_origins WHERE origin_kind='legacy';

-- Snapshot first, then only insert absent RISK-MANAGEMENT relations.  ISO tags are
-- deliberately not inferred here: only a reviewed service/user action may attach them.
WITH candidates AS (
  SELECT tenant_id, 'asset'::text entity_type, id entity_id FROM app.assets WHERE status = 'active'
  UNION ALL
  SELECT tenant_id, 'risk_scenario'::text, id FROM app.risk_scenarios WHERE status = 'active'
), snap AS (
  SELECT c.*, gen_random_uuid() generation_id,
         EXISTS (SELECT 1 FROM app.asset_frameworks af WHERE c.entity_type='asset' AND af.tenant_id=c.tenant_id AND af.asset_id=c.entity_id AND af.framework_key='RISK-MANAGEMENT')
         OR EXISTS (SELECT 1 FROM app.risk_scenario_frameworks rf WHERE c.entity_type='risk_scenario' AND rf.tenant_id=c.tenant_id AND rf.risk_scenario_id=c.entity_id AND rf.framework_key='RISK-MANAGEMENT') existed
  FROM candidates c
), provenance AS (
  INSERT INTO app.framework_backfill_provenance (migration_key,tenant_id,entity_type,entity_id,framework_key,generation_id,relation_existed_before,relation_created_by_migration)
  SELECT '0046_management_framework_provenance',tenant_id,entity_type,entity_id,'RISK-MANAGEMENT',generation_id,existed,false FROM snap
  ON CONFLICT DO NOTHING RETURNING tenant_id,entity_type,entity_id,generation_id
), inserted_assets AS (
  INSERT INTO app.asset_frameworks (tenant_id,asset_id,framework_key)
  SELECT s.tenant_id,s.entity_id,'RISK-MANAGEMENT' FROM snap s JOIN provenance p USING (tenant_id,entity_type,entity_id,generation_id)
   WHERE s.entity_type='asset' AND NOT s.existed ON CONFLICT DO NOTHING RETURNING tenant_id,asset_id
), inserted_risks AS (
  INSERT INTO app.risk_scenario_frameworks (tenant_id,risk_scenario_id,framework_key)
  SELECT s.tenant_id,s.entity_id,'RISK-MANAGEMENT' FROM snap s JOIN provenance p USING (tenant_id,entity_type,entity_id,generation_id)
   WHERE s.entity_type='risk_scenario' AND NOT s.existed ON CONFLICT DO NOTHING RETURNING tenant_id,risk_scenario_id
), created AS (
  SELECT p.tenant_id,'asset'::text entity_type,a.asset_id entity_id,p.generation_id FROM inserted_assets a JOIN provenance p ON p.tenant_id=a.tenant_id AND p.entity_type='asset' AND p.entity_id=a.asset_id
  UNION ALL SELECT p.tenant_id,'risk_scenario',r.risk_scenario_id,p.generation_id FROM inserted_risks r JOIN provenance p ON p.tenant_id=r.tenant_id AND p.entity_type='risk_scenario' AND p.entity_id=r.risk_scenario_id
), origins AS (
  INSERT INTO app.framework_relation_origins (tenant_id,entity_type,entity_id,framework_key,generation_id,origin_kind,origin_id)
  SELECT tenant_id,entity_type,entity_id,'RISK-MANAGEMENT',generation_id,'migration','0046_management_framework_provenance' FROM created
  ON CONFLICT DO NOTHING RETURNING tenant_id,entity_type,entity_id,generation_id
)
INSERT INTO app.framework_relation_events (tenant_id,entity_type,entity_id,framework_key,generation_id,event_kind)
SELECT tenant_id,entity_type,entity_id,'RISK-MANAGEMENT',generation_id,'created' FROM origins;

UPDATE app.framework_backfill_provenance p SET relation_created_by_migration=true
 WHERE migration_key='0046_management_framework_provenance'
    AND EXISTS (SELECT 1 FROM app.framework_relation_origins o WHERE o.tenant_id=p.tenant_id AND o.entity_type=p.entity_type AND o.entity_id=p.entity_id AND o.framework_key=p.framework_key AND o.generation_id=p.generation_id AND o.origin_kind='migration');

-- Acceptance and ISO removal are append-only, tenant-scoped approvals.  The only
-- executive role in the existing immutable membership catalog is ciso.
CREATE TABLE app.risk_acceptances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, risk_scenario_id uuid NOT NULL,
  expected_version integer NOT NULL, residual_level smallint NOT NULL, inherent_level smallint NOT NULL,
  reason text NOT NULL CHECK (length(btrim(reason)) > 0), accepted_by uuid NOT NULL, accepted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id,risk_scenario_id,expected_version), FOREIGN KEY (tenant_id,risk_scenario_id) REFERENCES app.risk_scenarios(tenant_id,id),
  FOREIGN KEY (tenant_id,accepted_by) REFERENCES app.users(tenant_id,id), CHECK (residual_level <= inherent_level)
);
CREATE TABLE app.iso_framework_removal_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, entity_type text NOT NULL CHECK(entity_type IN ('asset','risk_scenario')), entity_id uuid NOT NULL,
  expected_generation_id uuid NOT NULL, before_hash bytea NOT NULL, after_hash bytea NOT NULL, reason text NOT NULL CHECK(length(btrim(reason))>0),
  alternate_control text NOT NULL CHECK(length(btrim(alternate_control))>0), expires_at timestamptz NOT NULL, requested_by uuid NOT NULL, approved_by uuid, approved_at timestamptz,
  status text NOT NULL DEFAULT 'requested' CHECK(status IN ('requested','approved','executed','rejected','expired')),
  UNIQUE(tenant_id,entity_type,entity_id,expected_generation_id), FOREIGN KEY(tenant_id,requested_by) REFERENCES app.users(tenant_id,id), FOREIGN KEY(tenant_id,approved_by) REFERENCES app.users(tenant_id,id),
  CHECK(expires_at > now() OR status IN ('expired','rejected'))
);
CREATE OR REPLACE FUNCTION app.accept_risk(p_risk uuid,p_expected_version integer,p_residual smallint,p_inherent smallint,p_reason text) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$ DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user(); out_id uuid; v_version integer; BEGIN
  IF NOT EXISTS(SELECT 1 FROM app.memberships WHERE tenant_id=t AND user_id=u AND role_key='ciso' AND revoked_at IS NULL) THEN RAISE EXCEPTION 'executive role required' USING ERRCODE='insufficient_privilege'; END IF;
  IF p_residual > p_inherent THEN RAISE EXCEPTION 'residual exceeds inherent'; END IF;
  SELECT count(*)::integer INTO v_version FROM app.risk_evaluation_snapshots WHERE tenant_id=t AND risk_scenario_id=p_risk;
  IF v_version <> p_expected_version THEN RAISE EXCEPTION 'risk acceptance version conflict'; END IF;
  INSERT INTO app.risk_acceptances(tenant_id,risk_scenario_id,expected_version,residual_level,inherent_level,reason,accepted_by) VALUES(t,p_risk,p_expected_version,p_residual,p_inherent,p_reason,u) RETURNING id INTO out_id; RETURN out_id;
END $$;
ALTER FUNCTION app.accept_risk(uuid,integer,smallint,smallint,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.accept_risk(uuid,integer,smallint,smallint,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.accept_risk(uuid,integer,smallint,smallint,text) TO app_rw;
CREATE OR REPLACE FUNCTION app.request_iso_framework_removal(p_entity_type text,p_entity uuid,p_generation uuid,p_before bytea,p_after bytea,p_reason text,p_alternate text,p_expires timestamptz) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$ DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user(); x uuid; actual bytea; expected_after bytea; BEGIN
 IF p_expires<=now() THEN RAISE EXCEPTION 'expiry required'; END IF;
 IF NOT EXISTS(SELECT 1 FROM app.framework_relation_origins WHERE tenant_id=t AND entity_type=p_entity_type AND entity_id=p_entity AND framework_key='ISO27001:2022' AND generation_id=p_generation) THEN RAISE EXCEPTION 'framework generation conflict'; END IF;
 SELECT public.digest(convert_to(p_entity_type||':'||p_entity::text||':ISO27001:2022:'||p_generation::text,'UTF8'),'sha256') INTO actual;
 IF p_before IS DISTINCT FROM actual THEN RAISE EXCEPTION 'framework snapshot hash mismatch'; END IF;
 SELECT public.digest(convert_to(p_entity_type||':'||p_entity::text||':WITHOUT:ISO27001:2022:'||p_generation::text,'UTF8'),'sha256') INTO expected_after;
 IF p_after IS DISTINCT FROM expected_after OR p_after=p_before THEN RAISE EXCEPTION 'framework after hash mismatch'; END IF;
 INSERT INTO app.iso_framework_removal_requests(tenant_id,entity_type,entity_id,expected_generation_id,before_hash,after_hash,reason,alternate_control,expires_at,requested_by) VALUES(t,p_entity_type,p_entity,p_generation,p_before,p_after,p_reason,p_alternate,p_expires,u) RETURNING id INTO x; RETURN x;
END $$;

CREATE OR REPLACE FUNCTION app.approve_iso_framework_removal(p_request uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$ DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user(); r app.iso_framework_removal_requests%ROWTYPE; BEGIN
 IF NOT EXISTS(SELECT 1 FROM app.memberships WHERE tenant_id=t AND user_id=u AND role_key='ciso' AND revoked_at IS NULL) THEN RAISE EXCEPTION 'executive role required' USING ERRCODE='insufficient_privilege'; END IF;
 SELECT * INTO r FROM app.iso_framework_removal_requests WHERE tenant_id=t AND id=p_request FOR UPDATE;
 IF NOT FOUND OR r.status<>'requested' OR r.expires_at<=now() THEN RAISE EXCEPTION 'removal request unavailable'; END IF;
 IF r.requested_by=u THEN RAISE EXCEPTION 'self approval prohibited' USING ERRCODE='insufficient_privilege'; END IF;
 UPDATE app.iso_framework_removal_requests SET status='approved',approved_by=u,approved_at=now() WHERE tenant_id=t AND id=p_request;
END $$;
CREATE OR REPLACE FUNCTION app.execute_iso_framework_removal(p_request uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$ DECLARE t uuid:=app.current_tenant(); r app.iso_framework_removal_requests%ROWTYPE; BEGIN
 SELECT * INTO r FROM app.iso_framework_removal_requests WHERE tenant_id=t AND id=p_request FOR UPDATE;
 IF NOT FOUND OR r.status<>'approved' OR r.expires_at<=now() THEN RAISE EXCEPTION 'removal request unavailable'; END IF;
 IF NOT EXISTS(SELECT 1 FROM app.framework_relation_origins o WHERE o.tenant_id=t AND o.entity_type=r.entity_type AND o.entity_id=r.entity_id AND o.framework_key='ISO27001:2022' AND o.generation_id=r.expected_generation_id) THEN RAISE EXCEPTION 'framework generation conflict'; END IF;
 IF r.entity_type='asset' THEN DELETE FROM app.asset_frameworks WHERE tenant_id=t AND asset_id=r.entity_id AND framework_key='ISO27001:2022'; ELSE DELETE FROM app.risk_scenario_frameworks WHERE tenant_id=t AND risk_scenario_id=r.entity_id AND framework_key='ISO27001:2022'; END IF;
 DELETE FROM app.framework_relation_origins WHERE tenant_id=t AND entity_type=r.entity_type AND entity_id=r.entity_id AND framework_key='ISO27001:2022' AND generation_id=r.expected_generation_id;
 INSERT INTO app.framework_relation_events(tenant_id,entity_type,entity_id,framework_key,generation_id,event_kind,actor_id) VALUES(t,r.entity_type,r.entity_id,'ISO27001:2022',r.expected_generation_id,'deleted',app.current_session_user());
 UPDATE app.iso_framework_removal_requests SET status='executed' WHERE tenant_id=t AND id=p_request;
END $$;
ALTER FUNCTION app.approve_iso_framework_removal(uuid) OWNER TO schema_owner; ALTER FUNCTION app.execute_iso_framework_removal(uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.request_iso_framework_removal(text,uuid,uuid,bytea,bytea,text,text,timestamptz),app.approve_iso_framework_removal(uuid),app.execute_iso_framework_removal(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.request_iso_framework_removal(text,uuid,uuid,bytea,bytea,text,text,timestamptz),app.approve_iso_framework_removal(uuid),app.execute_iso_framework_removal(uuid) TO app_rw;
CREATE OR REPLACE FUNCTION app.set_management_frameworks(p_entity_type text,p_entity uuid,p_keys text[]) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
DECLARE
 t uuid:=app.current_tenant(); u uuid:=app.current_session_user(); k text; g uuid; old app.framework_relation_origins%ROWTYPE;
BEGIN
 IF p_entity_type NOT IN ('asset','risk_scenario') OR NOT 'RISK-MANAGEMENT'=ANY(p_keys) THEN RAISE EXCEPTION 'management framework required'; END IF;
 IF p_entity_type='asset' AND EXISTS(SELECT 1 FROM app.asset_frameworks WHERE tenant_id=t AND asset_id=p_entity AND framework_key='ISO27001:2022' AND NOT ('ISO27001:2022'=ANY(p_keys))) THEN RAISE EXCEPTION 'ISO removal requires approval'; END IF;
 IF p_entity_type='risk_scenario' AND EXISTS(SELECT 1 FROM app.risk_scenario_frameworks WHERE tenant_id=t AND risk_scenario_id=p_entity AND framework_key='ISO27001:2022' AND NOT ('ISO27001:2022'=ANY(p_keys))) THEN RAISE EXCEPTION 'ISO removal requires approval'; END IF;
 FOR old IN SELECT * FROM app.framework_relation_origins
   WHERE tenant_id=t AND entity_type=p_entity_type AND entity_id=p_entity AND NOT (framework_key=ANY(p_keys))
 LOOP
   IF old.origin_kind='migration' THEN
     UPDATE app.framework_backfill_provenance SET ownership_released_at=now()
      WHERE migration_key=old.origin_id AND tenant_id=t AND entity_type=p_entity_type
        AND entity_id=p_entity AND framework_key=old.framework_key AND generation_id=old.generation_id;
   END IF;
   INSERT INTO app.framework_relation_events(tenant_id,entity_type,entity_id,framework_key,generation_id,event_kind,actor_id)
     VALUES(t,p_entity_type,p_entity,old.framework_key,old.generation_id,'deleted',u);
   DELETE FROM app.framework_relation_origins WHERE tenant_id=t AND entity_type=p_entity_type AND entity_id=p_entity AND framework_key=old.framework_key;
   IF p_entity_type='asset' THEN DELETE FROM app.asset_frameworks WHERE tenant_id=t AND asset_id=p_entity AND framework_key=old.framework_key;
   ELSE DELETE FROM app.risk_scenario_frameworks WHERE tenant_id=t AND risk_scenario_id=p_entity AND framework_key=old.framework_key; END IF;
 END LOOP;
 FOREACH k IN ARRAY p_keys LOOP
   g:=gen_random_uuid();
   IF p_entity_type='asset' THEN INSERT INTO app.asset_frameworks VALUES(t,p_entity,k) ON CONFLICT DO NOTHING;
   ELSE INSERT INTO app.risk_scenario_frameworks VALUES(t,p_entity,k) ON CONFLICT DO NOTHING; END IF;
   IF FOUND THEN
     INSERT INTO app.framework_relation_origins VALUES(t,p_entity_type,p_entity,k,g,'service','0046');
     INSERT INTO app.framework_relation_events(tenant_id,entity_type,entity_id,framework_key,generation_id,event_kind,actor_id)
       VALUES(t,p_entity_type,p_entity,k,g,'created',u);
   END IF;
 END LOOP;
END
$$;
ALTER FUNCTION app.set_management_frameworks(text,uuid,text[]) OWNER TO schema_owner; REVOKE ALL ON FUNCTION app.set_management_frameworks(text,uuid,text[]) FROM PUBLIC; GRANT EXECUTE ON FUNCTION app.set_management_frameworks(text,uuid,text[]) TO app_rw;

DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['framework_relation_origins','framework_relation_events','framework_backfill_provenance','risk_acceptances','iso_framework_removal_requests'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t); EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t); EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO app_rw',t); EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
  END LOOP;
END $$;
