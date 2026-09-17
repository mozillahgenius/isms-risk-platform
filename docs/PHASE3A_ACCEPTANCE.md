# Phase 3a 受入（macOS 端末エージェント）

## 対象

- macOS の固定 14 項目 allowlist と、実行時の任意 SQL 拒否
- Go 製 thin agent `isms-agent`（v2 固定 Native runner、fixture runner、Ed25519 posture 署名）
- 一回限り enrollment token、device 公開鍵登録、`devices` / `device_snapshots` への取り込み
- payload の canonical JSON、definition version/hash、署名検証、ローカル可読ログ（0600）
- API と DB 間の HMAC 証票（`ISMS_AGENT_INGEST_SECRET`）により、`app_rw` から署名検証を迂回した直接挿入を拒否
- 端末 D チェック 10 本（設計書 Part VI: EP-001〜EP-010）
- 改変・再送・token 再利用が落ちることを確認する逆向き検証

## 収集 allowlist

定義の正本は [`agent/internal/definition/v2.json`](../agent/internal/definition/v2.json)。v1 は履歴として非activeで保持し、収集するのは次の 14 項目だけ。`edr_vendor` と `builtin_protection` は別々の証跡として保持する。

v2では各itemに `collector` と固定 `commands` を持たせる。Nativeは絶対パスの実行ファイルとargv配列を `exec.CommandContext` で直接起動し、shell展開・任意SQL・サーバーからの任意コマンド受信は行わない。出力ストリームも定義の `output` で固定する。`off_premise` は明示的に `metadata` collector として enrollment属性だけを使用する。

方式比較の実測では、到達可能な3台（このMac、managed-device-02、managed-device-user-05）で `osqueryi` は未導入、Native候補の固定コマンドは実行可能だったため、v2ではNativeを採用した。未到達端末は配布後のcanary/full-fleet検証で別途確認する。

`disk_encrypted`、`screen_lock`、`os_version`、`patch_current`、`auto_update_checks_enabled`、
`firewall_enabled`、`edr_running`、`edr_vendor`、`builtin_protection`、
`admin_account_count`、`password_manager_installed`、`unapproved_apps`（名前のみ）、
`device_identity`、`off_premise`（enrollment 属性）。

`builtin_protection` はXProtectの稼働プロセス数、XProtect.bundle版、XProtect.app/Remediator版、
`spctl --status`、`csrutil status`、`systemextensionsctl list`を保持する。CHK-ENDPOINT-003は、
商用EDRの`edr_vendor`（`ps`で得たPIDをkernel-backed `proc_pidpath`で解決した実行ファイル絶対パスが定義側allowlistに一致）または、全項目が揃った有効な`builtin_protection`のいずれかで満たす。プロセス名やコマンドライン引数だけでは満たさない。
有効なbuiltin protectionは、v2定義の`promotes_to=["edr_running"]`に従って集約項目
`edr_running=true`にも反映する。`edr_vendor="none"`は商用EDR未導入の事実として残し、
`builtin_protection`と混同しない。

`auto_update_checks_enabled` は `softwareupdate --schedule` の「自動更新チェック」の状態であり、
自動ダウンロード・自動インストールの有効性を意味しない。CHK-ENDPOINT-007もこの題意で評価する。

`unapproved_apps` の母集団は定義側の `location_prefixes=["/Applications"]`、
`location_depth=1` に固定し、`/System/Applications` と `~/Applications` は
`excluded_location_prefixes` で除外する。承認リストは別の業務判断であり、母集団を
狭めるためには使わない。`application_inventory=system_profiler_and_directory` により
`system_profiler` と `/usr/bin/find` のディレクトリ列挙を突合し、差分は黙って捨てない。
差分は署名証跡に残り、CHK-ENDPOINT-009を違反扱いにする。`include_hidden_bundles=true` で `/Applications` 直下のドット始まり
`.app` も母集団に含める。実測候補と差分は [`ENDPOINT_009_APPLICATION_CANDIDATES_20260816.md`](ENDPOINT_009_APPLICATION_CANDIDATES_20260816.md) に残す。

`admin_account_count` のシステムアカウント除外も `admin_exclusions` として定義側に保持し、
collector実装へアカウント名を埋め込まない。`root` と `_` 始まりだけを除外し、実在する
`remoteaccess` は数える。許容する場合はユーザー承認と根拠を得てから定義を更新する。

ファイル内容・ファイル名一覧・ブラウザ履歴・キー入力・clipboard・画面キャプチャ・位置情報・
常時 process 監視・アプリ利用時間・メール/チャット本文は契約に含めず、コードにも実装していない。

## 実行

```sh
make agent-test
make ci
```

`make agent-test` は隔離 DB と web API の production build を使い、次を通す。

1. 固定定義の query 改変、canonical JSON、署名 payload 改変を Go テストで拒否する
2. enrollment → fixture collect → posture ingest を通す
3. 同一 raw hash の再送で `device_snapshots` が増えない
4. 署名 payload の改変を HTTP 401、使用済み enrollment token を拒否する
5. ローカル posture log と秘密鍵が 0600 で作られる
6. definition endpoint がサーバー Ed25519 署名と署名者公開鍵を返し、DB 関数の偽 HMAC 証票を拒否する

`make ci` では D チェック 10 本それぞれについて、違反が無い状態を確認した後、negative fixture で違反が発生することを確認する。
通常の checker 実行は core 4 + Phase 2 6 + Phase 3a 10 の計 20 本を `negative_verified` 付きで pass にする。

CHK-ENDPOINT-001〜009 は `device_id` ごとに
`collected_at DESC, id DESC` で最新の1 snapshotだけを選ぶ。古い違反snapshotを
二重計上せず、最新snapshotが違反している場合も1 device 1 violationとして保持する。
CIのseed検査は、この `DISTINCT ON` と決定的な降順タイブレークを確認する。

## 未実装・人の確認が必要な範囲

- Windows MSI（Phase 3b）、notarized pkg、MDM 配布、常駐 launchd 化
- サーバー配布方式へのdefinition API署名鍵の本番注入
- Google Workspace/OAuth の実接続、SSO、業務データ向け REST API、スケジューラ、通知
- PostgreSQL 16 での検証（CI は PostgreSQL 17。Docker が利用可能な環境で別途実施）
- 実顧客・従業員データを使ったプライバシー/労務レビュー、署名鍵の本番保管・ローテーション

API 起動時は `ISMS_AGENT_INGEST_SECRET`（64 桁 hex）と、definition 署名用の
`ISMS_AGENT_DEFINITION_PRIVATE_KEY_B64`（PKCS#8 DER の base64）を秘密管理基盤から注入する。
