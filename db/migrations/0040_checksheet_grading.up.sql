-- 0040 app: storage for automatic checksheet grading (screen 4)
--
-- User decision (2026-09-02): the LLM call itself is not implemented this time (same policy as 0039's
-- competency_summaries; to be implemented when a local LLM is introduced).
-- Only the schema for accepting uploads and storing per-question judgements is prepared.
--
-- Given that uploaded files may contain personal information (an open item in the spec),
-- the file itself is not stored. file_ref is only a reference to an external storage location.
--
-- RLS is configured individually here, for the same reason as 0037 onward.

CREATE TABLE app.checksheet_submissions (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  uploaded_at   timestamptz NOT NULL DEFAULT now(),
  uploaded_by   uuid,
  -- The file itself is not stored. Only a reference to an external storage location (Drive etc.)
  -- (open item: handling of personal information in uploaded files is undecided).
  -- The CHECK constrains it as far as non-empty, but validating the format -- "is this really a reference, not the
  -- content itself (Base64 etc.)" -- is the app layer's role (to be implemented together with
  -- the upload feature. Codex review 2026-09-02: stated explicitly that a DB constraint alone
  -- is only a convention).
  file_ref      text NOT NULL CHECK (file_ref <> ''),
  parsed_status text NOT NULL DEFAULT 'pending'
                  CHECK (parsed_status IN ('pending','parsed','failed')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, uploaded_by) REFERENCES app.users(tenant_id, id)
);

CREATE TABLE app.checksheet_answers (
  id             uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL,
  submission_id  uuid NOT NULL,
  question       text NOT NULL,
  -- LLM judgement. Generation logic is not implemented, so it is always NULL for now.
  llm_judgement  text CHECK (llm_judgement IS NULL OR llm_judgement IN ('適合','要確認','不適合')),
  confidence     numeric(4,3) CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1 AND confidence <> 'NaN'::numeric)),
  raw_llm_output text,                      -- audit trail (spec C4). Generation logic not implemented, so NULL for now
  -- Acceptance criterion C3 "a path for humans to review and correct". Keep the LLM judgement and the human's final decision
  -- separate (applying to human_judgement too the same design as 0039's confirmed_by/at: "never create a
  -- confirmed state with an unknown confirmer").
  human_judgement text CHECK (human_judgement IS NULL OR human_judgement IN ('適合','要確認','不適合')),
  reviewed_by    uuid,
  reviewed_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, submission_id) REFERENCES app.checksheet_submissions(tenant_id, id),
  FOREIGN KEY (tenant_id, reviewed_by) REFERENCES app.users(tenant_id, id),
  CHECK ((reviewed_by IS NULL) = (reviewed_at IS NULL)),
  -- When a human fills in human_judgement, who confirmed it and when must always accompany it
  -- (reflecting the finding about the loophole in 0039's CHECK constraint, constrain both directions from the start).
  CHECK (human_judgement IS NULL OR reviewed_by IS NOT NULL)
);

COMMENT ON TABLE app.checksheet_submissions IS 'アップロードされたチェックシートの受付記録。ファイル本体は保存せずfile_refで参照のみ';
COMMENT ON TABLE app.checksheet_answers IS '設問ごとのLLM判定結果と人によるレビュー。生成ロジックは未実装(ローカルLLM導入待ち、2026-09-02決定)';

DO $$
DECLARE
  t text;
  tables constant text[] := ARRAY['checksheet_submissions','checksheet_answers'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw
                    USING (tenant_id = app.current_tenant())
                    WITH CHECK (tenant_id = app.current_tenant())', t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro
                    USING (tenant_id = app.current_tenant())', t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON app.%I TO app_rw', t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro', t);
  END LOOP;
END $$;
