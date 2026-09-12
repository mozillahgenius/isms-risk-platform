-- @run-as: admin
-- 0066: storage for legal, regulatory and contractual requirements (A.5.31) (the 2nd table of design doc 2026-09-11 §4).
--
-- A.5.31 is the control requiring that legal, statutory, regulatory and contractual requirements relevant to information security be identified, documented and kept up to date.
-- As an Annex A control, whether it applies is decided by the Statement of Applicability. The stage screen only shows a count and does not make it mandatory
-- (design decision of 2026-09-12).
--
-- Relations to other tables are only the "corresponding control and evidence" named by the design doc (both optional):
--   measure_id  -> app.measures (the control that meets the requirement)
--   evidence_id -> app.evidences (evidence that it is met)
-- A compliance assessment (compliant / partially compliant / non-compliant) either has "date, assessor and result" all set, or is not assessed (same idea as 0055).
-- No approval (the standard's text does not require it). Retire instead of deleting. No content data is inserted.
-- Formatting, RLS and down policy are the same as 0065.

SET ROLE schema_owner;

CREATE TABLE app.legal_requirements (
  id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  kind               text NOT NULL CHECK (kind IN ('law','regulation','contract','standard','other')),
  title              text NOT NULL,
  -- What it requires (mandatory). With a list of names only, nobody can judge whether it is met.
  requirement        text NOT NULL,
  -- Where in the original text, e.g. clause or contract article number.
  source_ref         text NOT NULL DEFAULT '',
  owner_user_id      uuid,
  measure_id         uuid,
  evidence_id        uuid,
  compliance_status  text NOT NULL DEFAULT 'not_assessed'
                     CHECK (compliance_status IN ('not_assessed','compliant','partially_compliant','non_compliant')),
  assessed_on        date,
  assessed_by        uuid,
  next_review_on     date,
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, kind, title),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, assessed_by)   REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, measure_id)    REFERENCES app.measures(tenant_id, id),
  FOREIGN KEY (tenant_id, evidence_id)   REFERENCES app.evidences(tenant_id, id),
  CHECK (title ~ '[^[:space:]]'),
  CHECK (requirement ~ '[^[:space:]]'),
  -- Claiming an assessment requires when and by whom. If not assessed, both are empty.
  CONSTRAINT legal_requirements_assessment_complete CHECK (
    (compliance_status = 'not_assessed' AND assessed_on IS NULL AND assessed_by IS NULL)
    OR (compliance_status <> 'not_assessed' AND assessed_on IS NOT NULL AND assessed_by IS NOT NULL)
  ),
  -- The next review comes after the assessment.
  CONSTRAINT legal_requirements_review_after_assessment CHECK (
    next_review_on IS NULL OR assessed_on IS NULL OR next_review_on > assessed_on
  )
);
CREATE INDEX legal_requirements_measure ON app.legal_requirements (tenant_id, measure_id) WHERE measure_id IS NOT NULL;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['legal_requirements'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO app_rw',t);
  END LOOP;
END $$;

COMMENT ON TABLE app.legal_requirements IS
  '法令・規制・契約上の要求事項（A.5.31）。requirement は必須。適合の評価は assessed_on / assessed_by が揃ったときだけ。統制（measure_id）・証跡（evidence_id）へ任意で結ぶ。';

-- Add legal to the writable roles: owner / admin / manager (same tier as corrective action and evidence; records of business operation).
-- Auditors may not write. This is 0065's version with one kind added (down restores 0065's version).
CREATE OR REPLACE FUNCTION app.require_records_role(p_kind text) RETURNS text
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
    WHEN 'objective'         THEN ARRAY['owner','admin']
    WHEN 'evidence'          THEN ARRAY['owner','admin','manager']
    WHEN 'exception'         THEN ARRAY['owner']
    WHEN 'context'           THEN ARRAY['owner','admin']
    WHEN 'legal'             THEN ARRAY['owner','admin','manager']
  END;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'unknown record kind: %', p_kind;
  END IF;
  IF v_role IS NULL OR NOT (v_role = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_role;
END $$;

RESET ROLE;
