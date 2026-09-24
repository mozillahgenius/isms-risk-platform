# 新しい組織へ導入する: 環境条件とセットアップ手順

この文書は、このシステムを新しい組織の環境へ導入するときに、**何を先に決め、何を揃え、どの順で入れ、何をもって完了とするか**をまとめたものです。

## なぜこの文書があるか

過去の導入では、次の順に 1 つずつ止まりました。どれも個別の不具合ではなく、**導入に必要な条件の一覧が無かった**ことが共通の原因です。特に、上流の `ops/` を「その環境固有の運用ファイル」として取り込まなかったとき、**そのファイルが担っていた要件（24 時間以内のセッション更新など）まで一緒に落ちました**。

| 止まった症状 | 原因 | この文書の該当箇所 |
|---|---|---|
| メンバーマスタに「テナントセッションまたは信頼済みの利用者識別が必要です」 | 操作者の本人識別を画面へ渡していない | 第1節「本人識別の渡し方」 |
| 同上、運用データ画面が 42501 | Web テナントセッション（最長 24 時間）の更新ジョブが無く、構築の翌日に失効。失敗通知も無く 7 日間気づかなかった | 第5節 |
| 招待リンク・エージェントの接続先が 404 | パス配下（basePath）で公開したのに、URL をホスト名だけで組んでいた | 第1節「公開形態」 |
| エージェントの登録開始が 403 | `ISMS_AGENT_LOGIN_ENROLLMENT_ENABLED` が未設定 | 第4節 |
| 招待メールが出ない | SMTP の資格情報と送信ジョブが無い | 第4節・第5節 |
| 端末の状態報告が 400 | `ISMS_AGENT_INGEST_SECRET` と DB 側の鍵が未設定 | 第4節 |

## 1. 第0工程: 設定より先に決めること

設定値を書き始める前に、次を決めてください。ここが決まっていないと、後の設定をいくら揃えても一部の画面が動きません。

- **公開形態**: ホスト直下で公開するか、既存アプリの下のパス（例: `/risk`）で公開するか。**同梱の実装はホスト直下での公開を前提にしています。** `web/src/lib/agentDistribution.ts` の `agentWebOrigin()` は `ISMS_WEB_BASE_URL` のパスを捨て、`web/src/lib/managementEnrollment.ts` の `managementAgentOrigin()` はパス付きの値を拒否します（その場合、登録開始は 503 になります）。パス配下で公開する場合は、Next.js の `basePath` に加えて、この 2 つの関数をパスを保つように改修し、公開 URL の設定（第4節）にもパスまで含めてください。改修しないと、招待リンク・導入スクリプト・エージェントの接続先が親側へ届いて 404 になります。
- **本人識別の渡し方**: 「いま画面を操作しているのは誰か」を画面へどう渡すか。前段のプロキシ（OAuth 等）が `x-forwarded-email` と共有秘密ヘッダを付ける方式（`ISMS_DEVICE_CONTROL_PROXY_SECRET`）が標準です。既存アプリに組み込む場合は、そのアプリから署名付きで引き渡す仕組みを用意します。**これが無いと、メンバーマスタ・端末配布・書き込み系の画面はすべて止まります。**
- **名簿の正本**: 既存アプリの利用者名簿と、このシステムの `app.users` が二重になる場合、どちらを正とし、どう揃えるか。
- **実行環境**: 常駐と定期ジョブを systemd（`ops/systemd/`）で持つか、launchd（`ops/launchd/`）で持つか、それ以外か。
- **失敗の通知先**: 定期ジョブが失敗したとき、誰にどう届くか。メール送信そのものの失敗をメールで知らせると循環するので、別の経路にします（`ops/runtime/notify-failure.sh` を参照）。
- **秘密の受け渡し**: SMTP のパスワードやトークンは、導入先の機械の上で担当者が 0600 のファイルへ直接書きます。チャット・チケット・リポジトリには貼りません。

## 2. 環境条件

- PostgreSQL 16 以上（17 で検証）、拡張 `pgcrypto` / `btree_gist` / `citext`
- Node.js（`web/` の Next.js）、Python 3.12 以上（`scripts/`）、`psql`
- Go（端末エージェントのビルド。`scripts/build-agent-artifacts.sh`）
- Web は `127.0.0.1` で待ち受け、前段のリバースプロキシ経由で公開します。本番の起動スクリプト（`ops/runtime/start-isms.sh`）は `-H 127.0.0.1` で起動しますが、`web/package.json` の `start` は `0.0.0.0` で待ち受けます。`npm run start` で起動する場合は、前段を通らずに届く経路ができないよう待ち受けアドレスを確認してください。

## 3. DB ロール

接続は用途ごとにロールを分けます。取り違えると、起動時の検査（`ops/runtime/start-isms.sh`）で止まるか、関数呼び出しで権限エラーになります。

| ロール | 用途 | 使う設定 |
|---|---|---|
| `app_ro` | 画面の読み取り | `ISMS_WEB_DATABASE_URL` |
| `app_rw` | 書き込み・エージェントの受信 | `ISMS_WRITE_DATABASE_URL` / `ISMS_AGENT_DATABASE_URL` |
| `management_web` | 本人識別つきの読み書き（メンバーマスタ等） | `ISMS_PROXY_DATABASE_URL` |
| `auth_svc` | テナントセッションの発行 | セッション更新ジョブ |
| `mail_worker` | 送信キューを進める | `ISMS_MAIL_DATABASE_URL` |
| `provisioner` | テナント作成・DB 側の鍵の登録 | `scripts/new_tenant.py` / `scripts/set_agent_ingest_key.py` |

ロールはマイグレーション（`0001` / `0021` / `0050` / `0059`）で作られます。ロールごとの接続文字列は、パスワードファイル（pgpass）から `scripts/configure_runtime_db_roles.py` で生成できます。ローカルのソケット接続でパスワードを使わない構成なら、`postgres:///<DB名>?user=<ロール>` の形で足ります。

## 4. 機能ごとの設定の束

使う機能ごとに、**束のすべて**を揃えてください。1 つでも欠けると、その機能だけが止まります（他の画面は動くので気づきにくい）。

| 機能 | 必要なもの |
|---|---|
| 画面（閲覧） | `ISMS_WEB_DATABASE_URL`、`ISMS_WEB_TENANT_TOKEN`、**Web セッション更新ジョブ** |
| 本人識別つきの画面（メンバーマスタ・書き込み） | `ISMS_PROXY_DATABASE_URL`、`ISMS_WRITE_DATABASE_URL`、本人識別（`ISMS_DEVICE_CONTROL_PROXY_SECRET` と前段の `x-forwarded-email`、または組み込み先からの引き渡し） |
| 端末エージェントの受信（登録・状態報告） | `ISMS_AGENT_DATABASE_URL`、`ISMS_AGENT_INGEST_SECRET`（`scripts/set_agent_ingest_key.py` で DB 側にも登録）、前段で `/api/agent/v1/*` を通す |
| 端末の配布（招待・Google アカウントでの有効化） | `ISMS_WEB_BASE_URL`、`ISMS_AGENT_ENROLLMENT_ORIGIN`、`NEXT_PUBLIC_ISMS_AGENT_ENROLLMENT_ORIGIN`（デバイス管理画面の案内に表示する接続先。**ビルド時**に埋め込まれ、未設定だと例示用のホスト名が表示される）、`ISMS_AGENT_LOGIN_ENROLLMENT_ENABLED=true`、`ISMS_AGENT_ARTIFACT_DIR`（ビルド済みのバイナリ） |
| 招待メールの送信 | Web とは別のファイルに `ISMS_SMTP_HOST` / `ISMS_SMTP_USER` / `ISMS_SMTP_PASSWORD` / `ISMS_SMTP_FROM`（`ISMS_SMTP_PORT` は任意、既定 587・STARTTLS）、`ISMS_MAIL_DATABASE_URL`（`mail_worker`）、`ISMS_MAIL_TENANT_TOKEN`（送信用のテナントセッション。`scripts/send_mail_outbox.py` 自体は環境変数を読まないので、`ops/runtime/send-mail-outbox.sh` のように `--token=` で渡す。値が `-` で始まることがあるため、`--token` と値を分けずに `=` でつなぐ）、**送信ジョブと送信用セッション更新ジョブ**（詳細は [MAIL_OUTBOX.md](MAIL_OUTBOX.md)） |
| 任意: 外部の実行基盤からの端末操作 | `CODZILLA_ISMS_DISPATCH_URL` / `CODZILLA_ISMS_DISPATCH_TOKEN` / `CODZILLA_ISMS_DISPATCH_VIEW_TOKEN` |
| 任意: Google Workspace の月次取り込み | `GOOGLE_WORKSPACE_SERVICE_ACCOUNT_KEY`、`ISMS_GWS_SUBJECT` ほか（`ops/launchd/...google-workspace-monthly.plist`） |

`ISMS_AGENT_LOGIN_ENROLLMENT_ENABLED` は「露出の制御」の設定でもありますが、Google アカウントでの有効化を使う配布では**必須**です。登録は、対象者本人の有効化と DB 側の回数制限を通るまで完了しません。

## 5. 必須の定期ジョブ

| ジョブ | 間隔 | 止まるとどうなるか | 上流の実装 |
|---|---|---|---|
| Web セッション更新 | 6 時間（24 時間未満であること） | 24 時間後から、画面が「テナントセッション」系のエラーを出す。**HTTP は 200 のまま** | `ops/systemd/isms-web-session-rotate.*`、`ops/launchd/...web-session-rotate.plist`、`scripts/rotate_web_session.py` |
| 送信用セッション更新 | 6 時間 | 送信ジョブが静かに失敗し続ける | `ops/systemd/isms-mail-session-rotate.*`、`ops/runtime/rotate-mail-session.sh` |
| 送信キュー | 2〜5 分 | 招待メールが出ない | `ops/systemd/isms-mail-outbox.*`、`ops/runtime/send-mail-outbox.sh` |
| 失敗通知 | 上の各ジョブが失敗したとき | 何日も気づかない | `ops/runtime/notify-failure.sh`、`ops/systemd/isms-failure-notify@.service` |

テナントセッションは DB 側で**最長 24 時間**に制限されています（`app.create_session`）。更新ジョブが無い環境は、構築直後の確認を通っても翌日に止まります。

**`ops/` の実装を取り込まない場合は、この表の各行を自分の環境でどう満たすかを先に決めてから外してください。** 実装を捨てても、要件は残ります。

## 6. セットアップ手順

1. 第1節（第0工程）を決める
2. DB を作り、拡張を入れ、マイグレーションを適用する（`make migrate` / `scripts/migrate.sh`）
3. ロールごとの接続設定を用意する（ロールはマイグレーションで作られる。第3節）
4. テナントを作る（`scripts/new_tenant.py`。管理者と最初のセッションが発行される）
5. 設定ファイルを作る（第4節の束のうち、使う機能のぶん。秘密を含むファイルは 0600）
6. エージェント受信の鍵を登録する（`scripts/set_agent_ingest_key.py`）
7. `web/` をビルドし（`NEXT_PUBLIC_*` はビルド時に効くので、設定ファイルを読み込んでからビルドする）、`127.0.0.1` で起動する
8. 前段のリバースプロキシで公開し、`/api/agent/v1/*` を通す
9. 第5節の定期ジョブと失敗通知を入れる
10. エージェントのバイナリをビルドし（`scripts/build-agent-artifacts.sh`）、`ISMS_AGENT_ARTIFACT_DIR` に置く
11. メンバーマスタに運用者（オーナー・管理者）を登録する
12. 第7節の受入確認を行う

## 7. 受入確認

**実在の利用者の経路で、機能ごとに最後まで通します。** 途中の HTTP 200 では完了にしません。エラーを表示したまま 200 を返す画面があるためです。自分で作った Cookie やトークンでの確認は、実装の自己整合を見たにすぎません。

- [ ] 実在の利用者でログインし、画面が開く
- [ ] メンバーマスタに名簿が表示される（「信頼済みの利用者識別が必要です」が出ない）
- [ ] 運用データ画面が 42501 を出さない
- [ ] Web セッションの期限が「いま＋24 時間以内」で、更新ジョブが 1 回以上成功している
- [ ] 招待を発行し、メールが届き、リンクが公開 URL（パスを含む）で開く
- [ ] 対象の端末で導入し、登録開始が 200 を返し、本人の有効化で端末が台帳に出る
- [ ] 端末の状態報告が取り込まれる
- [ ] 定期ジョブをわざと 1 回失敗させ、通知が届く
- [ ] Web の待ち受けが `127.0.0.1` のまま

## 8. 症状から原因を探す

| 症状 | まず見る所 |
|---|---|
| 「テナントセッションまたは信頼済みの利用者識別が必要です」 | Web セッションの期限切れ（更新ジョブ）／本人識別が渡っていない／その人が名簿に居ない |
| `42501 tenant context is not set` | Web セッションの期限切れ |
| 登録開始が 403 `{"error":"closed"}` | `ISMS_AGENT_LOGIN_ENROLLMENT_ENABLED` |
| 招待リンク・エージェントの接続先が 404、登録開始が 503 | パス配下での公開か（第1節の改修と、公開 URL にパスが入っているか） |
| 招待メールが `queued` のまま | 送信ジョブ、SMTP の設定、送信用セッション |
| 状態報告が 400 `{"error":"posture rejected"}` | `ISMS_AGENT_INGEST_SECRET` と DB 側の鍵（`app.agent_ingest_keys`） |

## 9. 調べる順番

「この機能はあるか」を答えるときは、**上流の正本 → この公開版 → 導入先**の順に見ます。導入先だけを見て「機能が無い」と判断しないでください。導入先は上流の一部だけを取り込んでいることがあります。
