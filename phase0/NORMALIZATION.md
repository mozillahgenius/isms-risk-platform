# カルテ_リスクマップ の正規化規則 — `norm/v1`

Phase 0 の受入は「既存 xlsx を投入 → DB → 再出力した xlsx の内容が入力と一致（機械 diff で差分 0 件）」。
**xlsx のバイナリ比較では判定できない**（作成日時・XML の並び・スタイル・共有文字列表で必ず差が出る）。
そこで「何をもって一致とするか」を規則として固定し、**規則そのものをテストの対象にする**。

実装は `phase0/karte.py`。規則を変えたらバージョン（`NORM_VERSION`）を上げる。

---

## 1. 対象と対象外

| シート | 扱い |
|---|---|
| `カルテ_リスクマップ` | **比較対象**。ここが差分 0 件でなければ不合格 |
| `リスクマップ_AUTO` | 対象外（入力から決定的に再生成される派生物）。ただし別途ゴールデンテストで担保する |
| `ヒートマップ_AUTO` | 同上 |
| `リスクマップマスタ` | 対象外（テナントデータではなく `catalog.risk_scenario_templates` へ入る）。件数と代表レコードを別テストで確認する |

**「対象外」にしただけでは、AUTO の生成が壊れても受入が通ってしまう。**
そのため `phase0/golden/auto_sheets.json` に期待値を固定し、再生成が一致することを検査する
（`run_acceptance.sh` 工程 8）。

---

## 2. 列の対応

入力側のヘッダは 2 系統ある。実テンプレートと既存 `build_risk_map.py` で名前が食い違う。
**正準名は builder 側**（`build_risk_map.py` を無改変で呼ぶため）。

| 実テンプレート | builder（正準） | DB の格納先 |
|---|---|---|
| `RiskItem` | `RiskItem` | `app.risk_scenarios.area` と `phase`（機能領域とPhase。例 `経理・税務` / `1`） |
| `BigCategory` | `Big` | `app.risk_scenarios.theme`（課題テーマ） |
| `MidCategory` | `Mid` | `app.risk_scenarios.measure`（施策） |
| `SmallFrame` | `Frame` | `app.risk_scenarios.frame` |
| `Summary` | `Summary` | `app.risk_scenarios.summary` |
| `ProbBefore` | `ProbBefore` | `app.risk_assessments.prob` |
| `ImpactBefore` | `ImpactBefore` | `app.risk_assessments.impact_biz` |
| `ActionPlan` | `Action` | `app.risk_treatments.action_plan` |
| `ProbAfter` | `ProbAfter` | `app.risk_treatments.prob_after` |
| `ImpactAfter` | `ImpactAfter` | `app.risk_treatments.impact_biz_after` |

**業務キー** = `(RiskItem, Big, Mid, Frame, Summary)`
＝ DB の `(domain, theme, measure, frame, summary)`。

この対応は列名の付け替えではなく**意味の写像**なので、
`run_acceptance.sh` 工程 3 が DB から直接 SELECT して期待値と突き合わせる。

### ヘッダの検査（黙って無視しない）

次はすべてエラーにする。

- 未知の列がある
- 必須の列が足りない
- 2 つの列が同じ正準名へ写る（例: `Big` と `BigCategory` が同居）
- 同じ列名が重複する

末尾の完全に空の列だけは無視する。

---

## 3. 値の正規化

### 文字列（`RiskItem` / `Big` / `Mid` / `Frame` / `Summary` / `Action`）

1. **Unicode NFC**。**NFKC は使わない** — NFKC は全角括弧 `（）` や全角英数字を半角へ畳み、
   台帳の値そのものを書き換える（実測: `人事・労務（Phase1）` → `人事・労務(Phase1)`）。
   往復では辻褄が合うが、DB に入る値が原本と変わるのは正規化ではなく改変
2. NBSP（U+00A0）と全角空白（U+3000）を半角空白へ
3. 改行を LF へ統一（CRLF / CR → LF）
4. 各行の前後の空白を除去し、行内の連続空白を 1 個へ畳む
5. 全体の前後の空白を除去
6. **大小文字は変換しない**（日本語主体の台帳で誤変換の害が大きい）
7. `NULL` と空文字は同一視して「空」とする。ただし業務キー 5 項目が空ならエラー
8. 数値セルに入っていた文字列項目は、整数なら文字列化して扱う（非整数はエラー）

### 数値（`ProbBefore` / `ImpactBefore` / `ProbAfter` / `ImpactAfter`）

- セルが数値でも文字列でも同じ値として扱う（文字列は NFKC を通してからパース）
- **非整数は切り捨てずエラー**（`1.5` はエラー）
- 1〜5 の範囲外はエラー
- 空はエラー（必須）

### 出現したらエラーにするもの

- 真偽値・日付・Decimal（この帳票には出現しない）
- 数式セル。`data_only=True` はキャッシュを読むだけで、キャッシュが古くても検知できない
  （＝黙って古い値を通す）ため、数式そのものを拒否する
- Excel のエラー値（`#REF!` `#VALUE!` `#DIV/0!` `#NAME?` `#N/A` `#NULL!` `#NUM!`）

### 行

- 全列が空の行は「行」として数えない（末尾の空行を含む）
- 結合セルは値を持つ左上のセルのみ採用する
- **非表示行も除外しない**（除外は静かな取りこぼしになる）
- 業務キーの重複はエラー（台帳として重複行は誤り。multiset 比較にはしない）

---

## 4. 並び順と直列化

- 行順は意味を持たないと定義し、**業務キーで並べ替えてから比較**する
- 並びは Python 側で**コードポイント順**、DB 側は `COLLATE "C"` を明示する
  （ロケール差で結果が変わらないようにする）
- 直列化は **JSON Lines**。1 行 1 レコード、キーは正準列の順、
  `ensure_ascii=False` / `sort_keys=True` / 区切りは `,` と `:`（余分な空白を入れない）
- ダイジェストは直列化した **UTF-8 バイト列の SHA-256**（16 進小文字）

---

## 5. 仕様として明文化する差分

設計書の受入は「差分が出る箇所は仕様として明文化されている」ことを求める。該当は次の 3 つ。

1. **ヘッダ名**：入力が実テンプレート形式（`BigCategory` 等）でも、出力は builder の
   正準名（`Big` 等）になる。別名表で吸収し、値としては一致する
2. **シート構成**：入力の `リスクマップマスタ` は出力に含まれない
   （テナントデータではなく `catalog` へ入るため）。件数と代表レコードは別テストで確認する
3. **AUTO 2 シート**：入力側の内容とは比較しない（入力から決定的に再生成される派生物のため）。
   代わりにゴールデンとの一致を検査する

---

## 6. 逆向き検証

規則が機能していることを、**壊して落ちることで**確認する（`run_acceptance.sh` 工程 6・7）。

- 出力の 1 セルを書き換えると diff が落ちる
- `Big` と `BigCategory` が同居する入力は「列の衝突」で落ちる
- `1.5` は切り捨てられず「非整数」で落ちる

---

## 7. 入力 fixture

`phase0/make_fixture.py` が **`build_risk_map.py` を使わずに** openpyxl で直接生成する。
生成器と検証器が同じコードだと、往復で確かめられるのは自己整合性だけで、
相互運用性の検証にならないため。

fixture のデータは顧客の実データを含まない（`make_fixture.py` に書いてあるものが全て）。
前後の空白・全角空白・改行・3 観点すべてを意図的に含めてある。
