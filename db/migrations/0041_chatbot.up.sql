-- 0041 app: 従業員向けチャットボットの受け皿(画面⑥)
--
-- ユーザー決定(2026-09-02): LLM呼び出し自体は今回実装しない(0039/0040と
-- 同じ方針、将来ローカルLLM導入時に実装)。会話・メッセージを保存する
-- スキーマのみ用意する。RAG構成・公開可否フィルタ・Slack連携は未着手。
--
-- 0037以降と同じ理由でRLSはここで個別設定する。

CREATE TABLE app.chatbot_conversations (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  -- Slack側のユーザーID。app.usersとは別軸(Slack連携が無い状態でも会話を
  -- 保存できるよう、FKにはしない。仕様書のSlack権限管理は未決事項)。
  slack_user_id text NOT NULL,
  channel       text NOT NULL DEFAULT '',
  started_at    timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id)
);

CREATE TABLE app.chatbot_messages (
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL,
  conversation_id uuid NOT NULL,
  role            text NOT NULL CHECK (role IN ('user','bot')),
  content         text NOT NULL,
  -- 受入条件C1「根拠(引用元)付きで回答する」。RAG未実装のため当面は空配列。
  cited_sources   jsonb NOT NULL DEFAULT '[]'::jsonb
                  CHECK (jsonb_typeof(cited_sources) = 'array'),
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, conversation_id) REFERENCES app.chatbot_conversations(tenant_id, id)
);

COMMENT ON TABLE app.chatbot_conversations IS 'Slack経由の従業員チャットボット会話。RAG・Slack連携は未実装(ローカルLLM導入待ち、2026-09-02決定)';
COMMENT ON TABLE app.chatbot_messages IS 'チャットボットの会話メッセージ。cited_sourcesは受入条件C1(根拠付き回答)に対応、RAG未実装のため当面空配列';

DO $$
DECLARE
  t text;
  tables constant text[] := ARRAY['chatbot_conversations','chatbot_messages'];
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
