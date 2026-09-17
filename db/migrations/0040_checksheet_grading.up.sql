-- 0040 app: チェックシート自動採点の受け皿(画面④)
--
-- ユーザー決定(2026-09-02): LLM呼び出し自体は今回実装しない(0039の
-- competency_summariesと同じ方針、将来ローカルLLM導入時に実装)。
-- アップロード受付・設問ごとの判定結果を保存するスキーマのみ用意する。
--
-- アップロードファイルに個人情報が含まれうる件(仕様書の未決事項)を踏まえ、
-- ファイル本体は保存しない。file_refは外部の保管場所への参照のみとする。
--
-- 0037以降と同じ理由でRLSはここで個別設定する。

CREATE TABLE app.checksheet_submissions (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  uploaded_at   timestamptz NOT NULL DEFAULT now(),
  uploaded_by   uuid,
  -- ファイル本体は保存しない。外部の保管場所(Drive等)への参照のみ
  -- (未決事項: アップロードファイルの個人情報取り扱いが未確定のため)。
  -- 空文字禁止まではCHECKで縛るが、「本当に参照であって本体そのもの
  -- (Base64等)ではないか」の形式検証はアプリ層の役割(アップロード機能を
  -- 実装する際に併せて実装する。Codexレビュー2026-09-02指摘: DB制約だけ
  -- では規約止まりであることを明記)。
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
  -- LLM判定。生成ロジック未実装のため当面は常にNULL。
  llm_judgement  text CHECK (llm_judgement IS NULL OR llm_judgement IN ('適合','要確認','不適合')),
  confidence     numeric(4,3) CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1 AND confidence <> 'NaN'::numeric)),
  raw_llm_output text,                      -- 監査証跡(仕様書C4)。生成ロジック未実装のため当面NULL
  -- 受入条件C3「人が確認・修正できる導線」。LLM判定と人による最終判断を
  -- 分けて持つ(0039のconfirmed_by/atと同じ「確認者不明の確認済み状態を
  -- 作らない」設計をhuman_judgementにも適用する)。
  human_judgement text CHECK (human_judgement IS NULL OR human_judgement IN ('適合','要確認','不適合')),
  reviewed_by    uuid,
  reviewed_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, submission_id) REFERENCES app.checksheet_submissions(tenant_id, id),
  FOREIGN KEY (tenant_id, reviewed_by) REFERENCES app.users(tenant_id, id),
  CHECK ((reviewed_by IS NULL) = (reviewed_at IS NULL)),
  -- human_judgementを人が記入した場合は、誰がいつ確認したかを必ず伴う
  -- (0039のCHECK制約の抜け穴指摘を踏まえ、最初から両方向を縛る)。
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
