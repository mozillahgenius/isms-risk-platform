-- @run-as: admin
-- A risk acceptance is bound to immutable residual and inherent evaluation evidence.
ALTER TABLE app.risk_acceptances
  ADD COLUMN evaluation_snapshot_id uuid,
  ADD COLUMN evaluation_snapshot_sha256 text CHECK (evaluation_snapshot_sha256 ~ '^[a-f0-9]{64}$'),
  ADD COLUMN inherent_snapshot_id uuid,
  ADD COLUMN inherent_snapshot_sha256 text CHECK (inherent_snapshot_sha256 ~ '^[a-f0-9]{64}$');
ALTER TABLE app.risk_acceptances
  ADD CONSTRAINT risk_acceptances_evaluation_snapshot_fk FOREIGN KEY (tenant_id,evaluation_snapshot_id) REFERENCES app.risk_evaluation_snapshots(tenant_id,id),
  ADD CONSTRAINT risk_acceptances_inherent_snapshot_fk FOREIGN KEY (tenant_id,inherent_snapshot_id) REFERENCES app.risk_evaluation_snapshots(tenant_id,id);
ALTER TABLE app.internal_management_audit_events
  ADD COLUMN evaluation_snapshot_id uuid,
  ADD COLUMN evaluation_snapshot_sha256 text CHECK (evaluation_snapshot_sha256 IS NULL OR evaluation_snapshot_sha256 ~ '^[a-f0-9]{64}$'),
  ADD COLUMN inherent_snapshot_id uuid,
  ADD COLUMN inherent_snapshot_sha256 text CHECK (inherent_snapshot_sha256 IS NULL OR inherent_snapshot_sha256 ~ '^[a-f0-9]{64}$');

CREATE OR REPLACE FUNCTION app.risk_evaluation_snapshot_sha256(p_snapshot app.risk_evaluation_snapshots) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
  SELECT encode(public.digest(convert_to(
    p_snapshot.id::text||':'||p_snapshot.risk_scenario_id::text||':'||p_snapshot.stage||':'||p_snapshot.assessed_on::text||':'||
    p_snapshot.probability::text||':'||p_snapshot.impact::text||':'||coalesce(p_snapshot.measure_id::text,'')||':'||
    p_snapshot.rationale||':'||p_snapshot.source_note||':'||to_char(p_snapshot.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'UTF8'),'sha256'),'hex')
$$;
ALTER FUNCTION app.risk_evaluation_snapshot_sha256(app.risk_evaluation_snapshots) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.risk_evaluation_snapshot_sha256(app.risk_evaluation_snapshots) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.risk_evaluation_snapshot_sha256(app.risk_evaluation_snapshots) TO app_rw;

CREATE OR REPLACE FUNCTION app.accept_risk_snapshot(
  p_risk uuid, p_evaluation uuid, p_evaluation_hash text, p_inherent uuid, p_inherent_hash text, p_reason text
) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
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
REVOKE ALL ON FUNCTION app.accept_risk_snapshot(uuid,uuid,text,uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.accept_risk_snapshot(uuid,uuid,text,uuid,text,text) TO app_rw;
