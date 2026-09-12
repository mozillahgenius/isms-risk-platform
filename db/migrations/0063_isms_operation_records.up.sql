-- @run-as: admin
-- 0063: storage for entering ISMS operation records from the UI (stage 1 of design doc 2026-09-11 §4/§5).
--
-- In scope are the 4 records, among those needed every year in the annual cycle, that §5.3 chose to do first:
--   internal audit (9.2), findings and corrective action (10.2), management review (9.3), control effectiveness evaluation (9.1).
-- The first 3 already had tables but no way to write them from the UI. Effectiveness evaluation has no table at all, so it is created here.
--
-- Policy:
--   - Writes are done directly by web server actions as app_rw (same as the existing risk register).
--     Writes are not routed through SECURITY DEFINER functions because every target table would need a
--     schema_owner policy, spreading the "raises without context" trap fixed in 0062.
--   - Role checks happen in one place, app.require_records_role(kind) (not relying on UI visibility alone).
--   - Only management review minutes involve approval. Executives (ciso) approve, and the hash of the
--     minutes at approval time is linked to app.approvals. Approving the same minutes twice is rejected (same shape as 0034 / 0056).
--   - No content data is inserted (that would fabricate a track record).

SET ROLE schema_owner;

-- ---------------------------------------------------------------------------
-- Control effectiveness evaluation (9.1). "Implemented" and "effective" are different. Record the latter together with
-- what was taken as effective (criteria) and when and by whom it was evaluated. An evaluation without criteria is no evaluation, so empty is not allowed.
CREATE TABLE app.control_effectiveness (
  id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  measure_id         uuid NOT NULL,
  criteria           text NOT NULL,
  evaluated_on       date NOT NULL,
  evaluator_user_id  uuid NOT NULL,
  result             text NOT NULL CHECK (result IN ('effective','partially_effective','not_effective')),
  evidence_note      text NOT NULL DEFAULT '',
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, measure_id)        REFERENCES app.measures(tenant_id, id),
  FOREIGN KEY (tenant_id, evaluator_user_id) REFERENCES app.users(tenant_id, id),
  -- btrim only strips spaces by default, so criteria of only tabs or newlines would slip through. At least one non-whitespace character is required.
  CHECK (criteria ~ '[^[:space:]]')
);
CREATE INDEX control_effectiveness_measure ON app.control_effectiveness (tenant_id, measure_id, evaluated_on DESC);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['control_effectiveness'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO app_rw',t);
  END LOOP;
END $$;

COMMENT ON TABLE app.control_effectiveness IS
  '統制の有効性評価（9.1）。criteria（何をもって有効とみなすか）は必須。評価日が今日までのものだけを実施済みとして数える。';

-- ---------------------------------------------------------------------------
-- For each record kind, decide in one place which roles may write it.
--   audit              internal audit / audit findings        : owner / admin / auditor (auditors cannot write business data but do write audit records)
--   corrective         corrective action                      : owner / admin / manager
--   effectiveness      effectiveness evaluation / review      : owner / admin
--   management_review  management review                      : owner / admin
CREATE FUNCTION app.require_records_role(p_kind text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text := app.current_management_role();
  v_allowed text[];
BEGIN
  IF app.current_session_user() IS NULL THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  v_allowed := CASE p_kind
    WHEN 'audit'             THEN ARRAY['owner','admin','auditor']
    WHEN 'corrective'        THEN ARRAY['owner','admin','manager']
    WHEN 'effectiveness'     THEN ARRAY['owner','admin']
    WHEN 'management_review' THEN ARRAY['owner','admin']
  END;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'unknown record kind: %', p_kind;
  END IF;
  -- When the role is NULL, `NOT (NULL = ANY (...))` is NULL and the IF does not branch, letting it through. Reject NULL explicitly.
  IF v_role IS NULL OR NOT (v_role = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_role;
END $$;
ALTER FUNCTION app.require_records_role(text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.require_records_role(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.require_records_role(text) TO app_rw;

-- ---------------------------------------------------------------------------
-- Approval of management review minutes (9.3). Add one read-only definer policy so the approval function
-- can read the minutes as schema_owner. Its name and shape are fixed by check_rls.sql:
-- tenant_security_definer_read (compares with NULL when there is no context = sees nothing; same style as 0062).
CREATE POLICY tenant_security_definer_read ON app.management_reviews FOR SELECT TO schema_owner
  USING (tenant_id = (SELECT app.current_tenant_or_null()));

CREATE FUNCTION app.approve_management_review(p_review_id uuid, p_comment text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant  uuid := app.current_tenant();
  v_user    uuid := app.current_session_user();
  v_minutes text;
  v_held    date;
  v_hash    bytea;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM app.memberships m
      JOIN app.users u ON u.tenant_id = m.tenant_id AND u.id = m.user_id
     WHERE m.tenant_id = v_tenant AND m.user_id = v_user AND m.role_key = 'ciso'
       AND m.revoked_at IS NULL AND u.status = 'active'
  ) THEN
    RAISE EXCEPTION 'executive role required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT minutes_md, held_on INTO v_minutes, v_held
    FROM app.management_reviews WHERE tenant_id = v_tenant AND id = p_review_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'management review not found';
  END IF;
  -- Do not approve minutes of a review not yet held (no date, or a future date). A plan is not treated as done.
  IF v_held IS NULL OR v_held > (now() AT TIME ZONE 'Asia/Tokyo')::date THEN
    RAISE EXCEPTION 'management review has not been held';
  END IF;
  IF v_minutes IS NULL OR v_minutes !~ '[^[:space:]]' THEN
    RAISE EXCEPTION 'management review minutes are empty';
  END IF;

  -- Hash the meeting date together with the minutes (so "what was approved" survives later edits to the minutes).
  v_hash := public.digest(pg_catalog.convert_to(v_held::text || E'\n' || v_minutes, 'UTF8'), 'sha256');
  IF EXISTS (
    SELECT 1 FROM app.approvals
     WHERE tenant_id = v_tenant AND target_type = 'management_review'
       AND target_id = p_review_id AND target_version_hash = v_hash
  ) THEN
    RAISE EXCEPTION 'these management review minutes are already approved';
  END IF;

  INSERT INTO app.approvals
    (tenant_id, target_type, target_id, target_version_hash, approver_user_id, comment, created_by)
  VALUES (v_tenant, 'management_review', p_review_id, v_hash, v_user, p_comment, v_user);
END $$;
ALTER FUNCTION app.approve_management_review(uuid, text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.approve_management_review(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.approve_management_review(uuid, text) TO app_rw;

COMMENT ON FUNCTION app.approve_management_review(uuid, text) IS
  'マネジメントレビュー（9.3）の議事の承認。ciso のみ。開催日が今日までで議事が空でないこと。開催日＋議事のハッシュを app.approvals へ結び、同じ議事の二重承認は拒否する。';

RESET ROLE;

-- ---------------------------------------------------------------------------
-- Invariants of corrective action (10.2). The table owner is not necessarily schema_owner, so add them as superuser.
-- Existing rows are validated too (not NOT VALID). With NOT VALID, violating existing rows would remain, even unrelated updates
-- to those rows would fail re-checking, and a later VALIDATE would not pass either (Codex review 2026-09-12, round 2).
-- If any row violates them, the migration itself fails. Do not fix silently; a human checks the rows first (audit records are not rewritten by machine).
ALTER TABLE app.corrective_actions
  ADD CONSTRAINT corrective_actions_effectiveness_complete CHECK (
    (effectiveness_reviewed_by IS NULL AND effectiveness_reviewed_at IS NULL AND effectiveness_result IS NULL)
    OR (effectiveness_reviewed_by IS NOT NULL AND effectiveness_reviewed_at IS NOT NULL AND effectiveness_result IS NOT NULL)
  );
-- One cannot say "it worked" before the action is finished. Besides being completed, the review time must be after completion
-- (you cannot enter only a completion time and claim a review dated earlier than it).
ALTER TABLE app.corrective_actions
  ADD CONSTRAINT corrective_actions_effectiveness_after_completion CHECK (
    effectiveness_reviewed_at IS NULL
    OR (completed_at IS NOT NULL AND effectiveness_reviewed_at >= completed_at)
  );
-- Segregation of duties: the person responsible for an action does not review its own effectiveness.
ALTER TABLE app.corrective_actions
  ADD CONSTRAINT corrective_actions_reviewer_not_owner CHECK (
    effectiveness_reviewed_by IS NULL OR owner_user_id IS NULL OR effectiveness_reviewed_by <> owner_user_id
  );
