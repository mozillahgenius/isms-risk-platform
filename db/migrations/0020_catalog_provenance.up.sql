-- 0020 カタログの出所（provenance）。
--
-- なぜ要るか:
--   画面に「このルールはどこから来たか」を出すとき、固定文字列を埋め込むと嘘になる。
--   実際 catalog.controls / catalog.risk_scenario_templates には出所の列が無く、
--   304 件・196 件が DOM 2026.1 に属することも DB 上では証明できなかった。
--   投入した側（seed）が、投入時に「どのリポジトリのどの commit のどのファイルを、
--   どのハッシュで、何件読んだか」を書き残す。画面はここだけを見る。
--
-- 正本の所在（2026-08-13 時点の実測）:
--   - DOM 2026.1 の定義        … このリポジトリ db/seeds/0001_dom_2026_1.sql
--   - 統制 / リスクテンプレ … 設定された外部カタログの CSV
--   どちらも Git が正本で、DB は投影。二重に持つと片方が古くなるので取り込まない。
--   上流 CSV の改変検知は scripts/ci/check_reused_assets.sh のハッシュ突合が担う。

SET ROLE schema_owner;

CREATE TABLE catalog.seed_provenance (
  -- 投入対象の論理名。1 対象につき最新の 1 行だけを保つ（履歴は audit ではなくここでは持たない）。
  target          text PRIMARY KEY
                  CHECK (target IN ('dom', 'controls', 'risk_scenario_templates')),
  -- 正本の所在。source_repo は URL ではなく owner/name（表示の一貫性のため）。
  source_repo     text NOT NULL CHECK (source_repo <> ''),
  -- 正本の commit。取得できなかった場合は NULL（空文字で「有る」ように見せない）。
  source_commit   text CHECK (source_commit IS NULL OR source_commit ~ '^[0-9a-f]{7,40}$'),
  -- リポジトリルートからの相対パス。絶対パスを書かない（機ごとに変わるため）。
  source_path     text NOT NULL CHECK (source_path <> '' AND source_path !~ '^/'),
  -- 投入したファイルの SHA-256。scripts/ci/reused_assets.sha256 と突合できる。
  source_sha256   text NOT NULL CHECK (source_sha256 ~ '^[0-9a-f]{64}$'),
  -- どの DOM 版として投入したか。
  dom_version_id  uuid NOT NULL REFERENCES catalog.dom_versions(id),
  -- 投入時点で読み込んだ行数。画面の件数と突合し、ズレたら投入が古いと分かる。
  row_count       integer NOT NULL CHECK (row_count >= 0),
  -- 投入したもの（ファイル名）。人が追える形にする。
  loader          text NOT NULL CHECK (loader <> ''),
  loaded_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE catalog.seed_provenance IS
  'カタログ各対象の正本（Git）の所在と投入時の実測。画面の出所表示はここだけを読む。';

-- catalog は読み取り専用（設計書 2.1）。0015 と同じ方針で app_rw / app_ro へ SELECT のみ。
GRANT SELECT ON catalog.seed_provenance TO app_rw, app_ro;

RESET ROLE;
