-- @run-as: admin
-- 0069: Receptacle for technical vulnerability management (A.8.8) (4th item of design doc 2026-09-11 §4).
--
-- A.8.8 is the control requiring that information on technical vulnerabilities be obtained, exposure evaluated, and appropriate measures taken.
-- As an Annex A control, whether it applies is decided by the Statement of Applicability. The step page only shows the count and does not make it mandatory
-- (design decision 2026-09-12).
--
-- Status: detected (open) -> in progress (in_progress) -> mitigated (mitigated), or false positive (false_positive).
-- There is no "accept without fixing" status: per the decision not to create a new approval flow (2026-09-12),
-- and because it does not fit existing exceptions (attached to findings) either. If accepted, handle it as a risk in the risk register.
-- Claiming closed (mitigated / false positive) requires a closed date; a false positive requires a reason.
-- Only one open record per identifier (CVE etc.) and asset (recurrence after closing is entered as a new record).
-- Linking to an asset is optional (a relation named by the design doc). No approval is attached. No content data is inserted.
-- Formatting, RLS, and down policy are the same as 0065-0068. The table is written only by the records UI, so 0067's role policies are applied too.

SET ROLE schema_owner;

CREATE TABLE app.vulnerabilities (
  id               uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL,
  title            text NOT NULL,
  -- CVE number, vendor advisory number, etc. Empty if none.
  identifier       text NOT NULL DEFAULT '',
  source           text NOT NULL CHECK (source IN ('scan','advisory','report','pentest','other')),
  asset_id         uuid,
  severity         text NOT NULL CHECK (severity IN ('critical','high','medium','low')),
  detected_on      date NOT NULL,
  due_date         date,
  status           text NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open','in_progress','mitigated','false_positive')),
  resolved_on      date,
  resolution_note  text NOT NULL DEFAULT '',
  owner_user_id    uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, asset_id)      REFERENCES app.assets(tenant_id, id),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id),
  CHECK (title ~ '[^[:space:]]'),
  CONSTRAINT vulnerabilities_due_after_detected CHECK (due_date IS NULL OR due_date >= detected_on),
  -- A closed date is present only when closed (mitigated / false positive). Rejects open-with-closed-date and closed-without-one.
  CONSTRAINT vulnerabilities_resolved_iff_closed CHECK (
    (status IN ('mitigated','false_positive')) = (resolved_on IS NOT NULL)
  ),
  CONSTRAINT vulnerabilities_resolved_after_detected CHECK (resolved_on IS NULL OR resolved_on >= detected_on),
  -- If claiming a false positive, write why it is not a vulnerability.
  CONSTRAINT vulnerabilities_false_positive_reason CHECK (
    status <> 'false_positive' OR resolution_note ~ '[^[:space:]]'
  )
);
-- Open (detected / in progress) records: only one per identifier and asset.
-- Separate indexes for with-asset and without-asset. Substituting a fixed UUID for no-asset would confuse it with the asset having that UUID
-- (Codex review 2026-09-12). NULLS NOT DISTINCT requires PostgreSQL 15+, so it is not used.
CREATE UNIQUE INDEX vulnerabilities_open_identifier ON app.vulnerabilities (tenant_id, identifier)
  WHERE identifier <> '' AND asset_id IS NULL AND status IN ('open','in_progress');
CREATE UNIQUE INDEX vulnerabilities_open_identifier_asset ON app.vulnerabilities (tenant_id, identifier, asset_id)
  WHERE identifier <> '' AND asset_id IS NOT NULL AND status IN ('open','in_progress');
CREATE INDEX vulnerabilities_open ON app.vulnerabilities (tenant_id, status, due_date);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['vulnerabilities'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO app_rw',t);
    -- Same role policies as 0067 (names, shape, and target tables are pinned by check_rls.sql).
    EXECUTE format('CREATE POLICY records_role_insert ON app.%I AS RESTRICTIVE FOR INSERT TO app_rw '
                   'WITH CHECK ((SELECT app.records_role_allows(%L)))', t, 'vulnerability');
    EXECUTE format('CREATE POLICY records_role_update ON app.%I AS RESTRICTIVE FOR UPDATE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L))) WITH CHECK ((SELECT app.records_role_allows(%L)))',
                   t, 'vulnerability', 'vulnerability');
    EXECUTE format('CREATE POLICY records_role_delete ON app.%I AS RESTRICTIVE FOR DELETE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L)))', t, 'vulnerability');
  END LOOP;
END $$;

COMMENT ON TABLE app.vulnerabilities IS
  '技術的脆弱性（A.8.8）。閉じた（mitigated / false_positive）ときだけ resolved_on が入る。誤検知は理由必須。開いている記録は同じ識別子・資産で 1 つだけ。';

-- Add vulnerability to the permission table: owner / admin / manager (operational business records). Auditors may not write.
-- Only one kind added to the 0068 version (down restores the 0068 version).
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
