-- 0024 コネクタの正規化先で、設計書に**無かった**ものを足す。
--
-- 見つかった経緯:
--   マニフェスト検証（scripts/validate_manifests.py）に「全 resource の map_to は
--   着地先を持たねばならない」という規則を入れたところ、設計書 3.2 の
--   google_workspace マニフェスト v3 に、着地先の無い写像が 2 つあった。
--
--   1. groups の `email: email` … 設計書 2.6 の app.groups に email 列が無い。
--      Drive の permission はグループを `emailAddress` で指すので、
--      **email が無いとグループ宛の権限をグループ行へ解決できない**。
--      「グループ経由でのみ到達できる公開を検知する」（Phase 2 受入 #3）が成立しない。
--
--   2. admin_reports_login の `map_to: raw_events` … `raw_events` という表が
--      設計書のどこにも定義されていない。ログイン監査の着地先が無い。
--
--   どちらも「マニフェストには書いてあるが入れる場所が無い」状態だった。
--   検証を入れるまで気づかない類の穴なので、着地先を作り、検証で維持する。
--
-- ここでは**表と列を用意するだけ**で、書き込む実装（同期エンジン）は Phase 2B。
-- 空であることは画面が「未投入」として正直に出す。

SET ROLE schema_owner;

-- 1. グループのメールアドレス --------------------------------------------------
-- 一次キーは external_id のまま（メールは変わり得る）。email は解決の手がかり。
ALTER TABLE app.groups ADD COLUMN email citext;

-- 同じテナント・同じコネクタで同じメールのグループは 1 つ。
-- NULL は重複してよい（未取得のグループが複数在り得る）。
CREATE UNIQUE INDEX groups_email_unique
  ON app.groups (tenant_id, connector, email) WHERE email IS NOT NULL;

COMMENT ON COLUMN app.groups.email IS
  'グループのメール。Drive の permission が emailAddress でグループを指すため解決に要る。一次キーは external_id。';

-- 2. 生イベント（ログイン監査など）--------------------------------------------
-- 正規化グラフのノード・エッジに落ちない時系列の記録。**追記のみ**。
CREATE TABLE app.raw_events (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  connector     text NOT NULL,
  resource_name text NOT NULL,              -- マニフェストの resources[].name
  external_id   text NOT NULL,              -- 提供元のイベント ID（冪等性の鍵）
  occurred_at   timestamptz NOT NULL,
  event_type    text NOT NULL,
  actor_email   citext,                     -- 名寄せ前。account への解決は正規化側の仕事
  -- 提供元固有の中身はここへ隔離する（列を増やして SaaS ごとに分岐させない）
  attributes    jsonb NOT NULL DEFAULT '{}',
  collection_state text NOT NULL DEFAULT 'collected'
                  CHECK (collection_state IN ('collected','unreadable','gone','not_collected')),
  collected_at  timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  -- 同じ実行を 2 回流しても増えない（設計書 3.5 の冪等性）
  UNIQUE (tenant_id, connector, external_id)
);
CREATE INDEX raw_events_recent
  ON app.raw_events (tenant_id, connector, occurred_at DESC);

-- RLS と権限。0015 と同じ生成規則を、この表にも同じ形で当てる。
-- **追記のみ**なので UPDATE / DELETE は与えない（device_snapshots / graph_events と同じ扱い）。
ALTER TABLE app.raw_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.raw_events FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON app.raw_events;
DROP POLICY IF EXISTS tenant_read      ON app.raw_events;
CREATE POLICY tenant_isolation ON app.raw_events FOR ALL TO app_rw
  USING (tenant_id = app.current_tenant())
  WITH CHECK (tenant_id = app.current_tenant());
CREATE POLICY tenant_read ON app.raw_events FOR SELECT TO app_ro
  USING (tenant_id = app.current_tenant());
REVOKE ALL ON app.raw_events FROM PUBLIC;
GRANT SELECT, INSERT ON app.raw_events TO app_rw;
GRANT SELECT ON app.raw_events TO app_ro;

COMMENT ON TABLE app.raw_events IS
  'ノード・エッジに落ちない時系列の記録（ログイン監査等）。追記のみ。書き込みは Phase 2B の同期エンジン。';

-- 3. 出所の対象に「コネクタマニフェスト」を足す ---------------------------------
-- マニフェストも Git が正本で DB は投影。統制やリスク雛形と同じく、
-- どのリポジトリのどの commit のどのファイルから入ったかを実測して記録する。
ALTER TABLE catalog.seed_provenance DROP CONSTRAINT seed_provenance_target_check;
ALTER TABLE catalog.seed_provenance
  ADD CONSTRAINT seed_provenance_target_check
  CHECK (target IN ('dom', 'controls', 'risk_scenario_templates', 'connector_manifests'));

RESET ROLE;
