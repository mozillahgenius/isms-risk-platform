# Phase 2 受入（コネクタ基盤）

## 対象

- Google Workspace `reader` マニフェスト v3
- 記録済みレスポンスの再生（実 API には接続しない）
- 正規化ポスチャグラフ（accounts / groups / resources / grants / OAuth / raw_events）
- 同期状態 `collected` / `unreadable` / `gone` / `not_collected` と coverage
- Phase 2 の代表チェック A/B/C/F/G（6 本）と finding の `detected` → `retest_passed` 遷移

## 実行

```sh
make ci
make connector-test
```

`make ci` は空 DB への全 migration、up→down→up、RLS、seed の冪等性（統制304 / リスク雛形196 / チェック20 / コネクタ1）、既存 checker を検証する。Phase 2 の受入結果はこのうちコネクタ基盤と A/B/C/F/G 6 本に関するもの。

`make connector-test` は次を検証する。

1. fixture の SHA-256 が改変を拒否する
2. 実 API なしで Google Workspace の応答を正規化する
3. 資源別の `unreadable` / `gone` を記録する
4. Drive permission の coverage `0.500` を記録する
5. 同じ fixture を二度流しても正規化グラフの件数が変わらない

対象テナントを作成した後の再生は次のように行う。

```sh
make tenant NAME="検証用" DOMAIN="example.invalid" \
  EMAIL="admin@example.invalid" ADMIN="管理者"
ISMS_DB=isms_dev python3 scripts/connector_sync.py --token "$TOKEN"
ISMS_DB=isms_dev python3 scripts/checker.py --token "$TOKEN"
```

fixture は `fixtures/google_workspace/replay-basic.json` とその `.sha256` が一組で、変更時は SHA-256 を更新してレビューを通す。実 API の認証情報はこのリポジトリや fixture に置かない。

## 人の確認が必要な範囲

- 外部 API への実接続（Google Workspace の認証情報・スコープ・組織承認）
- PostgreSQL 16 の実行（この Mac は PostgreSQL 17）
- 実データでの公開ファイル検知と finding の内容確認
