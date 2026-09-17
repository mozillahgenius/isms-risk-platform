# SaaS コネクト型 リスク分析・管理プラットフォーム

詳細設計書 v2.0 の実装。

> **正本**: `ISMS-リスク管理プラットフォーム_詳細設計書_v2.0.md`（Drive「claudecode work /
> 2026-08-13_ISMSリスク管理プラットフォーム設計」）。矛盾したら設計書が優先する。
> ただし設計書のとおりでは設計書自身の受入条件を満たさない箇所が 11 件あり、
> 逸脱として [`docs/DECISIONS.md`](docs/DECISIONS.md) に理由付きで記録してある。

## 現在地

| フェーズ | 内容 | 状態 |
|---|---|---|
| Phase 0 | 既存 Excel の取り込みと再出力 | **受入合格**（差分 0 件・逆向き検証つき） |
| Phase 1 | DOM ＋ 台帳 ＋ 履歴 ＋ テナント分離 | DB 基盤は完成。受入 16 項目のうち 8 項目が自動テスト済み。内訳は [`docs/PHASE1_ACCEPTANCE.md`](docs/PHASE1_ACCEPTANCE.md) |
| Phase 2 | Google Workspace reader／正規化／チェック A/B/C/F/G | **受入合格**（記録済み応答の再生） |
| Phase 3a | macOS 端末エージェント／署名 posture／D チェック | **受入合格**（fixture・逆向き検証・API 取り込み） |
| Phase 3b | Windows エージェント／端末登録・配布・有効化 | 実装済み（fixture・単体検証） |
| 画面（web/） | ルールを読むだけのブラウザ（図・一覧・出所） | **動く**。Mac のローカル PostgreSQL に対して `make web` |
| チェック機能（checker） | 標準チェックの実行と、落ちることの確認 | **動く**。`make tenant` → `make checker`。core 4 本＋Phase 2 6 本＋Phase 3a D 10 本 |

**まだ無いもの**: 業務データ向け REST API・SSO・外部 API の実接続・スケジューラ・通知。
Phase 3a の端末 enrollment / posture 取り込み API は [`docs/PHASE3A_ACCEPTANCE.md`](docs/PHASE3A_ACCEPTANCE.md) の範囲で実装済み。
運用データの画面はチェックの結果に加えて、リスク台帳の実測件数と既存画面への導線、統制の実施状況の現行記録・状態別件数・証跡件数を表示する。
統制の実施記録が無い場合は 0 件と明示し、テナント文脈が無い場合は 0 件にせず読めない状態を表示する。逸脱は未実装。

## 構成

> **適用済みの migration は書き換えない。** `migrate.sh` が up / down 双方の
> SHA-256 を突合するので、配備済みの環境では書き換えが必ず落ちる。修正は新しい番号で足す。
> 0001〜0015 はまだ配備先が無いため直接修正してきたが、最初の実配備で凍結する（[D-16](docs/DECISIONS.md)）。

```
db/migrations/   0001〜0083。設計書 2.2 の適用順＋Phase 2/3a/3b 拡張。up と down が対
db/seeds/        catalog（DOM 2026.1・標準チェック）と既存 CSV マスタの投入、出所の記録
scripts/         migrate.sh（適用・巻き戻し）、ci/（品質ゲート）
phase0/          xlsx → DB → xlsx の往復と機械 diff。正規化規則は NORMALIZATION.md
tests/           受入条件を実ロール接続で確かめるテスト
web/             ルールを読む画面（Next.js）。読み取り専用ロールで catalog だけを見る
docs/            設計書からの逸脱（DECISIONS.md）と受入トレーサビリティ
```

## 前提

- PostgreSQL 16 以上。**この機は Docker が無いため 17 でのみ検証している**（[D-11](docs/DECISIONS.md)）
- 拡張 `pgcrypto` / `btree_gist` / `citext`
- Python 3.12 以上 ＋ `openpyxl`（DB は `psql` 経由で触るのでドライバは要らない）

`docker-compose.yml` は設計書 11.2 の配備構成。ローカルの PostgreSQL に対しては
`make db-reset` で同じスキーマを作れる。

## 既存資産の再利用（設計書 Part XIII）

帳票生成は 1 行も書き直さない。外部で管理する `build_risk_map.py` /
`build_control_karte.py` を**無改変で**呼ぶ。

- 参照先は `RISK_MAP_SCRIPTS_DIR`（未設定時は Phase 0 を SKIP）
- 4 ファイルのハッシュを `scripts/ci/reused_assets.sha256` に固定し、CI が突合する。
  **上流が変わったら CI が落ちる**（黙って挙動が変わらないようにする）

## 使い方

```bash
make db-reset   # 空 DB を作り直して 0001〜0025 を適用
make seed       # DOM 2026.1 ＋ 同梱の架空サンプルCSV ＋ 出所の記録
make test       # テナント分離・ドメイン制約（使い捨て DB。isms_dev は汚さない → D-28）
make phase0     # Phase 0 の受入（差分 0 件）
make ci         # 品質ゲート一式（設計書 11.5 のうち実装済みのもの）
make connector-test # Google Workspace reader の記録済みレスポンス再生受入
```

## チェック機能（checker）

統制が効いているかを機械で確かめる。**合格と数える前に、壊して落ちることを確かめる。**

```bash
make tenant NAME="自社" DOMAIN=example.com EMAIL=admin@example.com ADMIN="管理者"
make checker TOKEN=<上で出たトークン>
make checker-test          # 受入（隔離 DB で通しに確かめる）
```

- チェックは `catalog.checks`。いま入っているのは **core 4 本＋Phase 2 の 6 本＋Phase 3a の D 10 本**。
  全 66 本のうち Windows・クラウド/コード・追加の運用/証跡チェックは後続 Phase で実装する
- `query_sql` は**違反している行**を返す SELECT。`expect` は `{"max_violations": N}`（[D-22](docs/DECISIONS.md)）
- 実行は **`app_ro`（読み取り専用）** ＋テナント文脈。カタログの SQL を書ける接続では実行しない
- **`negative_fixture` は対象の DB で流さない。** 毎回使い捨ての DB を作ってそこで確かめる（[D-24](docs/DECISIONS.md)）
- **確かめていないチェックは `pass` として記録できない。** DB が拒否する（[D-23](docs/DECISIONS.md)）。
  でたらめな指紋も、確認後に中身を書き換えた場合も通らない（[D-27](docs/DECISIONS.md)）。
  ただし **「fixture を本当に流したか」は DB からは見えない**。そこは実行側の仕事

確認は 2 段構えで、両方そろって初めて「確認済み」とする。

1. 何もしない状態で違反が 0 件（前提が成立している）
2. `negative_fixture` を入れると違反が出る（検査が働く）

接続先は `DATABASE_URL`（既定 `postgres:///isms_dev`）。
`ISMS_DB` にデータベース名だけを渡すこともできる。CI は `ISMS_CI_DB`（既定 `isms_ci`）を作り直す。

## 画面（web/）

ルールを**読むだけ**の画面。Mac の上でそのまま動く（Docker は要らない）。

```bash
make db-reset && make seed   # まだなら
make web                     # http://127.0.0.1:3100
make web-check               # 型検査・lint・単体テスト・ビルド
make web-verify              # 上に加えて外形検査（下記）
```

`make web-verify` は **壊した状態で実際に落ちること**まで見る。

Phase 2 の受入条件と証跡は [`docs/PHASE2_ACCEPTANCE.md`](docs/PHASE2_ACCEPTANCE.md)、
Phase 3a の受入条件と証跡は [`docs/PHASE3A_ACCEPTANCE.md`](docs/PHASE3A_ACCEPTANCE.md) を参照。

- 主要ページが 200 で、画面の件数が DB の実測と一致する
- 壊れた ID・存在しない ID が **404**（500 や 307 ではない）
- **seed していない隔離 DB** に対して 0 件と「未投入」を出す
- **分類の無い統制（`theme` が NULL）が在る隔離 DB** で、図と詳細が 200・件数が一致し、
  空欄ではなく「分類なし」と出る（[D-29](docs/DECISIONS.md)）
- **届かない接続先**で 500 になる（0 件の顔で誤魔化さない）

`isms_dev` を空にしたり PostgreSQL を止めたりはしない。隔離した DB と届かないポートを使う。

- 接続は **`app_ro`（catalog へ SELECT のみ）**。加えて接続時に `default_transaction_read_only`
  を立てるので、書こうとした時点で落ちる（[D-21](docs/DECISIONS.md)）
- 待ち受けは **127.0.0.1 に固定**。まだ認証（SSO）が無いため LAN に出さない
- 接続先は `web/.env.local` の `ISMS_WEB_DATABASE_URL`（既定 `postgres:///isms_dev?user=app_ro`）
- 運用データを見るには `ISMS_WEB_TENANT_TOKEN`（`make tenant` が出すトークン）を
  **サーバ側の env にだけ**置く。無ければ運用ページは「読める状態にない」と出す。
- eラーニング受講実績を「教育・訓練」へ同期するには、サーバ側に
  `ELEARNING_COMPLETIONS_URL` と `ELEARNING_MANAGEMENT_SYNC_TOKEN`（32文字以上）を置く。
  対象は eラーニング側で `isms` または `risk-management` タグが付いた完了講座だけ。
  文脈は 1 リクエスト＝1 トランザクションで確立する（接続プールでは別接続に流れて消えるため）
- Web 書き込みは共有トークンの利用者を実行者にしない。oauth2-proxy が渡す
  `x-forwarded-email` と、既存の秘密ヘッダ `x-ib-device-control-proxy-secret`
  （`ISMS_DEVICE_CONTROL_PROXY_SECRET` と一致）を組み合わせ、同じテナントの有効な利用者へ
  DB セッションを束縛する。どちらかが欠ければ fail-closed とする。
  本人性の束縛RPCは専用DB login `management_web` のみに許可し、一般の `app_rw` / `app_ro`
  からは実行できない。配備時に `ISMS_PROXY_DATABASE_URL` をowner-only環境ファイルへ生成する。
- ローカルE2Eで共有トークン利用者として書く必要がある場合だけ、非本番環境で
  `ISMS_WEB_ALLOW_SHARED_WRITE_ACTOR=true` を明示する。本番ではこの設定を無視する。

見られるもの:

| 画面 | 中身 |
|---|---|
| 図で見る | 階層ピラミッド（2.5D / 3D / WebGL）と関連グラフ。ノードをクリックすると該当ページへ |
| 統制 / リスク | 同梱サンプル。検索・絞り込み・ページング・詳細 |
| 規程 / リスク基準 / 体制・分類 / 年間カレンダー / フレームワーク | DOM が定めるもの |
| 運用 | テナントの概要とチェックの最新結果。トークンが無ければ「読める状態にない」と出す |

**図の読み方**: 辺には 2 種類ある。**実関係**（`framework_key` や `owner_role` のように列に
そのまま在るもの）と、**導出**（`theme` / `domain` の文字列を割って作ったもの）。
hover でどちらか分かり、件数も分けて出る。白抜きのノードは DB の行ではない見出し。
関連テーブルは実測 0 件なので、いま線の大半は導出（[D-19](docs/DECISIONS.md)）。

**ルールの正本は Git**、DB はその投影。統制とリスク雛形の CSV は
外部カタログソースにあり、このリポジトリへは取り込まない（[D-17](docs/DECISIONS.md)）。
各画面の「出所」は `catalog.seed_provenance` の実測（リポジトリ・commit・SHA-256・件数）を
読んでいて、画面に書いた固定文字列ではない（[D-18](docs/DECISIONS.md)）。

図の描画（`GraphCanvas` / `PyramidCanvas` / `Pyramid3D` / `pyramidLayout`）は
Kaname の実装をそのまま移植した。改変したのは接続部だけ（テーマイベント名、
ノードのリンク先、語彙）。

## テナント文脈の使い方（重要）

`app.tenant_id` の GUC は署名つきで、`app_rw` が自分で `SET` しても通らない。
**必ず同一トランザクションで**次の順に呼ぶ。

```sql
BEGIN;
SELECT app.set_tenant_context('<セッショントークン>');
-- ここで業務クエリ
COMMIT;
```

`set_config(..., true)` は `SET LOCAL` 相当なので、トランザクションが終わると文脈は消える
（接続プールへ返しても残らない）。autocommit で `set_tenant_context()` だけ呼んでも
次の文には残らない。詳細と「証明できる性質の範囲」は [D-01](docs/DECISIONS.md)。
