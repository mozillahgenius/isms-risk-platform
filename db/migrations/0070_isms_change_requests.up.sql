-- @run-as: admin
-- 0070: Home for change requests and approvals (A.8.32) (design doc 2026-09-11 §4, item 5 of 5, the last).
--
-- A.8.32 is the control requiring changes to information processing facilities and information systems to follow change management procedures.
-- Requiring permission for a change is the substance of the control itself, so this is the only one in the §4 table given an approval (design decision 2026-09-12).
-- As an Annex A control, the stage screen only shows its count and does not make it mandatory.
--
-- Flow: request (requested) -> approval (approved) or rejection (rejected) -> implementation (implemented).
--       Requested and approved ones can be withdrawn (cancelled). Cancelled, rejected and implemented are terminal (never reverted).
-- Only app.decide_change_request() writes approvals/rejections. Executives (ciso) only; a requester never decides their own request.
-- The hash of the content at approval time is linked into app.approvals (same shape as the management review approval in 0063).
--
-- app_rw writes the table directly (restricted to the change role by the 0067 role policies), so a trigger guards state
-- transitions and decision columns against it. With write role policies alone, a member could write
-- "approved, approver = executive" themselves. Editing content after approval would shift "what was approved", so
-- content can be edited only while requested. Withdraw instead of deleting (no DELETE for app_rw). No content data is inserted.

SET ROLE schema_owner;

CREATE TABLE app.change_requests (
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL,
  title           text NOT NULL,
  -- What is changed and how (required).
  description     text NOT NULL,
  -- Impact and risk (required). A change whose impact cannot be stated cannot be decided.
  impact          text NOT NULL,
  risk_level      text NOT NULL CHECK (risk_level IN ('low','medium','high')),
  -- How to roll back on failure.
  rollback_plan   text NOT NULL DEFAULT '',
  asset_id        uuid,
  -- Planned implementation date (a plan, not content, so it can be edited after approval).
  planned_on      date,
  requested_by    uuid NOT NULL,
  requested_at    timestamptz NOT NULL DEFAULT now(),
  status          text NOT NULL DEFAULT 'requested'
                  CHECK (status IN ('requested','approved','rejected','implemented','cancelled')),
  decided_by      uuid,
  decided_at      timestamptz,
  decision_note   text NOT NULL DEFAULT '',
  implemented_by  uuid,
  implemented_at  timestamptz,
  result_note     text NOT NULL DEFAULT '',
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, asset_id)       REFERENCES app.assets(tenant_id, id),
  FOREIGN KEY (tenant_id, requested_by)   REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, decided_by)     REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, implemented_by) REFERENCES app.users(tenant_id, id),
  CHECK (title ~ '[^[:space:]]'),
  CHECK (description ~ '[^[:space:]]'),
  CHECK (impact ~ '[^[:space:]]'),
  -- Approved/rejected/implemented requires who decided and when. A pending request has no decision. Decider and time go together.
  CONSTRAINT change_requests_decision_complete CHECK (
    (decided_by IS NULL) = (decided_at IS NULL)
    AND (status NOT IN ('approved','rejected','implemented') OR decided_by IS NOT NULL)
    AND (status <> 'requested' OR decided_by IS NULL)
  ),
  -- Segregation of duties: a requester does not decide their own request.
  CONSTRAINT change_requests_decider_not_requester CHECK (decided_by IS NULL OR decided_by <> requested_by),
  -- Implemented requires who implemented it and when. Implementer and time go together.
  CONSTRAINT change_requests_implementation_complete CHECK (
    (implemented_by IS NULL) = (implemented_at IS NULL)
    AND ((status = 'implemented') = (implemented_by IS NOT NULL))
  ),
  -- Implementation comes after the decision (approval).
  CONSTRAINT change_requests_implemented_after_decided CHECK (implemented_at IS NULL OR implemented_at >= decided_at)
);
CREATE INDEX change_requests_status ON app.change_requests (tenant_id, status, requested_at DESC);

-- Guard state transitions and decision columns. Only schema_owner (= decide_change_request) can write the decision (approve/reject) columns.
-- For writes coming from app_rw, current_user is app_rw (or a role it belongs to), so the two can be told apart here.
CREATE FUNCTION app.change_requests_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  v_definer boolean := (current_user = 'schema_owner');
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'requested' OR NEW.decided_by IS NOT NULL OR NEW.decided_at IS NOT NULL
       OR NEW.decision_note <> '' OR NEW.implemented_by IS NOT NULL OR NEW.implemented_at IS NOT NULL THEN
      RAISE EXCEPTION 'change request must start as requested' USING ERRCODE = 'check_violation';
    END IF;
    -- The requester is the person making the request (prevents requesting in someone else's name and approving it yourself; Codex review 2026-09-12). Request time is now.
    IF NOT v_definer AND NEW.requested_by IS DISTINCT FROM app.current_session_user() THEN
      RAISE EXCEPTION 'requester must be the session user' USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.requested_at := now();
    RETURN NEW;
  END IF;
  -- The request's ID and tenant never change (changing them breaks the link to the approval record app.approvals.target_id).
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
    RAISE EXCEPTION 'change request id cannot be changed' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT v_definer AND (NEW.decided_by IS DISTINCT FROM OLD.decided_by
                        OR NEW.decided_at IS DISTINCT FROM OLD.decided_at
                        OR NEW.decision_note IS DISTINCT FROM OLD.decision_note) THEN
    RAISE EXCEPTION 'change request decision can only be recorded by the approval function'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NEW.requested_by IS DISTINCT FROM OLD.requested_by OR NEW.requested_at IS DISTINCT FROM OLD.requested_at THEN
    RAISE EXCEPTION 'change request requester cannot be changed' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'requested' AND NEW.status IN ('approved','rejected') AND v_definer)
    OR (OLD.status = 'requested' AND NEW.status = 'cancelled')
    OR (OLD.status = 'approved'  AND NEW.status IN ('implemented','cancelled'))
  ) THEN
    RAISE EXCEPTION 'illegal change request transition: % -> %', OLD.status, NEW.status USING ERRCODE = 'check_violation';
  END IF;
  -- Content can be edited only while requested (so it never drifts from what was approved/rejected). The planned date is not part of the content.
  IF OLD.status <> 'requested'
     AND (NEW.title, NEW.description, NEW.impact, NEW.risk_level, NEW.rollback_plan, NEW.asset_id)
         IS DISTINCT FROM (OLD.title, OLD.description, OLD.impact, OLD.risk_level, OLD.rollback_plan, OLD.asset_id) THEN
    RAISE EXCEPTION 'change request content can only be edited while requested' USING ERRCODE = 'check_violation';
  END IF;
  -- The implementation record can be written only when moving to implemented (implementer and time are never rewritten later).
  IF OLD.status <> 'approved' AND (NEW.implemented_by IS DISTINCT FROM OLD.implemented_by
                                   OR NEW.implemented_at IS DISTINCT FROM OLD.implemented_at) THEN
    RAISE EXCEPTION 'change request implementation can only be recorded once, after approval' USING ERRCODE = 'check_violation';
  END IF;
  -- The implementer is the person recording it, and the time is now (no recording implementation under another's name or at a past time).
  IF NEW.status = 'implemented' AND OLD.status = 'approved' THEN
    IF NOT v_definer AND NEW.implemented_by IS DISTINCT FROM app.current_session_user() THEN
      RAISE EXCEPTION 'implementer must be the session user' USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.implemented_at := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER change_requests_guard BEFORE INSERT OR UPDATE ON app.change_requests
  FOR EACH ROW EXECUTE FUNCTION app.change_requests_guard();

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['change_requests'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    -- Withdraw instead of deleting. No DELETE for app_rw (a request paired with an approval record must not be deleted).
    EXECUTE format('GRANT SELECT,INSERT,UPDATE ON app.%I TO app_rw',t);
    -- Same role policies as 0067 (names, shape and target tables are fixed by check_rls.sql; there is no DELETE privilege, but the shape is kept consistent).
    EXECUTE format('CREATE POLICY records_role_insert ON app.%I AS RESTRICTIVE FOR INSERT TO app_rw '
                   'WITH CHECK ((SELECT app.records_role_allows(%L)))', t, 'change');
    EXECUTE format('CREATE POLICY records_role_update ON app.%I AS RESTRICTIVE FOR UPDATE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L))) WITH CHECK ((SELECT app.records_role_allows(%L)))',
                   t, 'change', 'change');
    EXECUTE format('CREATE POLICY records_role_delete ON app.%I AS RESTRICTIVE FOR DELETE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L)))', t, 'change');
  END LOOP;
END $$;

-- Access path for the decision function to read/write requests as schema_owner (written as in 0062; nothing is visible without a context).
-- Name, shape and target table are fixed by check_rls.sql.
CREATE POLICY tenant_security_definer ON app.change_requests FOR ALL TO schema_owner
  USING (tenant_id = (SELECT app.current_tenant_or_null()))
  WITH CHECK (tenant_id = (SELECT app.current_tenant_or_null()));

COMMENT ON TABLE app.change_requests IS
  '変更の申請と承認（A.8.32）。承認・却下は app.decide_change_request() だけ（ciso・申請者以外）。中身を直せるのは申請中だけ。消さずに取りやめる。';

-- Approve/reject. Executives (ciso) only. A requester does not decide their own request. Rejection requires a reason.
-- The hash of the content at approval (title, description, impact, risk, rollback plan, asset) is linked into app.approvals.
CREATE FUNCTION app.decide_change_request(p_id uuid, p_approve boolean, p_note text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant uuid := app.current_tenant();
  v_user   uuid := app.current_session_user();
  r        app.change_requests%ROWTYPE;
  v_hash   bytea;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM app.memberships m
      JOIN app.users u ON u.tenant_id = m.tenant_id AND u.id = m.user_id
     WHERE m.tenant_id = v_tenant AND m.user_id = v_user AND m.role_key = 'ciso'
       AND m.revoked_at IS NULL AND u.status = 'active'
  ) THEN
    RAISE EXCEPTION 'executive role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT * INTO r FROM app.change_requests WHERE tenant_id = v_tenant AND id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'change request not found';
  END IF;
  IF r.status <> 'requested' THEN
    RAISE EXCEPTION 'change request is not awaiting a decision';
  END IF;
  IF r.requested_by = v_user THEN
    RAISE EXCEPTION 'requester cannot decide their own change request' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_approve IS NULL THEN
    RAISE EXCEPTION 'decision required';
  END IF;
  IF NOT p_approve AND (p_note IS NULL OR p_note !~ '[^[:space:]]') THEN
    RAISE EXCEPTION 'rejection reason required';
  END IF;
  IF p_approve THEN
    -- Hash a JSON array (joining with delimiters alone would let bodies containing newlines turn different content into the same bytes).
    v_hash := public.digest(pg_catalog.convert_to(jsonb_build_array(r.title, r.description, r.impact, r.risk_level,
                                                                    r.rollback_plan, coalesce(r.asset_id::text, ''))::text,
                                                  'UTF8'), 'sha256');
    INSERT INTO app.approvals
      (tenant_id, target_type, target_id, target_version_hash, approver_user_id, comment, created_by)
    VALUES (v_tenant, 'change_request', p_id, v_hash, v_user, p_note, v_user);
  END IF;
  UPDATE app.change_requests
     SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
         decided_by = v_user, decided_at = now(), decision_note = coalesce(p_note, ''),
         updated_at = now(), updated_by = v_user
   WHERE tenant_id = v_tenant AND id = p_id;
END $$;
ALTER FUNCTION app.decide_change_request(uuid, boolean, text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.decide_change_request(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.decide_change_request(uuid, boolean, text) TO app_rw;

COMMENT ON FUNCTION app.decide_change_request(uuid, boolean, text) IS
  '変更の申請（A.8.32）の承認・却下。ciso のみ・申請者以外・申請中だけ。承認は中身のハッシュを app.approvals へ結ぶ。却下は理由必須。';

-- Add change to the permission table: owner / admin / manager / member (anyone can request; only ciso decides, via the function above).
-- Auditors may not write. This only adds one kind to the 0069 version (down restores the 0069 version).
CREATE OR REPLACE FUNCTION app.records_role_allows(p_kind text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text;
  v_allowed text[];
BEGIN
  v_allowed := CASE p_kind
    WHEN 'audit'             THEN ARRAY['owner','admin','auditor']
    WHEN 'corrective'        THEN ARRAY['owner','admin','manager']
    WHEN 'effectiveness'     THEN ARRAY['owner','admin']
    WHEN 'management_review' THEN ARRAY['owner','admin']
    WHEN 'objective'         THEN ARRAY['owner','admin']
    WHEN 'evidence'          THEN ARRAY['owner','admin','manager']
    WHEN 'exception'         THEN ARRAY['owner']
    WHEN 'context'           THEN ARRAY['owner','admin']
    WHEN 'legal'             THEN ARRAY['owner','admin','manager']
    WHEN 'continuity'        THEN ARRAY['owner','admin','manager']
    WHEN 'vulnerability'     THEN ARRAY['owner','admin','manager']
    WHEN 'change'            THEN ARRAY['owner','admin','manager','member']
  END;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'unknown record kind: %', p_kind;
  END IF;
  IF app.current_session_user() IS NULL THEN
    RETURN false;
  END IF;
  v_role := app.current_management_role();
  RETURN v_role IS NOT NULL AND v_role = ANY (v_allowed);
END $$;

RESET ROLE;
