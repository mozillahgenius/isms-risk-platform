-- 0038 app: 力量管理(画面⑤「力量管理」)
--
-- ISO/IEC 27001の力量要件(本文7.2)に相当する管理領域。役割ごとに必要な
-- 力量(職能要件)を定義し、メンバーごとの充足状況を記録する。
--
-- 0037と同じ理由でRLSはここで個別設定する(0015のRLS一括適用は0015実行
-- 時点の既存テーブルにしか効かない。0037実装時に発見・以後の新規テーブル
-- では最初から個別設定する)。

CREATE TABLE app.competency_requirements (
  id                  uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL,
  role                text NOT NULL,
  required_competency text NOT NULL,
  description         text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, role, required_competency)
);

CREATE TABLE app.competency_fulfillments (
  id             uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL,
  requirement_id uuid NOT NULL,
  member_id      uuid NOT NULL,
  status         text NOT NULL DEFAULT '未充足'
                   CHECK (status IN ('充足','育成中','未充足')),
  evidence_ref   text NOT NULL DEFAULT '',
  assessed_on    date NOT NULL DEFAULT CURRENT_DATE,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, requirement_id) REFERENCES app.competency_requirements(tenant_id, id),
  FOREIGN KEY (tenant_id, member_id) REFERENCES app.users(tenant_id, id),
  -- 同一要件・同一メンバーの充足状況は1行に集約する(履歴が要る場合はassessed_on
  -- 込みの追記型へ後日拡張する。まずは「今どうか」の一覧表示に絞る)。
  UNIQUE (tenant_id, requirement_id, member_id)
);

COMMENT ON TABLE app.competency_requirements IS '役割ごとに必要な力量(職能要件)の定義';
COMMENT ON TABLE app.competency_fulfillments IS '力量要件に対するメンバーごとの充足状況。evidence_refに根拠(研修修了記録等)の所在を記す';

DO $$
DECLARE
  t text;
  tables constant text[] := ARRAY['competency_requirements','competency_fulfillments'];
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
