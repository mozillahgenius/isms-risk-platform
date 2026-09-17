# Phase 1 受入条件のトレーサビリティ

設計書 Part XII の受入 16 項目について、**何で検証しているか**と**現状**を対応付ける。

> 「エラーが出なかった」「ファイルが生成された」を根拠に完了としない（設計書 Part XII 冒頭）。
> 自動テストが無い項目は **未実装** と書く。書かないより、書いて残す。

凡例: ✅ 自動テストあり ／ ⚠️ 一部のみ ／ ❌ 未実装

| # | 受入条件 | 検証手段 | 現状 |
|---|---|---|---|
| 1 | テナント作成直後、何も設定せずに標準規程 12 本・標準統制・標準チェック 66 本・標準カレンダーが有効 | `scripts/ci/check_seeds.sql`（規程 12・カレンダー 14・ロール 5・資産分類 4・統制 304）＋ `tests/checker_test.sh`（`app.provision_tenant()` が標準規程 12 本を展開することを実測）。標準チェックは **66 本ではなく core 4 本**（[D-26](DECISIONS.md)）。カレンダーからのタスク自動生成は未実装 | ⚠️ |
| 2 | 標準チェックを無効化しようとすると、理由・代替統制・承認者・期限なしでは登録できない | `tests/domain_test.sh`「理由なしの逸脱」「代替統制なし」「承認者・期限なしで active」 | ✅ |
| 3 | 逸脱の期限を 180 日超で登録しようとすると拒否される | `tests/domain_test.sh`「期限が 180 日を超えると拒否」 | ✅ |
| 4 | 期限切れの逸脱が翌日 `expired` へ落ち、標準が自動的に再適用される | `tests/domain_test.sh`「expire_deviations で expired になり標準へ戻る」（`effective_risk_criteria.is_deviated` が false へ戻ることまで確認）。**日次スケジューラは未実装** | ⚠️ |
| 5 | 監査ログのハッシュチェーン検証が緑。かつ 1 行改ざんしたコピーで検証が赤になる | `tests/domain_test.sh`「チェーン検証が緑」「1 行改ざんで赤（逆向き検証）」 | ✅ |
| 6 | アプリロールで `audit_log` の UPDATE／DELETE が拒否され、アプリロールが所有者でも `BYPASSRLS` でもない | `tests/rls_test.sh`（UPDATE / DELETE の拒否）＋ `scripts/ci/check_rls.sql` 検査 4・6 | ✅ |
| 7 | `set_tenant_context()` を経由せず `app.tenant_id` を直接設定した接続がテナントデータへ到達できない | `tests/rls_test.sh`（署名なし SET／他テナントへ差し替え／偽トークン／短いトークン）。証明できる性質の範囲と残余リスクは [D-01](DECISIONS.md) | ✅ |
| 8 | 接続プール返却後の再利用で前リクエストのテナント文脈が残らない | `tests/rls_test.sh`（COMMIT 後／autocommit／ROLLBACK 後にいずれも文脈なし）。**PgBouncer 実機での確認は未実施** | ⚠️ |
| 9 | テナント A の資格情報でテナント B へ SELECT/INSERT/UPDATE/DELETE を試み、DB 層で全て拒否 | `tests/rls_test.sh`（`app_rw` の実接続で 4 操作すべて）。superuser では実行しない | ✅ |
| 10 | 任意の過去時点のリスクマップを再現でき、現在版との差分が出る | bitemporal 列（`valid_from/to`・`recorded_from/until`）と排他制約は実装済み。**as-of 再現クエリと差分出力は未実装** | ❌ |
| 11 | SoA が出力され、除外統制に理由が無い場合は出力がブロックされる | `tests/domain_test.sh`「除外に理由が無ければ登録できない」（DB 制約）。**SoA の出力そのものは未実装** | ⚠️ |
| 12 | 同一サイクル内で 残存 > 固有 の入力が拒否され、再評価での上昇は理由必須で通る | `tests/domain_test.sh` 3 件。設計書の実装では検査が素通りしていた（[D-04](DECISIONS.md)） | ✅ |
| 13 | `impact_sec` が算定式と一致しない値で投入されると DB が拒否する | `tests/domain_test.sh`「算定式と食い違う impact_sec は拒否」 | ✅ |
| 14 | 監査人ロールを他ロールと兼任させようとすると DB が拒否する | `tests/rls_test.sh`「監査人と他ロールの兼任を DB が拒否」 | ✅ |
| 15 | エクスポートで `scale` を省略すると 400。出力 xlsx に使用尺度・基準版・DOM 版が注記される | `phase0/export_xlsx.py` は `--scale` 必須（省略でエラー）。**REST API は未実装**。**xlsx への注記出力も未実装**（`app.export_runs` テーブルごと未作成） | ⚠️ |
| 16 | 復元演習が四半期スケジュールとして登録され、初回の演習結果が証跡として保存されている | `scripts/ci/check_seeds.sql` が `quarterly_restore` の登録を検査。**演習の実施と証跡保存は未実施** | ⚠️ |

## SQL だけでは完了扱いにできないもの

次は DB の検査では成立しない。実装していないことを明示する。

- Google Workspace SSO（OIDC）とログイン導線
- 画面上の承認フロー・権限制御（Part X の画面と REST API は未着手）
- 通知（Part X 10.4）
- 標準カレンダーからのタスク自動生成と、日次・四半期のスケジューラ実行
- xlsx の視覚的整合性（書式・注記）
- 性能、同時実行、PgBouncer 実機でのテナント文脈
- 証跡ファイルの保存（MinIO / オブジェクトストレージ）

## 設計書 11.5 の品質ゲートの実装状況

| ゲート | 実装 | 現状 |
|---|---|---|
| マイグレーション検証（空 DB へ適用＋ロールバック） | `scripts/ci/run.sh` 工程 2・4 | ✅ sentinel オブジェクトの保全まで確認 |
| RLS 網羅 | `scripts/ci/check_rls.sql` 検査 1〜3 | ✅ 壊して落ちることも確認済み |
| RLS テスト（越境の全経路） | `tests/rls_test.sh` | ⚠️ DB 経路のみ。ワーカー・帳票・エクスポート・署名 URL は未実装 |
| チェックの逆向き検証 | `tests/checker_test.sh`（CI 工程 9）＋ `app.check_runs` の制約 | ✅ core 4 本。**確かめていないチェックは pass として記録できない**（[D-23](DECISIONS.md)）。設計書の 66 本はコネクタ待ち（[D-26](DECISIONS.md)） |
| コネクタのスコープ検証 | — | ❌ Phase 2 |
| エージェント定義の突合 | — | ❌ Phase 3 |
| 監査ログの改ざん検知テスト | `tests/domain_test.sh` | ✅ |
| 帳票の回帰（xlsx 投入→再出力→機械 diff で差分 0） | `phase0/run_acceptance.sh` | ✅ 差分 0 件。壊した出力で落ちることも確認 |

## 実行環境の但し書き

設計書 11.1 は PostgreSQL 16 前提だが、**この機には Docker が無く PostgreSQL 17 でのみ検証している**。
PG16 での実行は未実施。
