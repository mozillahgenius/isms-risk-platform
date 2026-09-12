-- @run-as: admin
-- M3: expiry-aware acceptance reads, operational deviations, and measure history.

ALTER TABLE app.risk_acceptances ADD COLUMN expires_at timestamptz;
ALTER TABLE app.risk_acceptances
  ALTER COLUMN expires_at SET DEFAULT (now() + interval '365 days');

CREATE FUNCTION app.require_future_risk_acceptance_expiry() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF NEW.expires_at IS NULL OR NEW.expires_at <= now() THEN
    RAISE EXCEPTION 'risk acceptance expiry must be in the future';
  END IF;
  RETURN NEW;
END $$;
ALTER FUNCTION app.require_future_risk_acceptance_expiry() OWNER TO schema_owner;
CREATE TRIGGER risk_acceptances_future_expiry
  BEFORE INSERT ON app.risk_acceptances
  FOR EACH ROW EXECUTE FUNCTION app.require_future_risk_acceptance_expiry();

CREATE VIEW app.risk_acceptance_status WITH (security_invoker = true) AS
SELECT a.*,
       CASE WHEN a.expires_at IS NULL THEN 'legacy_unknown'
            WHEN a.expires_at <= now() THEN 'expired'
            ELSE 'current' END AS expiry_status
  FROM app.risk_acceptances a;
ALTER VIEW app.risk_acceptance_status OWNER TO schema_owner;
GRANT SELECT ON app.risk_acceptance_status TO app_rw, app_ro;

CREATE FUNCTION app.accept_risk_snapshot_with_expiry(
  p_risk uuid,p_evaluation uuid,p_evaluation_hash text,p_inherent uuid,
  p_inherent_hash text,p_reason text,p_expires_at timestamptz
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user();
        residual app.risk_evaluation_snapshots%ROWTYPE;
        inherent app.risk_evaluation_snapshots%ROWTYPE; out_id uuid; v_version integer;
BEGIN
  IF p_expires_at IS NULL OR p_expires_at <= now() THEN RAISE EXCEPTION 'risk acceptance expiry must be in the future'; END IF;
  IF NOT EXISTS (SELECT 1 FROM app.memberships m JOIN app.users usr ON usr.tenant_id=m.tenant_id AND usr.id=m.user_id
                 WHERE m.tenant_id=t AND m.user_id=u AND m.role_key='ciso' AND m.revoked_at IS NULL AND usr.status='active') THEN
    RAISE EXCEPTION 'executive role required' USING ERRCODE='insufficient_privilege';
  END IF;
  LOCK TABLE app.risk_evaluation_snapshots IN SHARE MODE;
  SELECT * INTO residual FROM app.risk_evaluation_snapshots WHERE tenant_id=t AND risk_scenario_id=p_risk
    AND stage='after_measure' AND assessed_on<=(now() AT TIME ZONE 'Asia/Tokyo')::date ORDER BY assessed_on DESC,created_at DESC,id DESC LIMIT 1;
  SELECT * INTO inherent FROM app.risk_evaluation_snapshots WHERE tenant_id=t AND risk_scenario_id=p_risk
    AND stage='inherent' AND assessed_on=residual.assessed_on ORDER BY created_at DESC,id DESC LIMIT 1;
  IF residual.id IS NULL OR inherent.id IS NULL OR residual.id<>p_evaluation OR inherent.id<>p_inherent
     OR app.risk_evaluation_snapshot_sha256(residual)<>p_evaluation_hash
     OR app.risk_evaluation_snapshot_sha256(inherent)<>p_inherent_hash OR residual.risk_level>inherent.risk_level THEN
    RAISE EXCEPTION 'stale or invalid risk snapshot evidence';
  END IF;
  SELECT count(*)::integer INTO v_version FROM app.risk_evaluation_snapshots WHERE tenant_id=t AND risk_scenario_id=p_risk;
  INSERT INTO app.risk_acceptances(tenant_id,risk_scenario_id,expected_version,residual_level,inherent_level,reason,accepted_by,evaluation_snapshot_id,evaluation_snapshot_sha256,inherent_snapshot_id,inherent_snapshot_sha256,expires_at)
  VALUES(t,p_risk,v_version,residual.risk_level,inherent.risk_level,p_reason,u,residual.id,p_evaluation_hash,inherent.id,p_inherent_hash,p_expires_at)
  RETURNING id INTO out_id;
  RETURN out_id;
END $$;
ALTER FUNCTION app.accept_risk_snapshot_with_expiry(uuid,uuid,text,uuid,text,text,timestamptz) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.accept_risk_snapshot_with_expiry(uuid,uuid,text,uuid,text,text,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.accept_risk_snapshot_with_expiry(uuid,uuid,text,uuid,text,text,timestamptz) TO app_rw;

CREATE FUNCTION app.accept_risk_snapshot_human_evidenced(
  p_operation_id text,p_request_sha256 text,p_risk uuid,p_evaluation uuid,
  p_evaluation_hash text,p_inherent uuid,p_inherent_hash text,p_reason text,
  p_expires_at timestamptz,p_policy_version_id uuid,p_policy_version_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE
  t uuid:=app.current_tenant(); u uuid:=app.current_session_user();
  approval_id uuid; acceptance_id uuid; audit_id uuid; receipt jsonb;
  old_hash text; old_action text; old_actor uuid; old_origin text;
  old_policy uuid; old_policy_hash text; old_reason text; old_expires timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_operation_id,0));
  SELECT o.receipt,o.request_sha256,o.action,o.actor_id,o.origin_kind,
         o.policy_version_id,o.policy_version_sha256,o.acceptance_reason,o.acceptance_expires_at
    INTO receipt,old_hash,old_action,old_actor,old_origin,
         old_policy,old_policy_hash,old_reason,old_expires
    FROM app.internal_management_operations o
   WHERE o.tenant_id=t AND o.operation_id=p_operation_id;
  IF FOUND THEN
    IF old_hash<>p_request_sha256 OR old_action<>'accept_risk'
       OR old_actor<>u OR old_origin<>'human'
       OR old_policy<>p_policy_version_id OR old_policy_hash<>p_policy_version_hash
       OR old_reason<>p_reason OR old_expires<>p_expires_at THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN receipt;
  END IF;
  approval_id:=app.approve_internal_risk_acceptance(
    p_operation_id,p_risk,p_evaluation,p_evaluation_hash,p_inherent,
    p_inherent_hash,p_policy_version_id,p_policy_version_hash,p_reason,p_expires_at);
  acceptance_id:=app.accept_risk_snapshot_with_expiry(
    p_risk,p_evaluation,p_evaluation_hash,p_inherent,p_inherent_hash,p_reason,p_expires_at);
  INSERT INTO app.internal_management_audit_events(
    tenant_id,operation_id,action,actor_id,requester_actor_id,risk_scenario_id,
    evaluation_snapshot_id,evaluation_snapshot_sha256,inherent_snapshot_id,
    inherent_snapshot_sha256,origin_kind,approval_id,policy_version_id,
    policy_version_sha256,acceptance_reason,acceptance_expires_at
  ) VALUES (
    t,p_operation_id,'accept_risk',u,u,p_risk,p_evaluation,p_evaluation_hash,
    p_inherent,p_inherent_hash,'human',approval_id,p_policy_version_id,
    p_policy_version_hash,p_reason,p_expires_at
  ) RETURNING id INTO audit_id;
  receipt:=jsonb_build_object(
    'risk_id',p_risk,'acceptance_id',acceptance_id,'audit_event_id',audit_id);
  INSERT INTO app.internal_management_operations(
    tenant_id,operation_id,action,request_sha256,receipt,actor_id,
    requester_actor_id,origin_kind,approval_id,policy_version_id,
    policy_version_sha256,acceptance_reason,acceptance_expires_at
  ) VALUES (
    t,p_operation_id,'accept_risk',p_request_sha256,receipt,u,u,'human',
    approval_id,p_policy_version_id,p_policy_version_hash,p_reason,p_expires_at);
  RETURN receipt;
END $$;
ALTER FUNCTION app.accept_risk_snapshot_human_evidenced(text,text,uuid,uuid,text,uuid,text,text,timestamptz,uuid,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.accept_risk_snapshot_human_evidenced(text,text,uuid,uuid,text,uuid,text,text,timestamptz,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.accept_risk_snapshot_human_evidenced(text,text,uuid,uuid,text,uuid,text,text,timestamptz,uuid,text) TO app_rw;
REVOKE EXECUTE ON FUNCTION app.accept_risk_snapshot_with_expiry(uuid,uuid,text,uuid,text,text,timestamptz) FROM app_rw;

CREATE TABLE app.management_deviations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  title text NOT NULL CHECK (length(btrim(title)) > 0),
  description text NOT NULL CHECK (length(btrim(description)) > 0),
  corrective_action text NOT NULL CHECK (length(btrim(corrective_action)) > 0),
  owner_user_id uuid NOT NULL,
  requested_by uuid NOT NULL,
  requested_at timestamptz NOT NULL DEFAULT now(),
  approved_by uuid,
  approved_at timestamptz,
  due_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  closed_by uuid,
  closed_at timestamptz,
  close_note text,
  status text NOT NULL DEFAULT 'requested'
    CHECK (status IN ('requested','open','closed','expired','rejected')),
  operation_id text NOT NULL CHECK (operation_id ~ '^[a-f0-9]{12,64}$'),
  request_sha256 text NOT NULL CHECK (request_sha256 ~ '^[a-f0-9]{64}$'),
  UNIQUE (tenant_id, operation_id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id,id),
  FOREIGN KEY (tenant_id, requested_by) REFERENCES app.users(tenant_id,id),
  FOREIGN KEY (tenant_id, approved_by) REFERENCES app.users(tenant_id,id),
  FOREIGN KEY (tenant_id, closed_by) REFERENCES app.users(tenant_id,id),
  CHECK (due_at > requested_at AND expires_at >= due_at),
  CHECK ((status = 'requested' AND approved_by IS NULL AND approved_at IS NULL AND closed_at IS NULL)
      OR (status = 'open' AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND closed_at IS NULL)
      OR (status = 'expired' AND closed_at IS NULL)
      OR (status = 'closed' AND approved_by IS NOT NULL AND approved_at IS NOT NULL
          AND closed_by IS NOT NULL AND closed_at IS NOT NULL AND length(btrim(coalesce(close_note,''))) > 0)
      OR status = 'rejected')
);
CREATE INDEX management_deviations_open ON app.management_deviations (tenant_id, status, due_at)
  WHERE status IN ('requested','open');

CREATE TABLE app.management_deviation_risks (
  tenant_id uuid NOT NULL, deviation_id uuid NOT NULL, risk_scenario_id uuid NOT NULL,
  PRIMARY KEY (tenant_id,deviation_id,risk_scenario_id),
  FOREIGN KEY (tenant_id,deviation_id) REFERENCES app.management_deviations(tenant_id,id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id,risk_scenario_id) REFERENCES app.risk_scenarios(tenant_id,id)
);
CREATE TABLE app.management_deviation_controls (
  tenant_id uuid NOT NULL, deviation_id uuid NOT NULL, control_id uuid NOT NULL,
  PRIMARY KEY (tenant_id,deviation_id,control_id),
  FOREIGN KEY (tenant_id,deviation_id) REFERENCES app.management_deviations(tenant_id,id) ON DELETE CASCADE,
  FOREIGN KEY (control_id) REFERENCES catalog.controls(id)
);
CREATE TABLE app.management_deviation_evidence (
  tenant_id uuid NOT NULL, deviation_id uuid NOT NULL, evidence_id uuid NOT NULL,
  PRIMARY KEY (tenant_id,deviation_id,evidence_id),
  FOREIGN KEY (tenant_id,deviation_id) REFERENCES app.management_deviations(tenant_id,id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id,evidence_id) REFERENCES app.evidences(tenant_id,id)
);

-- Each lifecycle transition has its own durable receipt. A retry must return
-- the original result instead of re-running a transition against new state.
CREATE TABLE app.management_deviation_operation_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL, deviation_id uuid NOT NULL,
  action text NOT NULL CHECK (action IN ('request','approve','close')),
  operation_id text NOT NULL CHECK (operation_id ~ '^[a-f0-9]{12,64}$'),
  request_sha256 text NOT NULL CHECK (request_sha256 ~ '^[a-f0-9]{64}$'),
  actor_id uuid NOT NULL,
  receipt jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, operation_id),
  FOREIGN KEY (tenant_id,deviation_id) REFERENCES app.management_deviations(tenant_id,id),
  FOREIGN KEY (tenant_id,actor_id) REFERENCES app.users(tenant_id,id)
);

CREATE TABLE app.measure_change_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, measure_id uuid NOT NULL,
  actor_id uuid NOT NULL, changed_at timestamptz NOT NULL DEFAULT now(),
  before_row jsonb NOT NULL, after_row jsonb NOT NULL,
  FOREIGN KEY (tenant_id,measure_id) REFERENCES app.measures(tenant_id,id),
  FOREIGN KEY (tenant_id,actor_id) REFERENCES app.users(tenant_id,id)
);
CREATE INDEX measure_change_history_timeline ON app.measure_change_history (tenant_id, measure_id, changed_at);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'management_deviations','management_deviation_risks','management_deviation_controls',
    'management_deviation_evidence','management_deviation_operation_receipts','measure_change_history'
  ] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY management_definer_access ON app.%I FOR ALL TO schema_owner USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_rw,app_ro',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO schema_owner',t);
  END LOOP;
END $$;

CREATE FUNCTION app.record_measure_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
BEGIN
  INSERT INTO app.measure_change_history(tenant_id,measure_id,actor_id,before_row,after_row)
  VALUES (NEW.tenant_id,NEW.id,app.current_session_user(),to_jsonb(OLD),to_jsonb(NEW));
  RETURN NEW;
END $$;
ALTER FUNCTION app.record_measure_change() OWNER TO schema_owner;
CREATE TRIGGER measures_record_change
  AFTER UPDATE ON app.measures FOR EACH ROW EXECUTE FUNCTION app.record_measure_change();
CREATE TRIGGER measure_change_history_immutable
  BEFORE UPDATE OR DELETE ON app.measure_change_history
  FOR EACH ROW EXECUTE FUNCTION app.reject_immutable_management_evidence();
CREATE TRIGGER management_deviation_operation_receipts_immutable
  BEFORE UPDATE OR DELETE ON app.management_deviation_operation_receipts
  FOR EACH ROW EXECUTE FUNCTION app.reject_immutable_management_evidence();

CREATE FUNCTION app.request_management_deviation(
  p_operation_id text,p_request_sha256 text,p_title text,p_description text,
  p_corrective_action text,p_owner uuid,p_due_at timestamptz,p_expires_at timestamptz,
  p_risk_ids uuid[] DEFAULT ARRAY[]::uuid[],p_control_ids uuid[] DEFAULT ARRAY[]::uuid[],
  p_evidence_ids uuid[] DEFAULT ARRAY[]::uuid[]
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user(); out_id uuid;
        receipt jsonb; existing_hash text; existing_action text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM app.memberships m JOIN app.users usr ON usr.tenant_id=m.tenant_id AND usr.id=m.user_id
                 WHERE m.tenant_id=t AND m.user_id=u AND m.role_key IN ('secretariat','risk_owner')
                   AND m.revoked_at IS NULL AND usr.status='active') THEN
    RAISE EXCEPTION 'deviation requester role required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app.memberships m JOIN app.users usr ON usr.tenant_id=m.tenant_id AND usr.id=m.user_id
                 WHERE m.tenant_id=t AND m.user_id=p_owner AND m.role_key='risk_owner'
                   AND m.revoked_at IS NULL AND usr.status='active') THEN
    RAISE EXCEPTION 'deviation owner must be an active risk owner' USING ERRCODE='insufficient_privilege';
  END IF;
  IF p_due_at <= now() OR p_expires_at < p_due_at THEN RAISE EXCEPTION 'future due and expiry required'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_operation_id,0));
  SELECT o.receipt,o.request_sha256,o.action INTO receipt,existing_hash,existing_action
    FROM app.management_deviation_operation_receipts o WHERE o.tenant_id=t AND o.operation_id=p_operation_id;
  IF FOUND THEN
    IF existing_hash <> p_request_sha256 OR existing_action <> 'request'
       OR (SELECT actor_id FROM app.management_deviation_operation_receipts WHERE tenant_id=t AND operation_id=p_operation_id) <> u THEN RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT'; END IF;
    RETURN receipt;
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(coalesce(p_risk_ids,ARRAY[]::uuid[])) x
             WHERE NOT EXISTS (SELECT 1 FROM app.risk_scenarios r WHERE r.tenant_id=t AND r.id=x))
     OR EXISTS (SELECT 1 FROM unnest(coalesce(p_evidence_ids,ARRAY[]::uuid[])) x
             WHERE NOT EXISTS (SELECT 1 FROM app.evidences e WHERE e.tenant_id=t AND e.id=x)) THEN
    RAISE EXCEPTION 'deviation link is outside tenant';
  END IF;
  INSERT INTO app.management_deviations(tenant_id,title,description,corrective_action,owner_user_id,requested_by,due_at,expires_at,operation_id,request_sha256)
  VALUES(t,p_title,p_description,p_corrective_action,p_owner,u,p_due_at,p_expires_at,p_operation_id,p_request_sha256)
  RETURNING id INTO out_id;
  INSERT INTO app.management_deviation_risks SELECT t,out_id,x FROM unnest(coalesce(p_risk_ids,ARRAY[]::uuid[])) x;
  INSERT INTO app.management_deviation_controls SELECT t,out_id,x FROM unnest(coalesce(p_control_ids,ARRAY[]::uuid[])) x;
  INSERT INTO app.management_deviation_evidence SELECT t,out_id,x FROM unnest(coalesce(p_evidence_ids,ARRAY[]::uuid[])) x;
  receipt:=jsonb_build_object('deviation_id',out_id,'status','requested');
  INSERT INTO app.management_deviation_operation_receipts(tenant_id,deviation_id,action,operation_id,request_sha256,actor_id,receipt)
  VALUES(t,out_id,'request',p_operation_id,p_request_sha256,u,receipt);
  RETURN receipt;
END $$;

CREATE FUNCTION app.approve_management_deviation(p_deviation uuid,p_operation_id text,p_request_sha256 text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user(); d app.management_deviations%ROWTYPE;
        receipt jsonb; existing_hash text; existing_action text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM app.memberships m JOIN app.users usr ON usr.tenant_id=m.tenant_id AND usr.id=m.user_id
                 WHERE m.tenant_id=t AND m.user_id=u AND m.role_key='ciso'
                   AND m.revoked_at IS NULL AND usr.status='active') THEN
    RAISE EXCEPTION 'executive role required' USING ERRCODE='insufficient_privilege';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_operation_id,0));
  SELECT o.receipt,o.request_sha256,o.action INTO receipt,existing_hash,existing_action
    FROM app.management_deviation_operation_receipts o WHERE o.tenant_id=t AND o.operation_id=p_operation_id;
  IF FOUND THEN
    IF existing_hash <> p_request_sha256 OR existing_action <> 'approve'
       OR (SELECT actor_id FROM app.management_deviation_operation_receipts WHERE tenant_id=t AND operation_id=p_operation_id) <> u THEN RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT'; END IF;
    RETURN receipt;
  END IF;
  SELECT * INTO d FROM app.management_deviations WHERE tenant_id=t AND id=p_deviation FOR UPDATE;
  IF NOT FOUND OR d.status <> 'requested' OR d.expires_at <= now() THEN RAISE EXCEPTION 'deviation unavailable'; END IF;
  IF d.requested_by = u THEN RAISE EXCEPTION 'self approval prohibited' USING ERRCODE='insufficient_privilege'; END IF;
  UPDATE app.management_deviations SET status='open',approved_by=u,approved_at=now() WHERE tenant_id=t AND id=p_deviation;
  receipt:=jsonb_build_object('deviation_id',p_deviation,'status','open');
  INSERT INTO app.management_deviation_operation_receipts(tenant_id,deviation_id,action,operation_id,request_sha256,actor_id,receipt)
  VALUES(t,p_deviation,'approve',p_operation_id,p_request_sha256,u,receipt);
  RETURN receipt;
END $$;

CREATE FUNCTION app.close_management_deviation(p_deviation uuid,p_close_note text,p_operation_id text,p_request_sha256 text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE t uuid:=app.current_tenant(); u uuid:=app.current_session_user(); d app.management_deviations%ROWTYPE;
        receipt jsonb; existing_hash text; existing_action text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_operation_id,0));
  SELECT o.receipt,o.request_sha256,o.action INTO receipt,existing_hash,existing_action
    FROM app.management_deviation_operation_receipts o WHERE o.tenant_id=t AND o.operation_id=p_operation_id;
  IF FOUND THEN
    IF existing_hash <> p_request_sha256 OR existing_action <> 'close'
       OR (SELECT actor_id FROM app.management_deviation_operation_receipts WHERE tenant_id=t AND operation_id=p_operation_id) <> u THEN RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT'; END IF;
    RETURN receipt;
  END IF;
  SELECT * INTO d FROM app.management_deviations WHERE tenant_id=t AND id=p_deviation FOR UPDATE;
  IF NOT FOUND OR d.status <> 'open' OR d.expires_at <= now() THEN RAISE EXCEPTION 'deviation unavailable'; END IF;
  IF length(btrim(coalesce(p_close_note,'')))=0 THEN RAISE EXCEPTION 'close note required'; END IF;
  IF u <> d.owner_user_id AND NOT EXISTS (SELECT 1 FROM app.memberships m JOIN app.users usr ON usr.tenant_id=m.tenant_id AND usr.id=m.user_id
                 WHERE m.tenant_id=t AND m.user_id=u AND m.role_key='ciso'
                   AND m.revoked_at IS NULL AND usr.status='active') THEN
    RAISE EXCEPTION 'deviation owner or executive required' USING ERRCODE='insufficient_privilege';
  END IF;
  UPDATE app.management_deviations SET status='closed',closed_by=u,closed_at=now(),close_note=p_close_note WHERE tenant_id=t AND id=p_deviation;
  receipt:=jsonb_build_object('deviation_id',p_deviation,'status','closed');
  INSERT INTO app.management_deviation_operation_receipts(tenant_id,deviation_id,action,operation_id,request_sha256,actor_id,receipt)
  VALUES(t,p_deviation,'close',p_operation_id,p_request_sha256,u,receipt);
  RETURN receipt;
END $$;

CREATE FUNCTION app.expire_management_deviations() RETURNS integer
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
  WITH changed AS (UPDATE app.management_deviations SET status='expired'
                    WHERE tenant_id=app.current_tenant() AND status IN ('requested','open')
                      AND expires_at <= now() RETURNING 1)
  SELECT count(*)::integer FROM changed
$$;

ALTER FUNCTION app.request_management_deviation(text,text,text,text,text,uuid,timestamptz,timestamptz,uuid[],uuid[],uuid[]) OWNER TO schema_owner;
ALTER FUNCTION app.approve_management_deviation(uuid,text,text) OWNER TO schema_owner;
ALTER FUNCTION app.close_management_deviation(uuid,text,text,text) OWNER TO schema_owner;
ALTER FUNCTION app.expire_management_deviations() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.request_management_deviation(text,text,text,text,text,uuid,timestamptz,timestamptz,uuid[],uuid[],uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.approve_management_deviation(uuid,text,text),app.close_management_deviation(uuid,text,text,text),app.expire_management_deviations() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.request_management_deviation(text,text,text,text,text,uuid,timestamptz,timestamptz,uuid[],uuid[],uuid[]) TO app_rw;
GRANT EXECUTE ON FUNCTION app.approve_management_deviation(uuid,text,text),app.close_management_deviation(uuid,text,text,text),app.expire_management_deviations() TO app_rw;
