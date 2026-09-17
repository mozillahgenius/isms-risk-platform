# メール送信（依頼通知と外部質問票の送付）

外部リソースへのチェックリスト／アンケートの送付と、作業依頼の通知は、
**画面が積み、別プロセスが送る**。

```
画面（management_web）→ app.mail_outbox に行を足すだけ
                         ↓
scripts/send_mail_outbox.py（mail_worker ＋ SMTP 資格情報）→ SMTP → 相手
                         ↓
              成功したら status='sent'、質問票も 'sent' へ
```

## なぜ分けているか

- **Web プロセスに SMTP の鍵を置かない。** ISMS の対象システム自身が社外への
  送信口を直接握ると、画面の脆弱性がそのまま社外への送信になる。
- **誤送信を 1 クリックで起こせない。** 積むところと出すところが別なので、
  出る前に `app.mail_outbox` を見て止められる。
- **送信の記録が必ず残る。** 宛先・件名・本文・試行回数・失敗理由が
  `app.mail_outbox` に残り、監査時にそのまま証跡になる。

## 権限

| 操作 | できる人 | 実装 |
|---|---|---|
| 質問票の送付をキューへ積む | オーナー・管理者 | `require_management_permission(..., 'questionnaire_send')` |
| 依頼通知をキューへ積む | オーナー・管理者・マネージャー | `require_management_permission(..., 'notify')` |
| 実際に送信する | `mail_worker` ロールだけ | `ops/runtime/send-mail-outbox.sh` |

### ロールの分離

送信キューの状態を進められるのは **`mail_worker` 専用ロール**だけ。

- `app_rw`（＝Web の `management_web`）には `SELECT` と `INSERT` しか無い。
  `UPDATE` も `DELETE` も持たない
- 状態を動かす 4 つの関数（`claim_mail_batch` / `mark_mail_sent` /
  `mark_mail_failed` / `reclaim_stale_mail`）は `SECURITY DEFINER` で、
  先頭で `session_user = 'mail_worker'` を確かめる。`app_rw` には
  `EXECUTE` 権限自体を与えていない
- したがって、Web 側に欠陥があっても **1 通も送らずに「送信済み」の記録を
  作ることはできない**。`sent` へは `sending` からしか入れず、`sending` に
  できるのはワーカーが `FOR UPDATE SKIP LOCKED` で掴んだときだけ
- `[unconfirmed]` の印を書けるのも `reclaim_stale_mail()` だけなので、
  印を消して再送対象へ戻す経路も無い

0050 の `management_web` と同じ考え方（境界ごとにロールを分け、そのロール
でしか呼べない関数を通す）を、送信にも当てている。

`app.mail_outbox` への INSERT はトリガー `trg_guard_mail_outbox` が上記を強制する。

UPDATE は送信ワーカーが状態を進めるため管理ロールの判定を通さない（ワーカーは
本人性を持たない）。代わりに `trg_guard_mail_outbox_update` が**中身を凍結**する。

- 用途・宛先・宛名・件名・本文・関連先・積んだ時刻・作成者は**変更できない**
- 一度 `sent` になった行は他の状態へ戻せない
- 試行回数は減らせない
- `DELETE` は誰にも与えていない（消せる記録は証跡にならない）
- 状態は `queued → sending → sent / failed` の順にしか動かない。
  **`sent` へは `sending` からしか入れない**ので、1 通も送らずに
  「送信済み」の記録を作ることはできない

つまり、キューに積まれた時点で「誰へ何を送ろうとしたか」は固定され、
後から書き換えて別の相手へ送ったり、送っていないものを送信済みに
見せかけたりはできない。

宛名・件名は制御文字を持てず、本文は改行とタブだけを許す（CHECK 制約）。

## 設定（値はリポジトリに書かない）

`/opt/isms-platform/target-env/isms-mail.env` に置き、`ops/runtime/send-mail-outbox.sh` が読む。

| 変数 | 内容 |
|---|---|
| `ISMS_SMTP_HOST` | SMTP サーバー |
| `ISMS_SMTP_PORT` | 既定 587（STARTTLS）。465 なら SMTPS |
| `ISMS_SMTP_USER` / `ISMS_SMTP_PASSWORD` | SMTP 認証 |
| `ISMS_SMTP_FROM` | 差出人。`表示名 <address>` 形式可 |
| `ISMS_SMTP_REPLY_TO` | 任意。返信先を差出人と分ける場合 |
| `ISMS_SMTP_CA_FILE` | 任意。社内 CA の証明書で検証する場合 |
| `ISMS_SMTP_STARTTLS` | 既定 `require`。`off` は**ループバック宛のみ**許される |
| `ISMS_MAIL_TENANT_TOKEN` | 送信対象テナントのセッショントークン |
| `ISMS_MAIL_DATABASE_URL` | DB 接続先。**ロールは `mail_worker`**（`app_rw` では送れない） |

Web 側は `ISMS_WEB_BASE_URL` だけを使う（通知メールに入れるリンクの起点）。
**予備値は持たない。** 未設定ならメールにリンクを入れず「管理画面の『自分の担当』から」とだけ書く
（他社のデプロイで自社の URL が社外宛てメールに載らないようにするため）。

## 動かし方

```bash
# 送信待ちを見るだけ（キューは進まない）
python3 scripts/send_mail_outbox.py --token "$ISMS_MAIL_TENANT_TOKEN" --db isms_dev

# 実際に送る
python3 scripts/send_mail_outbox.py --token "$ISMS_MAIL_TENANT_TOKEN" --db isms_dev --apply

# 失敗した分を拾い直す（人が理由を確かめてから）
python3 scripts/send_mail_outbox.py --token "$ISMS_MAIL_TENANT_TOKEN" --db isms_dev --apply --retry-failed
```

`--apply` が無ければ 1 通も送らないし、キューの状態も進めない。

本番は `ops/systemd/isms-mail-outbox.timer`（2 分ごと）から
`ops/runtime/send-mail-outbox.sh` を呼ぶ。

### timer を有効にする前に必ずやること

**キューに社外宛が残っていないかを先に見る。** 有効化した瞬間、既に積まれている
`queued` 行が 2 分以内に出る。`--apply` 無しの一覧は 1 通も出さないので、
これで宛先を全件確認してから有効にする。

```bash
python3 scripts/send_mail_outbox.py --token "$ISMS_MAIL_TENANT_TOKEN" \
  --dsn "$ISMS_MAIL_DATABASE_URL"
```

### セッションの期限

`ISMS_MAIL_TENANT_TOKEN` も `app.sessions` のトークンで、Web 用と同じ 24 時間で切れる。
切れると送信ワーカーが静かに失敗し続けるので、`ops/systemd/isms-mail-session-rotate.timer`
（6 時間ごと）で更新する。中身は Web 用と同じ `scripts/rotate_web_session.py` を
`ISMS_SESSION_ENV_KEY=ISMS_MAIL_TENANT_TOKEN` / `ISMS_SESSION_RESTART=none` で振ったもの。

## 失敗したら

失敗した行は `status='failed'` と `last_error` を残す。**次回以降は自動で
拾い直さない**（`--retry-failed` を付けたときだけ）。黙って再送し続けると、
同じ相手へ同じ質問票が何通も届く。画面（質問票の詳細）にも失敗理由が出る。

同時に複数のワーカーが走っても、取り出しは `FOR UPDATE SKIP LOCKED` で
排他するので同じ行を 2 回送らない。

### 送信は済んだが記録できなかったとき

SMTP が受理した後に DB へ書けなかった行は、**`failed` にしない**。
`failed` にすると `--retry-failed` で同じ相手へ二度届く。この場合は
`sending` のまま残し、標準エラーへ「送信済みだが記録に失敗」と id を出す。
終了コードも 0 にならない。

### `sending` のまま残ったとき

取り出した直後にプロセスが落ちると `sending` のまま誰にも拾われない。
通常実行は `queued`、`--retry-failed` は `failed` しか見ないため、専用の
回収コマンドを使う。

```bash
# 30 分以上 sending のままの行を failed へ落として見えるようにする
python3 scripts/send_mail_outbox.py --token "$TOKEN" --db isms_dev --reclaim-stale 30
```

**回収は再送しない。** 相手に届いた後で落ちた可能性があるので、実際に
届いたかを確かめてから判断する。

回収した行の `last_error` には `[unconfirmed]` の印が付き、**`--retry-failed`
では拾わない**。届いたかを確かめたうえで、明示的に `--retry-unconfirmed` を
付けたときだけ再送する。

```bash
python3 scripts/send_mail_outbox.py --token "$TOKEN" --db isms_dev \
  --apply --retry-failed --retry-unconfirmed
```

`--reclaim-stale` は 60 分未満を受け付けない。短くすると、実行中のワーカーが
掴んでいる行まで `failed` に落として二重送信を招く。`--apply` 無しの一覧には
`sending` の行と `last_error` も出る。

## 受入

`tests/org_members_and_questionnaires.sh` が通しで確かめる。

- `--apply` なしでキューが進まないこと
- SMTP 設定が無いまま `--apply` してもキューを消費せずに落ちること
- 繋がらない相手なら `failed` と理由が残り、`sending` のまま残らないこと
- 平文送信がループバック以外へは使えないこと
- 偽の SMTP サーバー（`tests/fixtures/fake_smtp.py`）へ実際に届き、
  件名・本文が復号でき、`sent` と質問票の `sent` まで進むこと
- 送信済みの行の状態を戻せないこと、宛先・本文を書き換えられないこと、
  `DELETE` できないこと
- 件名に制御文字を入れられないこと（本文の改行・タブは通ること）
- `sending` のまま残った行が `--reclaim-stale` で回収され、
  `--retry-failed` では拾われないこと（自動再送されないこと）
- `--reclaim-stale` が短すぎるしきい値を拒むこと
- 未送信を `sent` に書き換えられないこと
