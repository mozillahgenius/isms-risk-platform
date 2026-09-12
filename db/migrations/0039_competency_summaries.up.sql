-- 0039 app: Home for LLM competency summaries (part of screen 5, "competency management")
--
-- User decision (2026-09-02): the LLM call itself is not implemented this time. It is to be implemented
-- later by connecting to a local LLM once one is introduced. This migration
-- only prepares the data schema for storing generated results (a home for them).
-- The generation trigger (a manual button action by the secretariat only, as decided by the user), the actual LLM
-- call logic, and the "generate" action on screen will be implemented separately when the local LLM is introduced.
--
-- For the same reason as 0037/0038, RLS is set up individually here.

CREATE TABLE app.competency_summaries (
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL,
  member_id       uuid NOT NULL,
  generated_at    timestamptz NOT NULL DEFAULT now(),
  summary_text    text NOT NULL,
  -- References to the sources (training history, fulfillment status, results of assigned measures, etc.). Corresponds to
  -- source_data_refs in the spec. A JSON array so that multiple references can be held.
  source_data_refs jsonb NOT NULL DEFAULT '[]'::jsonb,
  model_ref       text NOT NULL,
  -- Spec C4: "has a human-confirmed flag". A guardrail so LLM output is not used as-is in HR
  -- evaluations (the assumed practice is that unconfirmed summaries are reference information only).
  confirmed_by    uuid,
  confirmed_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, member_id) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, confirmed_by) REFERENCES app.users(tenant_id, id),
  -- Require both to match, to prevent confirmed_at alone being set (a confirmed state with an unknown confirmer).
  -- confirmed_by IS NULL OR confirmed_at IS NOT NULL alone cannot prevent the reverse pattern of setting only
  -- confirmed_at and leaving confirmed_by NULL
  -- (Codex review finding, 2026-09-02).
  CHECK ((confirmed_by IS NULL) = (confirmed_at IS NULL))
);

COMMENT ON TABLE app.competency_summaries IS 'LLMが生成したメンバー別力量サマリー。生成ロジックは未実装(ローカルLLM導入待ち、2026-09-02決定)。人事評価への直接使用は想定しない';

DO $$
BEGIN
  ALTER TABLE app.competency_summaries ENABLE ROW LEVEL SECURITY;
  ALTER TABLE app.competency_summaries FORCE ROW LEVEL SECURITY;
  CREATE POLICY tenant_isolation ON app.competency_summaries FOR ALL TO app_rw
    USING (tenant_id = app.current_tenant())
    WITH CHECK (tenant_id = app.current_tenant());
  CREATE POLICY tenant_read ON app.competency_summaries FOR SELECT TO app_ro
    USING (tenant_id = app.current_tenant());
  REVOKE ALL ON app.competency_summaries FROM PUBLIC;
  GRANT SELECT, INSERT, UPDATE, DELETE ON app.competency_summaries TO app_rw;
  GRANT SELECT ON app.competency_summaries TO app_ro;
END $$;
