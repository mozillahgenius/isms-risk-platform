-- 0037 app: 単価マスタ・教育コスト記録(画面⑤「教育コストと人件費」の基盤)
--
-- ユーザー決定(2026-09-02、goto-twin諮問): 個人別の時間単価(給与相当)は
-- 本番DBへ載せない。役割別の既定単価のみ。member_id は持たない。
--
-- 本番の閲覧・編集制限(仕様書C5「事務局以外に開放されない」)について:
-- 本アプリは現時点でSSO/個人単位のログインが無く(next.config.tsのコメント
-- 「社内・ローカル限定の閲覧アプリ。SSOはまだ無い」の通り)、テナント単位の
-- 共有セッション1本で動いている。個人を識別できないため、役割ベースの
-- アクセス制御はアプリ層で技術的に実現できない(既存の全画面と同じ制約)。
-- 個人別給与ではなく役割別の集計値に留めたのは、この制約を踏まえた上での
-- リスク低減策(2026-09-02の決定)。

CREATE TABLE app.rate_master (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  role          text NOT NULL,                     -- 講師/教材作成/受講者/既定 等。自由入力
  hourly_rate   numeric(10,2) NOT NULL CHECK (hourly_rate >= 0 AND hourly_rate <> 'NaN'::numeric),
  effective_from date NOT NULL,
  source_note   text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  -- 同じroleに同じeffective_fromで複数行を持たせない(単価の一意性)。
  -- 改定時は新しいeffective_fromの行を追加する(追記型、既存行は書き換えない)。
  UNIQUE (tenant_id, role, effective_from)
);

CREATE TABLE app.education_records (
  id                uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL,
  program_name      text NOT NULL,
  role              text NOT NULL,                  -- rate_master.role と突き合わせて単価を引く
  member_id         uuid,                            -- 任意。個人を記録したい場合のみ
  hours             numeric(6,2) NOT NULL CHECK (hours > 0 AND hours <> 'NaN'::numeric),
  conducted_on      date NOT NULL,
  related_measure_id uuid,
  source_note       text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, member_id) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, related_measure_id) REFERENCES app.measures(tenant_id, id)
);

COMMENT ON TABLE app.rate_master IS '役割別の既定時間単価。個人別給与は持たない(2026-09-02決定)';
COMMENT ON TABLE app.education_records IS '教育プログラムの工数記録。role経由でrate_masterと突き合わせて人件費コストを算出する';

-- 0015のRLS一括適用は0015実行時点の既存テーブルにしか効かない。0016以降に
-- 作る新規テーブルは、0027等の既存パターンに倣ってここで個別に設定する
-- (設定を忘れるとテナント越境の欠陥になる。ローカル検証で実測して発見)。
DO $$
DECLARE
  t text;
  tables constant text[] := ARRAY['rate_master','education_records'];
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
