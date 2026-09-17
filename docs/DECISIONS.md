# 設計書からの逸脱と、その理由

> 正本: `ISMS-リスク管理プラットフォーム_詳細設計書_v2.0.md`（Drive）。矛盾時は設計書優先。
> ただし本書に挙げた項目は、**設計書のとおり実装すると設計書自身の受入条件を満たさない**、
> または PostgreSQL で動かないものである。逸脱の理由と、代わりに何を保証するかをここに残す。

各項目は「設計書の記述 / 実測した問題 / 採った実装 / 何が保証され、何が保証されないか」で書く。

---

## D-01 テナント文脈を GUC の素通しで信じない

**設計書 2.2 / 9.2**：`app.current_tenant()` は `current_setting('app.tenant_id')` を読み、
未設定なら例外を投げる。

**実測した問題**：`app.tenant_id` はカスタム GUC なので、`app_rw` が自分で
`SET LOCAL app.tenant_id = '<他テナントの uuid>'` と書ける。設計書の実装はその値を
そのまま信じるため、**RLS を素通りして他テナントのデータへ到達できる**。
これは設計書 Phase 1 受入 #7「`set_tenant_context()` を経由せず `app.tenant_id` を
直接設定した接続がテナントデータへ到達できない」を満たさない。

**採った実装**（`0006_tenant_context.up.sql`）：

- `app.tenant_context_keys`（singleton・`schema_owner` 所有・アプリロールに権限なし）に HMAC 鍵を置く
- `app.set_tenant_context()` は `app.tenant_id` に加えて `app.tenant_sig` を設定する
  - 署名 = `hmac('v1:' || tenant_id || ':' || pg_backend_pid(), 鍵, 'sha256')` を hex 化
  - 区切りと版を入れて連結の曖昧さを消す。鍵・引数のいずれかが NULL なら署名を作らず必ず例外（fail closed）
- `app.current_tenant()` は署名を再計算して照合し、合わなければ例外
- `pg_stat_activity.backend_start` は**使わない**。`SECURITY DEFINER` の中では
  `current_user` が関数所有者になり、他ロールのセッション行が見えず NULL になり得るため

**保証されること**（`tests/rls_test.sh` で検証済み）:

1. 新規接続で署名なしに `SET` しても拒否される
2. 他テナント向けの ID へ差し替えると署名が合わず拒否される
3. 別バックエンドへ署名を移しても `pg_backend_pid()` が違うので拒否される
4. `set_tenant_context()` の引数が呼出者の保持する秘密（セッショントークン）に紐付いている

**保証されないこと（残余リスク・明記する）**:

- 「現在の GUC が必ず関数経由で設定された」ことは証明しない。同一バックエンドで一度正規に
  `set_tenant_context()` を呼んだ呼出者は、`current_setting` で自分の署名を読み、以後
  同じバックエンド上で再設定できる。**ただし得られるのは常に自テナントだけ**で、
  権限の昇格にはならない
- `pg_backend_pid()` は再利用され得る。PID が一周して同じ値になった別バックエンドでは、
  同一テナント向けの古い署名が通り得る。これも自テナント限定であり越境にはならない
- 署名は鍵のローテーション（`app.tenant_context_keys` の更新）で一斉に無効化できる

**運用条件**：`set_config(..., true)` は `SET LOCAL` 相当でトランザクション終了時に消える。
**必ず `BEGIN → set_tenant_context → 業務クエリ → COMMIT` を同一トランザクションで行う。**
autocommit で `set_tenant_context()` だけ呼んでも次の文には残らない（これも試験済み）。
PgBouncer は transaction pooling を前提とする。

---

## D-02 `app.sessions` にトークンのハッシュを持たせる

**設計書 2.3**：`app.sessions` は `id uuid` のみ。`set_tenant_context(p_session uuid)` は
その id を受け取る。

**実測した問題**：DB ロールは `app_rw` をテナント間で共有するため、DB 側で
「呼出者が本当にそのセッションの持ち主か」を `session_user` で判定できない。
セッション UUID を知っているだけで任意テナントへ切り替えられる。

**採った実装**：

- `app.sessions.token_hash bytea NOT NULL UNIQUE`（sha256、32 バイト固定）を追加
- `app.set_tenant_context(p_token text)` は生トークンを受け取り、ハッシュで引く。生トークンは DB に残らない
- トークンは 32 文字未満を拒否（推奨は 32 バイト CSPRNG の hex ＝ 64 文字）
- `app.create_session()` / `app.revoke_session()` を `SECURITY DEFINER` で用意し、
  **`app.sessions` へのテーブル権限を `app_rw` / `app_ro` に一切与えない**
- TTL は最大 24 時間。ローテーションは「新トークンで `create_session` → 旧を `revoke`」

**副作用**：`app.sessions` と `app.memberships` は文脈確立**前**に定義者が読む必要がある。
`FORCE ROW LEVEL SECURITY` は所有者にも効くため、`schema_owner` 向けの参照ポリシー
（`ctx_session_lookup` / `ctx_membership_lookup`）を明示的に張っている。
これを張らないと `set_tenant_context()` が自分の引数を検証できず、鶏と卵になる。

---

## D-03 `app.effective_risk_criteria` ビューの 2 点

**設計書 2.5** のビュー定義には次の 2 つの問題がある。

1. **`security_invoker` 未指定**：PostgreSQL の通常のビューは所有者の権限で下位表を読むため、
   RLS を迂回する。`WITH (security_invoker = true)` を明示した。
   CI（`check_rls.sql` 検査 10）が `app` スキーマの全ビューについてこれを強制する。
2. **`(d.override->>'band_top_priority')::int[]` が動かない**：`->>` は JSON 配列を
   `[15, 16]` という文字列で返すが、PostgreSQL の配列リテラルは `{15,16}` なのでキャストに失敗する。
   `jsonb_array_elements_text` を通して配列を組み立てる `app.jsonb_to_int_array()` を用意した。

---

## D-04 残存リスクの検査が素通りしていた（生成列と BEFORE トリガ）

**設計書 2.7**：`app.validate_residual()` は `NEW.level_sec_after` を見て
「同一サイクルで 残存 > 固有 なら拒否」する。

**実測した問題**：`level_sec_after` は `GENERATED ALWAYS AS (...) STORED` の生成列で、
**BEFORE トリガの時点ではまだ計算されておらず必ず NULL** になる。
そのため関数は先頭の `IF ... IS NULL THEN RETURN NEW` で必ず抜け、
**この検査は一度も働いていなかった**（試験を書いて初めて分かった）。

**採った実装**：トリガ内で `NEW.prob_after * NEW.impact_sec_after` を自分で計算する。
`tests/domain_test.sh` が「同一サイクルの上昇は拒否」「再評価での上昇は理由必須」の
両方が実際に落ちることを確認する。

---

## D-05 `app` スキーマのテーブル権限・スキーマ USAGE の明示

設計書は RLS ポリシーを `app_rw` / `app_ro` に対して張っているが、
**テーブル権限そのものの GRANT が書かれていない**。RLS は行の可視性を制御するだけで、
操作種別の認可やロール権限の代わりにはならない（権限が無ければそもそも到達しない）。

`0015_rls_and_grants.up.sql` で次を明示した。

- `app` の各表に `SELECT, INSERT, UPDATE, DELETE` を `app_rw` へ、`SELECT` を `app_ro` へ
  （`GRANT ALL` は使わない。`TRUNCATE` / `REFERENCES` / `TRIGGER` は与えない）
- `catalog` の各表に `SELECT` のみ
- `ALTER DEFAULT PRIVILEGES` は実行者ごとで既存オブジェクトに遡及しないため**これに依存しない**。
  CI が `aclexplode` で実オブジェクトの実効権限を直接検査する

### 関数ごとの実行権限

| 関数 | app_rw | app_ro | auth_svc | auditlogd | 備考 |
|---|:--:|:--:|:--:|:--:|---|
| `app.current_tenant()` | ○ | ○ | × | ○ | RLS ポリシー式の評価で呼ばれるので両ロールに必要 |
| `app.set_tenant_context(text)` | ○ | ○ | × | × | |
| `app.tenant_context_signature(uuid)` | **×** | **×** | × | × | 与えると任意テナントの署名を作れる。CI 検査 12 で強制 |
| `app.create_session(...)` | **×** | **×** | ○ | × | app_rw に与えると任意テナントのセッションを発行できる（D-12）。CI 検査 13 |
| `app.revoke_session(text)` | ○ | × | ○ | × | 失効はトークンを知る者の正当な操作 |
| `app.rebuild_effective_grants(uuid)` | ○ | × | × | |
| `app.expire_deviations()` | ○ | × | × | |
| `audit.append(...)` | × | × | ○ | |
| `audit.verify_chain()` | ○ | ○ | × | `audit_verifier` にも付与 |

---

## D-06 掲載順の入れ替えと後付け FK

- `app.grants` は `app.oauth_apps` を FK 参照するが、設計書 2.6 の掲載順は逆。
  循環ではないので `oauth_apps` を先に作る順へ並べ替えた（`ALTER` の後付けは不要）
- `app.exceptions.finding_id` → `app.findings` は 0010 と 0011 にまたがるので
  `ALTER TABLE ... ADD CONSTRAINT` で後付けした
- `app.effective_grants` の RLS は設計書 4.2 が手書きしているが、他表と生成規則が
  二重になるため 0015 の一括生成に寄せた

---

## D-07 監査ログ：定義者向けポリシーと、追記ヘルパ

設計書 8.3 は `auditlogd` の INSERT ポリシーだけを定める。しかし `chain_seq` の採番と
`prev_hash` の連結は「直前の行を読む」必要があり、`auditlogd` には SELECT 権限が無い。

`audit.append()` を `SECURITY DEFINER` で用意し、採番・ハッシュ計算・挿入をまとめた
（呼出側がチェーンを壊せない）。所有者も `FORCE RLS` の対象なので、
**INSERT と SELECT のポリシーだけ**を `schema_owner` に張った。
UPDATE / DELETE のポリシーは作らない ＝ **所有者であっても RLS の段階で過去行を書き換えられない**。
これは設計書 8.3 不変条件 6 を `REVOKE` より強く担保する。

署名（`signature`）の検証は独立プロセスの責務なので `audit.verify_chain()` では見ない。
チェーンとハッシュだけを検証する。

---

## D-08 ロールはクラスタ全体の存在

`0001_init.down.sql` はロールを無条件に `DROP` すると、同じクラスタの別データベース
（開発用と CI 用を並べている等）が参照している場合に必ず失敗する。
`pg_shdepend` を見て、**他のデータベースからの依存が残っている間は残す**ようにした。

---

## D-09 Phase 0 の正規化に NFKC を使わない

当初 NFKC を使ったところ、`'人事・労務（Phase1）'` が `'人事・労務(Phase1)'` になった。
NFKC は全角括弧・全角英数字を半角へ畳むため、**台帳の値そのものを書き換える**。
往復では辻褄が合うが、DB に入る値が原本と変わるのは正規化ではなく改変なので採らない。

文字列は **NFC**（合成・分解の揺れだけを畳む）。空白（NBSP / 全角空白 / 連続空白 / 改行）は
明示的に処理する。数値列のパースだけは NFKC を使う（全角数字を許容するため）。
規則の全文は `phase0/NORMALIZATION.md`。

---

## D-10 実測と設計書の食い違い（数値）

| 設計書の記述 | 実測 | 対応 |
|---|---|---|
| 標準リスクシナリオライブラリ「既存 `risk_map_master.csv`（候補リスク **908 件**）」（1.6 / Part XIII） | 同ファイルは **196 行**（業務キーも 196 で重複なし）。テンプレート xlsx の「リスクマップマスタ」シートも 196 行 | 実ファイルどおり 196 件を投入した。件数を合わせるための水増しはしない。**設計書側の訂正が必要** |
| 上場準備 統制チェックカルテ **304 要請事項**（1.10 / Part XIII） | `control_requirements_master.csv` は 304 行で一致 | そのまま投入。CI が 304 件を検査する |
| 標準チェックカタログ **66 本**（1.10 / 6.3 / 受入 #1） | 設計書に `query_sql` と `negative_fixture` が載っているのは **4 本**（CHK-SHARE-001 / CHK-SHARE-004 / CHK-TPR-001 / CHK-OPS-006）。残り 62 本は key・タイトル・深刻度・周期・関連統制の表だけ | **投入していない**。`negative_fixture` が無いチェックはカタログ登録できない（設計書 6.4）という設計自身の規律に従う。件数を偽らないため、ダミーの `query_sql` は入れない。Phase 2 の作業 |

`catalog.controls` の `code` は `大項目記号-小項目コード(要請No)` で組み立てた
（例 `A-10-10-10(1)`）。設計書 2.4 の例示 `A-30-10(3)` は桁が省略されており、
実データでは一意にならないため。

---

## D-16 適用済み migration は書き換えない（運用ルール）

`scripts/migrate.sh` は適用時に up / down 双方の SHA-256 を `schema_migrations` へ
記録し、以降の `up` / `down` / `status` で実ファイルと突合する。
**一度でも適用された環境がある migration を書き換えると、その環境で必ず落ちる。**
修正は 0016 以降の新しい番号で足す。

現在の 0001〜0015 は、開発機と CI（毎回作り直す）にしか適用されていない。
つまり **まだ配備先が無い**ので、この期間の直接修正は許される。
0016 以降は「足す」だけにする。最初の実配備を行った時点で 0001〜0015 も凍結する。

この規律を破っていないかは CI の工程 2（空 DB へ全 DDL を適用）と
`verify_checksums` が見る。

---

## D-12 セッション発行を `auth_svc` へ分離する（設計書に無いロール）

**実測した問題**：`app.create_session()` を `app_rw` が呼べる状態だと、
`app_rw` は他テナントの uuid を指定してセッションを発行し、そのトークンで
`set_tenant_context()` を通せる。**D-01 の署名検証も D-02 のトークン照合も、
発行そのものが自由なら意味を成さない。** レビューで指摘されて気づいた。

**採った実装**：設計書 9.1 に無い 6 つ目のロール `auth_svc` を足し、
`app.create_session()` の EXECUTE を `auth_svc` だけに与える。
`app_rw` / `app_ro` からは剥がす。認証経路（ログイン処理）だけが `auth_svc` で接続する。
`auth_svc` はテーブル権限を一切持たない（CI 検査 13 が強制する）。

`app.revoke_session()` は `app_rw` にも残す。失効はトークンを知っている者にしかできず、
自分のセッションを切るのは正当な操作なので。

---

## D-13 監査ログの直接 INSERT を塞ぐ

**設計書 8.3**：`GRANT INSERT ON audit.audit_log TO auditlogd;` と
`CREATE POLICY audit_insert ... WITH CHECK (true)`。

**実測した問題**：これだと `auditlogd` が `audit.append()` を迂回して、
任意の `chain_seq` / `prev_hash` / `hash` を持つ行を直接書ける。
自分で整合したハッシュを計算して入れれば、`verify_chain()` を通る偽の履歴を作れる。

**採った実装**：`audit.audit_log` への直接権限を `auditlogd` からも剥がし、
追記は `audit.append()`（SECURITY DEFINER）経由のみにした。
CI 検査 9b が「SELECT 以外の権限が付いていないこと」を検査する。

---

## D-14 追記のみの表に UPDATE / DELETE を与えない

`app.device_snapshots` と `app.graph_events` は設計書 2.6 が「追記のみ」と書いているが、
0015 の一括 GRANT では他表と同じく UPDATE / DELETE も付いていた。
＝「追記のみ」がコメントだけの主張になっていた。
この 2 表は `SELECT, INSERT` のみに変えた。CI 検査 14 が強制する。

---

## D-15 統制マスタのプレースホルダ行

`control_requirements_master.csv` の 304 行のうち 1 行は、要請No が `-`、
要請事項が「なし」のプレースホルダ（`A-40` の `140-10`）。
実データを曲げないのでそのまま投入し、`code` は `A-40-140-10(-)` になる。
CI はこの形を許容しつつ、**該当が 1 件であること**を検査する
（いつの間にか増えていたら落ちる）。

---

## D-11 検証環境

設計書 11.1 は PostgreSQL 16 を前提とする。**この機には Docker / colima が無く、
Homebrew の PostgreSQL 17 でのみ検証している。**
CI の正は PG16 と定義するが、PG16 での実行は未実施。Docker が使える環境で回すまで
「PG16 検証済み」とは書かない。

---

## D-17 ルールの正本は Git。ただし 1 つのリポジトリではない

「ルールは GitHub で正本管理でも DB でもよい」という指示に対し、**Git を正本、DB を投影**と決めた。
画面は投影を読むだけで、DB を書き換えない。

ただし実測すると、正本は **2 つのリポジトリに分かれている**。

| 対象 | 正本 |
|---|---|
| DOM 2026.1（ロール・資産分類・リスク基準・カレンダー・規程） | このリポジトリの `db/seeds/0001_dom_2026_1.sql` |
| 統制 / リスクシナリオ雛形 | 設定された外部カタログ、または同梱の架空サンプルCSV |

外部CSVをこのリポジトリへコピーしない。二重に持つと片方が古くなり、
どちらが正かを人が判断する羽目になる。外部ソースを設定した場合の変化は
`scripts/ci/check_reused_assets.sh` のハッシュ突合が検知する。

---

## D-18 出所は画面に書かず、投入時に実測して DB へ残す

画面に「出所: db/seeds/…」と固定文字列を置くと、上流が動いても画面は同じ顔のままになる。
migration 0020 で `catalog.seed_provenance` を足し、`db/seeds/record_provenance.py` が
投入のたびに **リポジトリ・commit・パス・SHA-256・件数** を実測して記録する。画面はそこだけを読む。

- `row_count` は投入側の申告ではなく **投入後の DB の実測**（途中で落ちても「全部入った」と記録されない）
- commit は **そのファイルが HEAD と一致しているときだけ**書く。作業ツリーが汚れていれば NULL にし、
  画面は「未コミットの変更あり」と出す

---

## D-19 分類から導出した階層を、実在する関係と同じ顔で描かない

図の階層は、大半が **`controls.theme` / `risk_scenario_templates.domain` の文字列を割って**作っている。
関連テーブル（`framework_mappings` / `risk_template_controls` / `check_controls`）は実測 0 件で、
実在する関係だけでは図がほぼ線の無い点の集まりになる。

そこで辺に種別を持たせた。

- **実関係** … `controls.framework_key`、`calendar_events_default.owner_role` など、列にそのまま在るもの
- **導出** … theme / domain / cadence を割って作ったもの

画面は本数を「実在 N / 導出 M」と分けて出し、hover でどちらかが分かる。
導出した中間ノード（DB の行ではない見出し）は**白抜き**で描く。
これを混ぜると、無い関係を有るように見せることになる。

---

## D-20 0 件のものを図と一覧から消さない

統制が 0 件の現行フレームワーク（ISO27001:2022）、未投入の対応表・チェックは、
消さずに「未投入」の色のノード・カードとして残す。
旧版の移行用空枠（ISO27001:2013）のように、運用対象外と決めた枠は正本から削除する。
現行対象を消すと「無い」ではなく「元から想定が無い」に見え、抜けが見えなくなる。

---

## D-21 画面は app_ro で繋ぎ、運用データは「0 件」と書かない

画面の接続ロールは `app_ro`（catalog へ SELECT のみ）。加えて接続時に
`default_transaction_read_only` を立て、書こうとした時点で落ちるようにした。

`app.*` は RLS のテナント文脈が要るため、`app_ro` で読むと **0 件ではなく
`tenant context is not set` で失敗する**。したがって運用画面は「運用データ 0 件」と書かず、
**「読める状態にない」**と出す。0 件と読めないは別のことで、混ぜると DB が落ちている間ずっと
「ルールが 1 件も無い」画面を見せることになる。

---

## D-22 チェックの契約（query_sql / expect / negative_fixture）

設計書には `query_sql` と `negative_fixture` を持つチェックが 4 本例示されているが、
**`expect` の形式と、合否の決め方は書かれていない**。ここで決めた。

| 項目 | 決めたこと |
|---|---|
| `query_sql` | **違反している行**を返す SELECT。1 行も返さなければ合格 |
| `expect` | `{"max_violations": N}`。N 行までは合格とみなす |
| `negative_fixture` | 違反を 1 件わざと作る SQL |
| 実行するロール | `app_ro`（読み取り専用）＋テナント文脈。カタログの SQL は書ける接続で実行しない |
| `coverage_ratio` | 母集団を丸ごと走査するので、問い合わせが通れば 1.000。通らなければ NULL（0 と書くと「見たが 0%」に読める） |

「違反行を返す」形にしたのは、**証拠がそのまま残る**ため。件数だけを返す形だと、
落ちたときに「何が違反なのか」を人がもう一度探すことになる。

---

## D-23 「落ちることを確かめた」検査だけが pass になる（DB の制約）

`app.check_runs` に `negative_verified` と `verified_digest` を足し、
**`result = 'pass'` は `negative_verified` が真でなければ入らない**制約を置いた（0021）。

検査は「通ったこと」ではなく「落ちるべき時に落ちること」で初めて検査になる。
人が確認する運用にすると、忙しい日に飛ばされ、そのまま緑が並ぶ。
記録する側が制約に従うほかない形にすれば、飛ばした時点で記録できない。

確認の中身は 2 段構えで、**両方**を満たしたときだけ「確認済み」とする。

1. 何もしない状態で違反が 0 件（＝前提が成立している）
2. `negative_fixture` を入れると違反が出る（＝検査が働く）

2 だけを見ると、元から落ちている検査を「働いている」と誤認する。

`verified_digest` は確認した時点の `query_sql` と `negative_fixture` の SHA-256。
中身が書き換わったら前の確認は根拠にならないので、確認をやり直す。

**逆向き検証（実測）**: 制約を直接試すと
`check_runs_pass_requires_negative_verification` で拒否される。
`scripts/checker.py --skip-verify` は全件 `inconclusive` になり、1 本も pass しない。

---

## D-24 negative_fixture は対象の DB で流さない

確認は**使い捨ての DB を作ってそこで**行い、対象の DB では読むだけにする。

ロールバックする前提でも、対象の DB で流せばトリガ・監査ログ・連番など
**巻き戻らない副作用**に触れる。監査する側が被監査側のデータを動かしたら、
その時点で監査ではなくなる（[[設計｜事業基盤の統合と監査機能]] の「監査機能は業務データを直さない」）。

`scripts/checker.py` は毎回 `isms_checker_verify` を作り直し、そこで
migration → DOM 投入 → チェック投入 → テナント作成 → 確認 まで行ってから捨てる。

---

## D-25 テナントを作る経路（provisioner ロールと定義者向け INSERT ポリシー）

テナントが 1 つも作れないと運用データは永遠に空で、画面も「読めない」以上のことを言えない。
`app.provision_tenant()`（SECURITY DEFINER）を足し、テナント・管理者・membership・
標準規程 12 本の展開をひとまとまりで作る。

- 呼べるのは **`provisioner`** ロールだけ。表への権限は持たせない（この関数を呼ぶことしかできない）
- `app_rw` には持たせない。業務用の接続がテナントを作れる状態にしない
- 定義者（`schema_owner`）向けの INSERT ポリシーを 5 表に足したが、
  **`WITH CHECK` を「いま作っているテナントの行だけ」に縛る**（`app.provisioning_target()`）。
  `USING (true)` の permissive なポリシーを置くと、読み取り側にも波及して穴になる
- `scripts/ci/check_rls.sql` に検査 3c を足し、対象ロール・コマンド・`WITH CHECK` の中身・
  対象表が想定どおりであることを機械で見る

**`INSERT ... RETURNING` は使えない**（実測）。RETURNING は返す行に SELECT のポリシーを
要求し、定義者に読み取りポリシーを与えていないため落ちる。
回避のために読み取りを広げると、作成のためだけに定義者へ全テナントの閲覧を渡すことになる。
id を先に決めて書き戻さない形にした。

---

## D-26 いま入れられるチェックは 4 本（設計書の 66 本ではない）

設計書は標準チェック 66 本を想定するが、`query_sql` と `negative_fixture` が
書かれている 4 本はいずれも外部コネクタ（Google Workspace 等）の取得結果を前提にしている。
コネクタは Phase 2 で未着手なので、入れても動かない。

動かないチェックを並べるとカタログの件数だけが増え、「検査がある」ように見える。
**コネクタ無しで `app.*` の実体から判定できるもの 4 本**に絞った（`CHK-CORE-*`）。

作る途中で 1 本落とした。`app.sessions` を読むチェックを書いたが、
この表は**定義者専用**で `app_ro` からは読めない（0015 が意図的に権限を配っておらず、
CI がその漏れを検査している）。読み取り監査の立場で成立しないチェックだったので、
規程本文の標準からの乖離を見るチェックへ差し替えた。

### 既知の欠け: チェックの廃止経路が無い

`catalog.checks` に `retired_at` が無く、`app.check_runs` から参照されると
**削除できない**（実測: FK 違反）。実行履歴を持つチェックを止める手段が今は無い。
統制・リスク雛形には `retired_at` があるので、チェックにも同じ作法が要る。Phase 2 の作業。

---

## D-27 合格ゲートは「形の検査」ではなく「中身の照合」

0021 の制約は `result='pass'` に `negative_verified` と 64 桁の `verified_digest` を
求めるだけだった。**書ける主体が true と適当な 64 桁を入れれば pass にできた。**
形は合っているが中身を見ていないので、ゲートとしては素通しに近い。

0022 で 2 つ足した。

- `catalog.check_digest(key)` — チェックの中身から指紋を作る。**計算元は DB の 1 か所だけ**。
  実行側（`scripts/checker.py`）もこの関数を呼ぶ。同じ式を 2 か所に書くと、
  いつか片方だけ変わり、ずれた側は「一致しない」ではなく**黙って通る**方へ倒れる
- `app.check_runs` のトリガ — `negative_verified` を立てるなら、`verified_digest` が
  **いまのカタログの中身と一致していること**を求める

### 防げること / 防げないこと

| | |
|---|---|
| 防げる | でたらめな 64 桁で「確認済み」を名乗る |
| 防げる | 確認したあとにチェックを書き換えて、前の確認のまま通す |
| **防げない** | **fixture を本当に流したかどうか** |

最後の 1 つは DB からは見えない。実行側（checker）の仕事として残る。
「DB が止める」と言えるのはここまで、と線を引いておく。

### あわせて直したこと

`app.provision_tenant()` が `public.gen_random_uuid()` を名指ししていた。
`search_path` を `pg_catalog` に固定していても、`public` に関数を作れる主体が居れば
差し替えられる。この DB では PUBLIC から CREATE を剥がしてあるが（実測: `f`）、
その設定に寄りかからず `pg_catalog.gen_random_uuid()` へ変えた（PG13 以降は組み込み）。

なお、定義者向けの INSERT ポリシーが効くのは **FORCE ROW LEVEL SECURITY が
掛かっているから**（実測: `app` の RLS 有効な 50 表すべてが FORCE）。
FORCE が外れると所有者は RLS を素通りし、`WITH CHECK` は意味を失う。
`scripts/ci/check_rls.sql` が FORCE の網羅を見ている。

### 追補: 過去の確認は書き換えず、いま有効かを見せる

`catalog.checks` を後から変えても、既に記録された `check_runs` の
`verified_digest` は古いままになる。ここで過去の記録を書き換えたり無効化したりはしない。
**後から直せる記録は証拠として成立しない**（監査ログを書き換えない、と同じ理由）。

代わりに、画面が「その確認が**いまの中身にも当てはまるか**」を出す。

- 一致 → 「落ちることを確認済み」
- 不一致 → 「確認後に中身が変わった」（赤）

実測: `expect` を緩めると表示が切り替わり、戻すと元に戻る。

### 残っている前提: `public.digest` を差し替えられる主体

指紋の計算は pgcrypto の `public.digest` に依存する。これを差し替えられる主体が居れば
計算そのものを乗っ取れる。実測すると、

- `public` スキーマの ACL は `pg_database_owner=UC` と `=U`（他は USAGE のみ）
- `public.digest` の所有者はデータベース所有者

つまり差し替えられるのは**データベース所有者（スーパーユーザ）だけ**で、
その主体はどのみち全部を迂回できる。追加の危険は増えていない。
pgcrypto を専用スキーマへ移す整理は、配備先が決まった段階で行う。

---

## D-28 受入試験は共有 DB で走らせない（`make test` は使い捨て DB）

**設計書の記述**：Phase 1 受入は「DB 層で拒否されること」を実接続で確かめる、とだけ書いてある。
どの DB で走らせるかは書かれていない。

**実測した問題**：`make test` の既定が `isms_dev` だった。`tests/domain_test.sh` は
FK の相手を作るために `catalog.frameworks('TEST-FW')` と
`catalog.controls('TEST-FW','T.1', theme は与えない)` を入れ、終了時に消さない。
その結果、mac mini で `make test` を流したあと、

- `catalog.controls` が 304 → 305 件になった（seed の実数と食い違う）
- 残った統制の `theme` が NULL で、`/graph` と統制詳細が **500** になった

`catalog` は Git の投影であり、**試験が触ったまま残ると画面が正本と食い違う**。

**採らなかった案（後始末を足す）**：試験は `audit.audit_log` を消し、`app.risk_criteria` は
履歴テーブルなので通常削除できず、`rls_test.sh` は最後に fixture を残す。
「元へ戻す」は網羅が難しく、漏れても気づけない。

**採った実装**（`tests/run_isolated.sh`・`make test`）：

- 使い捨て DB（既定 `isms_test_<pid>`）を作り、migration と seed を入れ、そこで試験を走らせる
- 終了・失敗・中断のいずれでも `trap` で DROP する
- 使い捨て DB 名が共有 DB 名と一致したら**実行を拒否**する（DROP するため）
- **共有 DB（`$ISMS_DB`、既定 `isms_dev`）の `catalog` の指紋を試験の前後で突合する。**
  指紋は全テーブルの中身の md5 で、件数だけでは「1 行足して 1 行消した」を見逃す

**逆向き検証**：使い捨て DB へ切り替えずに `domain_test.sh` を共有 DB へ向けると、
指紋が `controls` / `dom_versions` / `frameworks` / `risk_criteria_default` の
4 テーブルで食い違い、検査が落ちることを実測した。

**保証されないこと**：`make ci` は従来どおり `isms_ci` を作り直して使う。
CI の中では試験が `catalog` に fixture を足すが、その DB は毎回捨てるので影響しない。

---

## D-29 分類（`theme`）の正規形を DB で強制し、画面は素の等値で読む

**設計書の記述**：統制は `theme` で階層に割る（3 段を想定）。NULL や空白の扱いは書かれていない。

**実測した問題（2 つある）**：

1. DDL 上 `theme` は nullable なのに、画面の型は `string` と書いてあった。
   `splitTheme(theme: string)` が `theme.split(...)` を呼ぶため、NULL の行が 1 件でも在ると
   `/graph` と統制詳細が 500 になる。**型が実データについて嘘をついていた。**
2. さらに調べると、「その統制の分類は何か」の定義が **3 か所に分かれていた**。

   | 場所 | 解釈 |
   |---|---|
   | 画面 `splitTheme` | `' / '` で割り、各段を JS の `trim` で削り、空段を捨てる |
   | 一覧の絞り込み | 素の `theme = ?` と `theme LIKE ? || ' / %'` |
   | 「同じ分類の統制」 | 素の `theme = (…)` |

   同じ値が 3 通りに解釈されるので、` A / B ` のように前後へ空白の入った行が 1 件在るだけで
   **「詳細は 2 件と言うのに、遷移先の一覧は 0 件」**になる。

**採らなかった案（画面側で正規化する）**：最初は `same_theme` を `btrim` で正規化したが、
一覧の絞り込みは素の等値のままなので、**ずれる場所が移動しただけ**だった。
次に JS の `trim` と同じ空白集合を SQL へ持ち込んだが、`' / '`（区切りだけ）のような値では
やはり画面と SQL の判断が割れた。**どこか 1 か所を正規化する限り、必ず別の 1 か所とずれる。**

**採った実装**（migration `0023_control_theme_canonical`）：**値の側を 1 通りに固定する。**

- `catalog.theme_space_chars()` — 空白と見なす文字。ECMAScript の
  WhiteSpace ＋ LineTerminator（TAB/LF/VT/FF/CR/SP/NBSP/OGHAM/各種スペース/LS/PS/NNBSP/MMSP/全角/BOM）
- `catalog.canonical_theme(text)` — `' / '` で割り、各段を上の集合で削り、空段を捨てて繋ぎ直す。
  画面の `splitTheme(theme).join(' / ')` と同じ結果になる
- `CHECK (theme IS NULL OR (theme <> '' AND theme = catalog.canonical_theme(theme)))`

これで `theme` は「NULL（＝分類なし）」か「正規形の空でない文字列」しか取り得ない。
以後、**素の等値比較が正規形の比較と一致する**ので、画面側で正規化する必要が無くなり、
3 か所の解釈が自動的に揃う。

適用前の実測: `catalog.controls` 304 件のうち NULL 0 件・空文字 0 件・非正規形 0 件。落ちる行は無い。

画面側に残るのは NULL の扱いだけ:

- `Control.theme` と図モデルの入力を `string | null` にする
- `splitTheme(null | undefined | 空白のみ)` は空配列を返す。分類の無い統制は
  中間ノードを介さず**フレームワーク直下**に付く。行は図から消さない（消すと件数が食い違う）
- 「分類なし」を表す中間ノードは**作らない**。在りもしない分類を図に足さないため
- 一覧・詳細は空欄ではなく **「分類なし」** と出す。空欄では「取れなかった」と区別が付かない
- 分類なしの統制には「同じ分類の統制を見る」を出さない（分類なしの寄せ集めを指すため）

**逆向き検証**：

- `splitTheme` のガードを `theme!.split(...)` に戻すと、**型検査は通るが**単体試験 2 件が落ちる。
  同じ変異をビルドに入れると外形検査 `4/4c` が「図が 200 になりません」で落ちる
- `same_theme` だけを正規化する変異を入れると、外形検査が
  「同じ分類の件数が 2 になりません（… 3）」で落ちる
- `controls_theme_canonical` を落とした DB で `domain_test.sh` を走らせると、
  非正規形 5 通り（前後空白・空白のみ・区切りだけ・空文字・空の段）が
  **すべて独立に**「失敗するはずが成功した」で落ちる。
  検査ごとに `code` を変えてある（使い回すと 2 件目以降が一意制約違反という
  **別の理由**で落ち、検査が働いたように見えてしまう）

**保証されないこと**：`catalog.risk_scenario_templates.theme` には同じ制約を入れていない。
こちらは `NOT NULL` で、かつ段に割らない葉のラベルなので同じ壊れ方はしないが、
前後空白のゆらぎが入れば図のノードは分かれる。実データにゆらぎが無いことは確認していない。

---

## D-30 フレームワーク対応とリスク↔統制は「初期対応候補」として投入する

カタログ画面で `framework_mappings` と `risk_template_controls` が 0 件のままだと、
統制やリスク雛形が存在していても、対応関係をレビューする入口が無い。
一方、対応候補を実施済み・証跡済みとして扱うと、カタログと運用台帳を混同する。

**採った実装**（seed `db/seeds/0009_relationships.sql`）：

- ISO/IEC 27001:2022 Annex A のコード・標準管理策名 93 件をカタログへ登録する
- IPO-KARTE と ISO の対応は、既存統制の名称・テーマによる候補抽出を `related` として登録する
- リスク雛形は領域ごとの標準候補（ISO と既存 IPO 統制）へ接続し、領域名変更などで孤立する場合は
  リスク管理の代表統制へ最低 1 件接続する
- `control_frameworks` は現行統制を IPO-KARTE と RISK-MANAGEMENT から参照できるよう再同期する
- seed 内で Annex A が 93 件、各 ISO 管理策に対応表があり、各リスク雛形に統制リンクがあることを検査する

**明示的に保証しないこと**：この投入は適用宣言書の最終判断、管理策の運用実施、承認、証跡、
残存リスクの受容を完了させない。これらは個別の SoA・リスク評価・証跡レビューで確定する。
