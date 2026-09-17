-- 0039 app: LLM力量サマリーの受け皿(画面⑤「力量管理」の一部)
--
-- ユーザー決定(2026-09-02): LLM呼び出し自体は今回実装しない。将来ローカルLLMを
-- 導入する想定で、そちらに接続する形で改めて実装する。本マイグレーションは
-- 生成結果を保存するためのデータスキーマのみを用意する(受け皿)。
-- 生成トリガー(事務局の手動ボタン操作のみ、とユーザー決定済み)・実際のLLM
-- 呼び出しロジック・画面上の「生成」操作は、ローカルLLM導入時に別途実装する。
--
-- 0037/0038と同じ理由でRLSはここで個別設定する。

CREATE TABLE app.competency_summaries (
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL,
  member_id       uuid NOT NULL,
  generated_at    timestamptz NOT NULL DEFAULT now(),
  summary_text    text NOT NULL,
  -- 根拠元(教育受講歴・充足状況・担当施策実績等)への参照。仕様書の
  -- source_data_refsに対応。JSON配列で複数の参照を持てるようにする。
  source_data_refs jsonb NOT NULL DEFAULT '[]'::jsonb,
  model_ref       text NOT NULL,
  -- 仕様書C4「人による確認済みフラグを持つ」。LLM出力をそのまま人事評価に
  -- 使わないためのガードレール(未確認のサマリーは参考情報止まりとする運用を想定)。
  confirmed_by    uuid,
  confirmed_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, member_id) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, confirmed_by) REFERENCES app.users(tenant_id, id),
  -- confirmed_at単独設定(確認者不明の確認済み状態)を防ぐため両方一致を要求する。
  -- confirmed_by IS NULL OR confirmed_at IS NOT NULL だけだと、confirmed_atのみ
  -- 設定してconfirmed_byをNULLのままにする逆パターンを防げない
  -- (Codexレビュー2026-09-02指摘)。
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
