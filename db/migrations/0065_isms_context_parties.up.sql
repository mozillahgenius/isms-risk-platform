-- @run-as: admin
-- 0065: storage for organizational issues (4.1) and interested parties (4.2) (the 1st table of design doc 2026-09-11 §4).
--
-- 4.1 requires "determining" external and internal issues affecting the ISMS's intended outcomes;
-- 4.2 requires "determining" interested parties, their requirements, and which of those the ISMS addresses.
-- Neither unconditionally requires documented information, so the stage screen only shows a count and does not make them mandatory
-- (design decision of 2026-09-12; only clauses requiring documented information, like 9.1, are mandatory).
--
-- Formatting follows 0055 (tenant FK, (tenant_id, id) primary key, CHECK rejecting whitespace-only mandatory fields,
-- no FK on created_by, down refuses if data exists). RLS is the same two policies as 0063
-- (writes are done by web server actions as app_rw, so no definer policy is needed).
-- No approval (the standard's text does not require it). No version table either. No content data is inserted.

SET ROLE schema_owner;

-- Organizational issues (4.1). An issue whose effect on the ISMS (isms_impact) cannot be written is not a 4.1 issue, so empty is not allowed.
CREATE TABLE app.context_issues (
  id             uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('internal','external')),
  title          text NOT NULL,
  description    text NOT NULL DEFAULT '',
  isms_impact    text NOT NULL,
  owner_user_id  uuid,
  -- Date of the last review. Empty if never reviewed.
  reviewed_on    date,
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, kind, title),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id),
  CHECK (title ~ '[^[:space:]]'),
  CHECK (isms_impact ~ '[^[:space:]]')
);

-- Interested parties (4.2). requirements are the information-security requirements (4.2 b) and are mandatory.
-- addressed_in_isms is the subset the ISMS addresses (4.2 c). Empty means "not decided yet".
CREATE TABLE app.interested_parties (
  id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  name               text NOT NULL,
  category           text NOT NULL
                     CHECK (category IN ('customer','regulator','employee','shareholder','supplier','partner','other')),
  requirements       text NOT NULL,
  addressed_in_isms  text NOT NULL DEFAULT '',
  owner_user_id      uuid,
  reviewed_on        date,
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, name),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id),
  CHECK (name ~ '[^[:space:]]'),
  CHECK (requirements ~ '[^[:space:]]')
);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['context_issues','interested_parties'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO app_rw',t);
  END LOOP;
END $$;

COMMENT ON TABLE app.context_issues IS
  '組織の課題（4.1）。kind は internal / external。isms_impact（ISMS にどう効くか）は必須。有効なもの（status=active）を数える。';
COMMENT ON TABLE app.interested_parties IS
  '利害関係者（4.2）。requirements（情報セキュリティに関する要求）は必須。addressed_in_isms はそのうち ISMS で扱うもの。';

-- Add context (organizational issues, interested parties) to the writable roles: owner / admin (same tier as information security objectives).
-- Auditors may not write. This is 0064's version with one kind added (down restores 0064's version).
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
