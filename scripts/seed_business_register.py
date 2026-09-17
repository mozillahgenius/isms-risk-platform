#!/usr/bin/env python3
"""自社（テナント）のリスク台帳の初期案を冪等に投入する。

入れるもの:
  1. 資産台帳     app.assets（＋枠組みタグ）
  2. 施策マスタ   app.measures（＋枠組みタグ）
  3. リスク台帳   app.risk_scenarios（＋枠組みタグ・関連資産）
  4. 評価の履歴   app.risk_evaluation_snapshots（固有／施策前／施策後）
  5. 監査用の評価 app.risk_criteria → app.risk_assessments → app.risk_treatments

5 を入れるのは、施策の画面が出す「関連リスク」が app.risk_treatments を数えているため。
4 だけ入れても施策の関連リスクは 0 件のままで、台帳が繋がって見えない。

すべて **初期案・未承認**。source_note と rationale にその旨を残す。
承認済みに見せない（approved_by / approved_at は入れない）。

冪等の効き方が 2 種類あることに注意する:
  - 台帳（資産・施策・リスク・枠組みタグ）は **収束する**。名前も内容もタグも、
    流すたびにこの表のとおりに揃う（余った枠組みタグは外す）。
    ただし **status（active/retired、planned/in_progress/done）には触らない**。
    そこは運用が動かす欄で、seed が上書きすると「完了にした施策が planned へ戻る」
    「廃止した資産が復活する」ことになる。台帳の中身と運用の状態は別の持ち物。
  - 評価の履歴（snapshots / assessments / treatments）は **追記のみ**。
    既に在る行を書き換えない。評価を変えるときは、新しい評価日で足す
    （assessed_on / valid_from が実質の鍵になっている）。
    ここを上書きにすると、いつ何をどう評価したかという記録の意味が消える。

枠組みタグの使い分け:
  RISK-MANAGEMENT … 自社のリスク台帳として横断で見るもの（全件）
  ISO27001:2022   … 情報セキュリティの管理策で扱うもの
  IPO-KARTE       … 上場準備の水準（意思決定の記録・職務権限・月次決算・
                    関連当事者取引・労務・反社チェック）で見るもの
                    ※ 当社は合同会社であり、株式会社の機関設計とは異なる。
                      ここでは「上場準備支援で顧客に求める水準を自社にも当てる」
                      という位置づけで台帳に載せる。
"""

from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

SOURCE = "Kaname 会社概要・規範体系を元にした初期案。未承認"
ASSESSED_ON = "DATE '2026-08-01'"
AFTER_ON = "DATE '2026-08-15'"

ISMS = ("RISK-MANAGEMENT", "ISO27001:2022")
IPO = ("RISK-MANAGEMENT", "IPO-KARTE")
BOTH = ("RISK-MANAGEMENT", "ISO27001:2022", "IPO-KARTE")


def literal(value: object) -> str:
    if value is None:
        return "NULL"
    text = str(value).replace("'", "''")
    return f"'{text}'"


def read_token() -> str:
    value = os.environ.get("ISMS_WEB_TENANT_TOKEN", "").strip()
    if value:
        return value
    env_path = ROOT / "web" / ".env.local"
    if env_path.exists():
        for line in env_path.read_text(encoding="utf-8").splitlines():
            if line.startswith("ISMS_WEB_TENANT_TOKEN="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit("ISMS_WEB_TENANT_TOKEN がありません。web/.env.local または環境変数を確認してください。")


# --- 資産台帳 ---------------------------------------------------------------
# (key, 名称, 種類, 内容, 区分, 枠組み)
ASSETS = [
    ("AST-001", "顧客・案件情報", "customer_data",
     "顧客名、案件、連絡先、成果物、進行状況。Kaname の案件・顧客情報を含む。", "confidential", ISMS),
    ("AST-002", "Google Workspace の組織データ", "workspace",
     "Gmail、ドライブ、カレンダー、共有設定、OAuth 連携アプリ、管理コンソールの設定。", "confidential", ISMS),
    ("AST-003", "ソースコード・本番運用基盤", "software_platform",
     "isms-platform、Kaname、各種自動化のソースコードと、その本番配備先の設定。", "confidential", ISMS),
    ("AST-004", "契約・法務・上場準備資料", "legal_corporate",
     "契約書、規程、法務相談、上場準備支援の資料、監査・認証の証跡。", "top_secret", BOTH),
    ("AST-005", "発信・メディア資産", "media_content",
     "The Governance OS ほか自社メディアの記事、動画、ブランド素材、公開前の原稿。", "internal", ISMS),
    ("AST-006", "請求・売上データ", "financial_data",
     "請求、入金、案件別の売上と原価、資金繰りの見通し。", "confidential", BOTH),
    ("AST-007", "認証情報・鍵", "identity_access",
     "SSO、API キー、トークン、サービスアカウント、バックアップの鍵。値は専用の保管先にのみ置く。",
     "top_secret", ISMS),
    ("AST-008", "AIエージェント運用資産", "operating_knowhow",
     "Claude Code・Codex 等の運用規範、プロンプト、スキル、フック、実行ログ。", "internal", ISMS),
    ("AST-009", "会計・税務データ", "financial_data",
     "会計 SaaS の仕訳、試算表、決算、申告関連の資料。", "confidential", BOTH),
    ("AST-010", "人事・労務情報", "hr_data",
     "役員・従業者・業務委託先の個人情報、契約、勤怠、報酬に関する情報。", "top_secret", BOTH),
    ("AST-011", "Kaname（組織ナレッジ基盤）", "knowledge_base",
     "組織ナレッジの正本。ノート、案件、顧客、監査ログ、コネクタ設定を保持する。", "confidential", ISMS),
    ("AST-012", "顧客から預かった業務データ", "customer_data",
     "受託業務のために顧客から預かる実データ（会計・人事・営業・システムのデータ）。", "top_secret", ISMS),
    ("AST-013", "上場準備支援の未公表情報", "customer_data",
     "顧客の資本政策、未公表の業績、上場スケジュール等、外部に出れば重大な影響が及ぶ情報。",
     "top_secret", BOTH),
    ("AST-014", "SNS・メディア運用アカウント", "account",
     "YouTube、X、Instagram、LinkedIn 等の投稿権限と、投稿予約ツールの設定。", "confidential", ISMS),
    ("AST-015", "AIサービスの利用アカウント", "external_service",
     "生成 AI・音声合成・画像生成等の API 利用アカウントと、その利用履歴・費用。", "confidential", ISMS),
    ("AST-016", "サーバ・常駐実行基盤", "infrastructure",
     "VPS と Mac mini 上の常駐サービス、定期実行、バックアップ、監視の設定。", "confidential", ISMS),
    ("AST-017", "業務用端末", "endpoint",
     "業務に用いる Mac 端末。暗号化、画面施錠、更新の適用状況を含む。", "confidential", ISMS),
    ("AST-018", "意思決定・稟議の記録", "governance_record",
     "重要な意思決定、承認、稟議、社内規程の制定改廃の記録。", "confidential", IPO),
]

# --- 施策マスタ -------------------------------------------------------------
# (key, 名称, 内容, 対応方針, 枠組み)
MEASURES = [
    ("M-001", "Google Workspace の権限棚卸",
     "四半期ごとに、アカウント、共有ドライブ、外部共有、OAuth 連携アプリを確認し、不要な権限を外す。実施結果を記録する。",
     "mitigate", ISMS),
    ("M-002", "顧客データの共有前レビュー",
     "顧客・案件情報を外部へ送る前に、宛先、目的、送る項目の必要性、契約上の許可を確認し、記録を残す。",
     "mitigate", ISMS),
    ("M-003", "リポジトリの秘密情報スキャン",
     "コミット・ビルド成果物に秘密情報が含まれないことを自動検査し、検知したら直ちに失効・再発行する。",
     "mitigate", ISMS),
    ("M-004", "バックアップ復元演習",
     "四半期ごとに、重要データのバックアップから実際に復元できることを試し、所要時間と欠損を記録する。",
     "mitigate", ISMS),
    ("M-005", "AIエージェントの外部送信レビュー",
     "AI に渡す情報、利用するモデル、送信先、保持期間を確認する。極秘は入力せず、顧客情報は分離する。",
     "mitigate", ISMS),
    ("M-006", "契約・法務資料の分類と承認",
     "契約・上場準備資料を区分し、共有・送付のたびに担当者と承認者を明確にして記録する。",
     "mitigate", BOTH),
    ("M-007", "発信前の内部情報チェック",
     "公開前の原稿・動画について、顧客名、非公開の数値、認証情報、契約情報が残っていないか確認する。",
     "mitigate", ISMS),
    ("M-008", "担当変更・契約終了時の権限剥奪",
     "退職・異動・案件終了・委託終了のつど、アカウント、共有、API、端末の権限を外し、確認を記録する。",
     "mitigate", ISMS),
    ("M-009", "規程体系の整備と年次見直し",
     "標準規程 28 本を自社の運用に合わせて確認し、年に1回および重要な変更のつど見直して承認を得る。",
     "mitigate", BOTH),
    ("M-010", "年次の情報セキュリティ教育",
     "年に1回、全員に教育を実施する。実際に起きた事例と報告の方法を含め、理解度と受講の記録を残す。",
     "mitigate", ISMS),
    ("M-011", "内部監査の実施",
     "年に1回、規程どおりに運用されているかを、記録と設定の実測で確認する。自分が実施した業務は監査しない。",
     "mitigate", BOTH),
    ("M-012", "マネジメントレビューの実施",
     "年に1回、監査結果・測定結果・インシデント・リスクの状況を入力として評価し、決定事項を記録する。",
     "mitigate", BOTH),
    ("M-013", "資産台帳の棚卸",
     "年に1回、資産台帳と実際に使っているサービス・端末・データを突き合わせ、差分を是正する。",
     "mitigate", ISMS),
    ("M-014", "端末設定の点検",
     "月に1回、業務端末の暗号化・画面自動施錠・更新の適用・マルウェア対策の状態を実測で確認する。",
     "mitigate", ISMS),
    ("M-015", "ログ取得と定期確認",
     "認証、権限変更、管理者操作の記録を取得し、月に1回確認する。取得できていない期間は「読めていない」として記録する。",
     "mitigate", ISMS),
    ("M-016", "脆弱性と依存関係の更新",
     "利用中のソフトウェアと依存ライブラリの脆弱性情報を確認し、深刻度に応じた期限内に更新して結果を確認する。",
     "mitigate", ISMS),
    ("M-017", "クラウドサービスの届出と棚卸",
     "業務で使う外部サービスを台帳へ登録し、四半期ごとに利用者・権限・外部共有・不要な契約を点検する。",
     "mitigate", ISMS),
    ("M-018", "委託先・提供者の年次評価",
     "情報を預ける委託先とクラウド提供者について、半期ごとに管理体制と権限を確認し、記録を残す。",
     "mitigate", BOTH),
    ("M-019", "インシデント対応手順の整備と訓練",
     "報告経路、初動、外部連絡の期限を定め、年に1回、想定事例で手順を通して確かめる。",
     "mitigate", BOTH),
    ("M-020", "重要な意思決定の記録",
     "投資、契約、体制、規程の制定改廃など重要な決定を、日付・根拠・決定者とともに記録して保管する。",
     "mitigate", IPO),
    ("M-021", "職務権限と承認の運用",
     "金額と種類に応じた承認者を定め、実行前の承認と、その証跡が残る形で運用する。",
     "mitigate", IPO),
    ("M-022", "月次決算の早期化と予実管理",
     "毎月、期限を決めて締め、予算と実績の差異を確認し、差異の理由を記録する。",
     "mitigate", IPO),
    ("M-023", "関連当事者取引の把握",
     "代表者および関係会社との取引を洗い出し、条件の妥当性を確認して記録する。",
     "mitigate", IPO),
    ("M-024", "労務管理の適正化",
     "勤務時間と業務委託先への指揮命令の実態を確認し、契約の形式と実態が食い違わないようにする。",
     "mitigate", IPO),
    ("M-025", "取引先の反社会的勢力チェック",
     "新規の取引先と委託先について、契約前に確認を行い、確認日と方法を記録する。",
     "mitigate", IPO),
    ("M-026", "海外拠点の管理",
     "海外拠点の口座・契約・帳簿・提出物の状況を定期的に確認し、国内と同じ記録の水準を保つ。",
     "mitigate", IPO),
]

# --- リスク台帳 -------------------------------------------------------------
# (key, phase, 領域, 課題テーマ, 施策（リスク雛形の列）, 観点, 要約, 資産, 施策, 枠組み)
RISKS = [
    ("RISK-001", 1, "顧客・案件管理", "共有・送付", "顧客データ誤共有", "管理可能性",
     "顧客・案件情報が誤った宛先や不要な共有設定により外部へ開示される。",
     ["AST-001", "AST-012"], ["M-002"], ISMS),
    ("RISK-002", 2, "組織ナレッジ管理", "権限棚卸", "Google Workspace権限残存", "管理可能性",
     "退職・担当変更後も Google Workspace や組織ナレッジへの権限が残り、不要な閲覧や変更が起きる。",
     ["AST-002", "AST-011"], ["M-001", "M-008"], ISMS),
    ("RISK-003", 3, "開発・本番運用", "秘密情報管理", "ソースコード・秘密情報の誤公開", "管理可能性",
     "ソースコード、環境変数、トークンがリポジトリやビルド成果物に混入し、外部へ公開される。",
     ["AST-003", "AST-007"], ["M-003"], ISMS),
    ("RISK-004", 1, "契約・法務管理", "送付・承認", "契約・上場準備資料の誤送付", "管理可能性",
     "契約書や顧客の未公表情報が、承認されていない相手や経路へ送付される。",
     ["AST-004", "AST-013"], ["M-006"], BOTH),
    ("RISK-005", 5, "継続・復旧", "バックアップ", "バックアップ復元不能", "スピード",
     "障害や誤操作の後にバックアップから重要データを復元できず、事業継続が遅れる。",
     ["AST-003", "AST-016"], ["M-004"], ISMS),
    ("RISK-006", 4, "AI・自動化運用", "外部送信", "AI・エージェントによる外部送信", "管理可能性",
     "AI エージェントが顧客情報や社内情報を意図しない外部サービスへ送信する。",
     ["AST-008", "AST-015"], ["M-005"], ISMS),
    ("RISK-007", 4, "発信・営業", "公開前確認", "発信データと内部情報の混同", "精度",
     "発信コンテンツに顧客名、非公開の数値、契約情報などの内部情報が混入する。",
     ["AST-005", "AST-014"], ["M-007"], ISMS),
    ("RISK-008", 2, "財務・請求管理", "完全性", "請求データの完全性低下", "精度",
     "請求や売上データの入力・変更誤りにより、判断や顧客への請求が不正確になる。",
     ["AST-006"], ["M-022"], BOTH),
    ("RISK-009", 3, "ISMS運用", "規程整備", "規程と実態の乖離", "管理可能性",
     "規程は在るが実際の運用と食い違い、監査・審査で不適合となる。",
     ["AST-004"], ["M-009", "M-011"], BOTH),
    ("RISK-010", 3, "ISMS運用", "教育", "教育未実施による誤操作", "管理可能性",
     "教育を実施しないまま運用が続き、報告の遅れや設定の誤りが起きる。",
     ["AST-008"], ["M-010"], ISMS),
    ("RISK-011", 4, "ISMS運用", "内部監査", "内部監査の未実施・独立性の欠如", "管理可能性",
     "少人数のため、自らが実施した業務を自ら監査し、不適合を見落とす。",
     ["AST-004"], ["M-011", "M-012"], BOTH),
    ("RISK-012", 2, "情報資産管理", "棚卸", "資産台帳と実態の不一致", "精度",
     "使っているサービス・端末・データが台帳に載らず、守る対象から漏れる。",
     ["AST-011", "AST-017"], ["M-013", "M-017"], ISMS),
    ("RISK-013", 3, "端末管理", "端末の紛失・盗難", "端末紛失による情報流出", "管理可能性",
     "業務端末の紛失・盗難により、保存された顧客情報や認証情報が第三者に渡る。",
     ["AST-017", "AST-007"], ["M-014", "M-008"], ISMS),
    ("RISK-014", 4, "監視・検知", "ログ", "ログ未取得による追跡不能", "スピード",
     "記録が取得されておらず、事象が起きたときに影響範囲を特定できない。",
     ["AST-016", "AST-002"], ["M-015"], ISMS),
    ("RISK-015", 3, "開発・本番運用", "脆弱性管理", "既知の脆弱性の放置", "管理可能性",
     "利用中のソフトウェアや依存ライブラリの既知の脆弱性が更新されないまま残る。",
     ["AST-003", "AST-016"], ["M-016"], ISMS),
    ("RISK-016", 2, "クラウド利用", "野良利用", "未把握のクラウド利用", "管理可能性",
     "届け出のない外部サービスへ業務の情報が入り、管理の外に置かれる。",
     ["AST-015", "AST-002"], ["M-017"], ISMS),
    ("RISK-017", 4, "委託先管理", "委託先事故", "委託先経由の情報漏えい", "管理可能性",
     "委託先やクラウド提供者で事故が起き、預けた情報が流出する。",
     ["AST-012", "AST-015"], ["M-018"], BOTH),
    ("RISK-018", 5, "インシデント対応", "初動", "インシデント対応の遅延", "スピード",
     "報告経路と初動が定まっておらず、法令・契約が求める期限内に対応・通知ができない。",
     ["AST-012", "AST-010"], ["M-019"], BOTH),
    ("RISK-019", 1, "ガバナンス", "意思決定の記録", "意思決定の記録不備", "管理可能性",
     "重要な決定の日付・根拠・決定者が残らず、後から経緯を説明できない。",
     ["AST-018"], ["M-020", "M-021"], IPO),
    ("RISK-020", 2, "経理・決算", "月次決算", "月次決算の遅延", "スピード",
     "月次の締めが遅れ、予実の差異と資金の見通しを早期に把握できない。",
     ["AST-009", "AST-006"], ["M-022"], IPO),
    ("RISK-021", 3, "ガバナンス", "関連当事者取引", "関連当事者取引の未把握", "管理可能性",
     "代表者・関係会社との取引が把握・記録されず、条件の妥当性を説明できない。",
     ["AST-009", "AST-018"], ["M-023"], IPO),
    ("RISK-022", 3, "労務管理", "実態と契約の乖離", "労務管理の不備", "管理可能性",
     "勤務・指揮命令の実態が契約の形式と食い違い、労務上の指摘を受ける。",
     ["AST-010"], ["M-024"], IPO),
    ("RISK-023", 1, "取引先審査", "反社チェック", "取引先審査の漏れ", "管理可能性",
     "新規の取引先・委託先の確認を行わないまま契約し、後から解消が必要になる。",
     ["AST-004", "AST-018"], ["M-025"], IPO),
    ("RISK-024", 5, "海外拠点", "記録の水準", "海外拠点の記録不備", "管理可能性",
     "海外拠点の契約・帳簿・提出物の記録が国内と同じ水準で残らない。",
     ["AST-009", "AST-018"], ["M-026"], IPO),
]

# risk_key -> (固有の発生可能性, C, I, A, 施策前の可能性, 施策前の影響, 施策後の可能性, 施策後の影響)
# 固有の影響度は max(C, I, A)。DB のトリガが式との一致を検査する。
SCORES = {
    "RISK-001": (4, 4, 3, 2, 4, 4, 2, 3),
    "RISK-002": (4, 4, 3, 2, 4, 4, 2, 3),
    "RISK-003": (3, 5, 4, 2, 3, 5, 2, 3),
    "RISK-004": (3, 5, 3, 2, 3, 5, 1, 3),
    "RISK-005": (3, 2, 4, 5, 3, 5, 2, 3),
    "RISK-006": (4, 5, 3, 2, 4, 5, 2, 3),
    "RISK-007": (3, 4, 3, 1, 3, 4, 1, 2),
    "RISK-008": (3, 2, 4, 2, 3, 4, 1, 3),
    "RISK-009": (4, 3, 4, 2, 4, 4, 2, 3),
    "RISK-010": (4, 3, 3, 2, 4, 3, 2, 3),
    "RISK-011": (4, 3, 4, 2, 4, 4, 2, 3),
    "RISK-012": (4, 3, 3, 2, 4, 3, 2, 3),
    "RISK-013": (2, 5, 3, 3, 2, 5, 1, 4),
    "RISK-014": (3, 3, 4, 2, 3, 4, 2, 3),
    "RISK-015": (3, 4, 4, 3, 3, 4, 2, 3),
    "RISK-016": (3, 4, 3, 2, 3, 4, 2, 3),
    "RISK-017": (2, 5, 4, 3, 2, 5, 2, 4),
    "RISK-018": (3, 4, 3, 4, 3, 4, 2, 3),
    "RISK-019": (4, 2, 4, 2, 4, 4, 2, 3),
    "RISK-020": (4, 1, 4, 3, 4, 4, 2, 3),
    "RISK-021": (3, 3, 4, 1, 3, 4, 2, 3),
    "RISK-022": (3, 3, 3, 2, 3, 3, 2, 2),
    "RISK-023": (3, 2, 4, 2, 3, 4, 1, 3),
    "RISK-024": (3, 3, 4, 2, 3, 4, 2, 3),
}


# ISO/IEC 27001:2022 附属書 A の各管理策を、自社のリスクへ結ぶ初期案。
# 管理策の実施済みを意味しない。資産 → リスク → 施策 → 管理策のレビュー経路を
# 先に作り、適用判断・SoA・証拠の登録は別の承認工程で行う。
CONTROL_RISK_GROUPS = [
    ("5", range(1, 9), ("RISK-004", "RISK-009", "RISK-011")),
    ("5", range(9, 15), ("RISK-001", "RISK-004", "RISK-007", "RISK-008", "RISK-012")),
    ("5", range(15, 19), ("RISK-002", "RISK-003", "RISK-013")),
    ("5", range(19, 24), ("RISK-004", "RISK-016", "RISK-017")),
    ("5", range(24, 31), ("RISK-005", "RISK-014", "RISK-018")),
    ("5", range(31, 38), ("RISK-004", "RISK-007", "RISK-009", "RISK-011")),
    ("6", range(1, 9), ("RISK-002", "RISK-010", "RISK-013", "RISK-018")),
    ("7", range(1, 15), ("RISK-005", "RISK-012", "RISK-013")),
    ("8", range(1, 6), ("RISK-002", "RISK-003", "RISK-013")),
    ("8", range(6, 11), ("RISK-003", "RISK-005", "RISK-015")),
    ("8", range(11, 15), ("RISK-001", "RISK-004", "RISK-005", "RISK-006")),
    ("8", range(15, 20), ("RISK-003", "RISK-014", "RISK-015")),
    ("8", range(20, 25), ("RISK-003", "RISK-006", "RISK-014", "RISK-015")),
    ("8", range(25, 35), ("RISK-003", "RISK-005", "RISK-009", "RISK-015")),
]


def build_control_risk_map() -> dict[str, tuple[str, ...]]:
    mapping: dict[str, tuple[str, ...]] = {}
    for family, numbers, risk_keys in CONTROL_RISK_GROUPS:
        for number in numbers:
            code = f"A.{family}.{number}"
            if code in mapping:
                raise ValueError(f"ISO管理策の重複割当: {code}")
            mapping[code] = risk_keys
    expected = 93
    if len(mapping) != expected:
        raise ValueError(f"ISO管理策の割当が {len(mapping)} 件（想定 {expected}）")
    return mapping


CONTROL_RISK_MAP = build_control_risk_map()


def framework_rows(table: str, id_column: str, source_table: str, key_column: str,
                   key: str, frameworks: tuple[str, ...]) -> list[str]:
    """枠組みタグを、この表が望む集合そのものに合わせる。

    足すだけにすると、割り当てを変えたときに**前のタグが残る**。
    残ったタグの分だけ、その枠組みの台帳に出続けるので、先に余りを外す。
    """
    wanted = ", ".join(literal(f) for f in frameworks)
    out = [
        f"DELETE FROM app.{table} t USING app.{source_table} s "
        f"WHERE t.tenant_id = app.current_tenant() AND s.tenant_id = t.tenant_id "
        f"AND s.id = t.{id_column} AND s.{key_column} = {literal(key)} "
        f"AND t.framework_key NOT IN ({wanted});"
    ]
    for framework in frameworks:
        out.append(
            f"INSERT INTO app.{table} (tenant_id, {id_column}, framework_key) "
            f"SELECT app.current_tenant(), id, {literal(framework)} FROM app.{source_table} "
            f"WHERE tenant_id=app.current_tenant() AND {key_column}={literal(key)} "
            "ON CONFLICT DO NOTHING;"
        )
    return out


def build_sql(token: str) -> str:
    lines = [
        "BEGIN;",
        f"SELECT app.set_tenant_context({literal(token)});",
    ]

    # 1. 資産
    for key, name, asset_type, description, classification, frameworks in ASSETS:
        lines.append(
            "INSERT INTO app.assets (tenant_id, asset_key, name, asset_type, description, classification, source_note) "
            f"VALUES (app.current_tenant(), {literal(key)}, {literal(name)}, {literal(asset_type)}, "
            f"{literal(description)}, {literal(classification)}, {literal(SOURCE)}) "
            "ON CONFLICT (tenant_id, asset_key) DO UPDATE SET name=EXCLUDED.name, asset_type=EXCLUDED.asset_type, "
            "description=EXCLUDED.description, classification=EXCLUDED.classification, "
            "source_note=EXCLUDED.source_note, updated_at=now();"
        )
        lines.extend(framework_rows("asset_frameworks", "asset_id", "assets", "asset_key", key, frameworks))

    # 2. 施策
    for key, name, summary, strategy, frameworks in MEASURES:
        lines.append(
            "INSERT INTO app.measures (tenant_id, measure_key, name, summary, strategy, source_note) "
            f"VALUES (app.current_tenant(), {literal(key)}, {literal(name)}, {literal(summary)}, "
            f"{literal(strategy)}, {literal(SOURCE)}) "
            "ON CONFLICT (tenant_id, measure_key) DO UPDATE SET name=EXCLUDED.name, summary=EXCLUDED.summary, "
            "strategy=EXCLUDED.strategy, source_note=EXCLUDED.source_note, updated_at=now();"
        )
        lines.extend(framework_rows("measure_frameworks", "measure_id", "measures", "measure_key", key, frameworks))

    # 3. 有効なリスク基準（監査用の評価に要る）。無いときだけ作る。
    lines.append(
        "INSERT INTO app.risk_criteria (tenant_id, dom_version_id, impact_sec_formula, "
        "band_top_priority, band_action, band_consider, band_accept, valid_from) "
        "SELECT app.current_tenant(), v.id, c.impact_sec_formula, c.band_top_priority, c.band_action, "
        f"c.band_consider, c.band_accept, {ASSESSED_ON} "
        "FROM catalog.dom_versions v JOIN catalog.risk_criteria_default c ON c.dom_version_id = v.id "
        "WHERE v.is_current AND NOT EXISTS ("
        "SELECT 1 FROM app.risk_criteria WHERE tenant_id=app.current_tenant() AND valid_to IS NULL);"
    )

    # 4. リスク・関連資産・評価履歴・監査用の評価と対応
    for (risk_key, phase, area, theme, risk_measure, frame, summary,
         asset_keys, measure_keys, frameworks) in RISKS:
        prob, conf, integ, avail, before_p, before_i, after_p, after_i = SCORES[risk_key]
        impact_sec = max(conf, integ, avail)

        lines.append(
            "INSERT INTO app.risk_scenarios (tenant_id, risk_key, domain, area, phase, theme, measure, frame, summary, status) "
            f"VALUES (app.current_tenant(), {literal(risk_key)}, {literal(area)}, {literal(area)}, {phase}, "
            f"{literal(theme)}, {literal(risk_measure)}, {literal(frame)}, {literal(summary)}, 'active') "
            "ON CONFLICT (tenant_id, risk_key) DO UPDATE SET domain=EXCLUDED.domain, area=EXCLUDED.area, "
            "phase=EXCLUDED.phase, theme=EXCLUDED.theme, measure=EXCLUDED.measure, frame=EXCLUDED.frame, "
            "summary=EXCLUDED.summary, updated_at=now();"
        )
        lines.extend(framework_rows(
            "risk_scenario_frameworks", "risk_scenario_id", "risk_scenarios", "risk_key", risk_key, frameworks))

        # 関連資産は貼り直す（並びと主従を毎回同じにする）
        lines.append(
            "DELETE FROM app.risk_scenario_assets WHERE tenant_id=app.current_tenant() "
            "AND risk_scenario_id=(SELECT id FROM app.risk_scenarios "
            f"WHERE tenant_id=app.current_tenant() AND risk_key={literal(risk_key)});"
        )
        for index, asset_key in enumerate(asset_keys):
            relation = "primary" if index == 0 else "secondary"
            lines.append(
                "INSERT INTO app.risk_scenario_assets (tenant_id, risk_scenario_id, asset_id, relation) "
                f"SELECT app.current_tenant(), r.id, a.id, {literal(relation)} "
                "FROM app.risk_scenarios r JOIN app.assets a ON a.tenant_id=r.tenant_id "
                f"AND a.asset_key={literal(asset_key)} "
                f"WHERE r.tenant_id=app.current_tenant() AND r.risk_key={literal(risk_key)} "
                "ON CONFLICT DO NOTHING;"
            )

        # 表示用の評価スナップショット（固有／施策前）
        for stage, on, p, i, rationale in (
            ("inherent", ASSESSED_ON, prob, impact_sec, "施策を考慮しない固有リスクの初期評価。未承認。"),
            ("before_measure", ASSESSED_ON, before_p, before_i, "現状の運用を前提にした施策実施前の初期評価。未承認。"),
        ):
            lines.append(
                "INSERT INTO app.risk_evaluation_snapshots (tenant_id, risk_scenario_id, stage, assessed_on, "
                "probability, impact, rationale, source_note) "
                f"SELECT app.current_tenant(), id, {literal(stage)}, {on}, {p}, {i}, "
                f"{literal(rationale)}, {literal(SOURCE)} "
                f"FROM app.risk_scenarios WHERE tenant_id=app.current_tenant() AND risk_key={literal(risk_key)} "
                "AND NOT EXISTS (SELECT 1 FROM app.risk_evaluation_snapshots s "
                "WHERE s.tenant_id=app.current_tenant() AND s.risk_scenario_id=app.risk_scenarios.id "
                f"AND s.stage={literal(stage)} AND s.assessed_on={on});"
            )

        # 監査用の評価（1 シナリオにつき有効なもの 1 件）
        lines.append(
            "INSERT INTO app.risk_assessments (tenant_id, risk_scenario_id, risk_criteria_id, status, prob, "
            "confidentiality, integrity, availability, impact_sec, rationale, assessed_by, valid_from) "
            f"SELECT app.current_tenant(), r.id, c.id, 'draft', {prob}, {conf}, {integ}, {avail}, {impact_sec}, "
            f"{literal('初期案。リスクアセスメント手順に基づく暫定評価で、未承認。')}, u.id, {ASSESSED_ON} "
            "FROM app.risk_scenarios r "
            "CROSS JOIN LATERAL (SELECT id FROM app.risk_criteria WHERE tenant_id=app.current_tenant() "
            "AND valid_to IS NULL ORDER BY valid_from DESC LIMIT 1) c "
            "CROSS JOIN LATERAL (SELECT id FROM app.users WHERE tenant_id=app.current_tenant() "
            "AND status='active' ORDER BY created_at LIMIT 1) u "
            f"WHERE r.tenant_id=app.current_tenant() AND r.risk_key={literal(risk_key)} "
            "AND NOT EXISTS (SELECT 1 FROM app.risk_assessments a WHERE a.tenant_id=app.current_tenant() "
            "AND a.risk_scenario_id=r.id AND a.valid_to IS NULL AND a.recorded_until IS NULL);"
        )

        for measure_key in measure_keys:
            # 施策後の評価（表示用）
            lines.append(
                "INSERT INTO app.risk_evaluation_snapshots (tenant_id, risk_scenario_id, measure_id, stage, "
                "assessed_on, probability, impact, rationale, source_note) "
                f"SELECT app.current_tenant(), r.id, m.id, 'after_measure', {AFTER_ON}, {after_p}, {after_i}, "
                f"{literal('施策を実施した場合の残余リスクの初期案。実施・承認後に再評価する。')}, {literal(SOURCE)} "
                "FROM app.risk_scenarios r JOIN app.measures m ON m.tenant_id=r.tenant_id "
                f"AND m.measure_key={literal(measure_key)} "
                f"WHERE r.tenant_id=app.current_tenant() AND r.risk_key={literal(risk_key)} "
                "AND NOT EXISTS (SELECT 1 FROM app.risk_evaluation_snapshots s WHERE s.tenant_id=app.current_tenant() "
                f"AND s.risk_scenario_id=r.id AND s.stage='after_measure' AND s.assessed_on={AFTER_ON} "
                "AND s.measure_id=m.id);"
            )
            # 監査用のリスク対応（施策の「関連リスク」はここを数えている）
            lines.append(
                "INSERT INTO app.risk_treatments (tenant_id, risk_assessment_id, strategy, action_plan, "
                "prob_after, impact_sec_after, status, valid_from, measure_id) "
                f"SELECT app.current_tenant(), a.id, m.strategy, m.name || '：' || m.summary, {after_p}, {after_i}, "
                f"'planned', {ASSESSED_ON}, m.id "
                "FROM app.risk_assessments a "
                "JOIN app.risk_scenarios r ON r.tenant_id=a.tenant_id AND r.id=a.risk_scenario_id "
                f"AND r.risk_key={literal(risk_key)} "
                f"JOIN app.measures m ON m.tenant_id=a.tenant_id AND m.measure_key={literal(measure_key)} "
                "WHERE a.tenant_id=app.current_tenant() AND a.valid_to IS NULL AND a.recorded_until IS NULL "
                "AND NOT EXISTS (SELECT 1 FROM app.risk_treatments t WHERE t.tenant_id=app.current_tenant() "
                "AND t.risk_assessment_id=a.id AND t.measure_id=m.id);"
            )

    # 5. ISO 管理策の適用初期案と、管理策↔自社リスクの対応候補。
    #    既存の現行記録・利用者の追加リンクは上書きしない。
    control_rationale = (
        "自社のISO/IEC 27001:2022附属書A対応の初期案。"
        "資産・リスク・施策との対応は初期紐付けであり、適用判断・実施状況・承認は未完了。"
    )
    for code, risk_keys in CONTROL_RISK_MAP.items():
        lines.append(
            "INSERT INTO app.control_implementations "
            "(tenant_id, control_id, applicability, rationale, status, valid_from) "
            "SELECT app.current_tenant(), c.id, 'applicable', "
            f"{literal(control_rationale)}, 'not_started', {ASSESSED_ON} "
            "FROM catalog.controls c "
            f"WHERE c.framework_key='ISO27001:2022' AND c.code={literal(code)} "
            "AND c.retired_at IS NULL AND NOT EXISTS ("
            "SELECT 1 FROM app.control_implementations ci "
            "WHERE ci.tenant_id=app.current_tenant() AND ci.control_id=c.id "
            "AND ci.valid_to IS NULL AND ci.recorded_until IS NULL);"
        )
        for risk_key in risk_keys:
            lines.append(
                "INSERT INTO app.risk_control_links (tenant_id, risk_scenario_id, control_id) "
                "SELECT app.current_tenant(), r.id, c.id "
                "FROM app.risk_scenarios r CROSS JOIN catalog.controls c "
                f"WHERE r.tenant_id=app.current_tenant() AND r.risk_key={literal(risk_key)} "
                "AND c.framework_key='ISO27001:2022' AND c.retired_at IS NULL "
                f"AND c.code={literal(code)} ON CONFLICT DO NOTHING;"
            )

    # 6. 取りこぼしをその場で落とす。
    #
    # INSERT ... SELECT ... JOIN は、参照先（資産キー・施策キー・利用者）が
    # 見つからないと **黙って 0 行** を入れて成功する。合計件数だけを見ていると、
    # 綴りを 1 文字間違えた行が入っていないことに気づけない。
    # 期待する本数をこの seed 自身が持っているので、突き合わせて落とす。
    asset_keys_sql = ", ".join(literal(a[0]) for a in ASSETS)
    measure_keys_sql = ", ".join(literal(m[0]) for m in MEASURES)
    risk_keys_sql = ", ".join(literal(r[0]) for r in RISKS)
    want_asset_links = sum(len(r[7]) for r in RISKS)
    want_treatments = sum(len(r[8]) for r in RISKS)
    iso_risk_keys = [r[0] for r in RISKS if "ISO27001:2022" in r[9]]
    iso_risk_keys_sql = ", ".join(literal(key) for key in iso_risk_keys)
    want_control_risk_links = sum(len(risk_keys) for risk_keys in CONTROL_RISK_MAP.values())
    lines.append(f"""
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM app.assets
   WHERE tenant_id = app.current_tenant() AND asset_key IN ({asset_keys_sql});
  IF n <> {len(ASSETS)} THEN RAISE EXCEPTION '資産が % 件しか入っていない（想定 {len(ASSETS)}）', n; END IF;

  SELECT count(*) INTO n FROM app.measures
   WHERE tenant_id = app.current_tenant() AND measure_key IN ({measure_keys_sql});
  IF n <> {len(MEASURES)} THEN RAISE EXCEPTION '施策が % 件しか入っていない（想定 {len(MEASURES)}）', n; END IF;

  SELECT count(*) INTO n FROM app.risk_scenarios
   WHERE tenant_id = app.current_tenant() AND risk_key IN ({risk_keys_sql});
  IF n <> {len(RISKS)} THEN RAISE EXCEPTION 'リスクが % 件しか入っていない（想定 {len(RISKS)}）', n; END IF;

  -- リスクと資産の紐付け。綴り違いはここで 0 行になって落ちる。
  SELECT count(*) INTO n
    FROM app.risk_scenario_assets x
    JOIN app.risk_scenarios r ON r.tenant_id = x.tenant_id AND r.id = x.risk_scenario_id
   WHERE x.tenant_id = app.current_tenant() AND r.risk_key IN ({risk_keys_sql});
  IF n <> {want_asset_links} THEN
    RAISE EXCEPTION 'リスクと資産の紐付けが % 件（想定 {want_asset_links}）', n;
  END IF;

  -- 有効な評価が 1 リスクにつき 1 件。
  SELECT count(*) INTO n
    FROM app.risk_assessments a
    JOIN app.risk_scenarios r ON r.tenant_id = a.tenant_id AND r.id = a.risk_scenario_id
   WHERE a.tenant_id = app.current_tenant() AND r.risk_key IN ({risk_keys_sql})
     AND a.valid_to IS NULL AND a.recorded_until IS NULL;
  IF n <> {len(RISKS)} THEN RAISE EXCEPTION '有効なリスク評価が % 件（想定 {len(RISKS)}）', n; END IF;

  -- 施策とリスクの紐付け（画面の「関連リスク」はここを数えている）。
  SELECT count(*) INTO n
    FROM app.risk_treatments t
    JOIN app.risk_assessments a ON a.tenant_id = t.tenant_id AND a.id = t.risk_assessment_id
    JOIN app.risk_scenarios r ON r.tenant_id = a.tenant_id AND r.id = a.risk_scenario_id
   WHERE t.tenant_id = app.current_tenant() AND r.risk_key IN ({risk_keys_sql})
     AND t.measure_id IS NOT NULL;
  IF n <> {want_treatments} THEN
    RAISE EXCEPTION '施策に紐づくリスク対応が % 件（想定 {want_treatments}）', n;
  END IF;

  -- 枠組みタグが 1 つも付いていない行を残さない。
  IF EXISTS (SELECT 1 FROM app.assets a
              WHERE a.tenant_id = app.current_tenant() AND a.asset_key IN ({asset_keys_sql})
                AND NOT EXISTS (SELECT 1 FROM app.asset_frameworks f
                                 WHERE f.tenant_id = a.tenant_id AND f.asset_id = a.id)) THEN
    RAISE EXCEPTION '枠組みタグの無い資産がある';
  END IF;
  IF EXISTS (SELECT 1 FROM app.measures m
              WHERE m.tenant_id = app.current_tenant() AND m.measure_key IN ({measure_keys_sql})
                AND NOT EXISTS (SELECT 1 FROM app.measure_frameworks f
                                 WHERE f.tenant_id = m.tenant_id AND f.measure_id = m.id)) THEN
    RAISE EXCEPTION '枠組みタグの無い施策がある';
  END IF;

  -- 93 管理策すべてに、自社テナントの現行適用初期案を置く。
  SELECT count(*) INTO n
    FROM app.control_implementations ci
    JOIN catalog.controls c ON c.id = ci.control_id
   WHERE ci.tenant_id = app.current_tenant()
     AND ci.valid_to IS NULL AND ci.recorded_until IS NULL
     AND c.framework_key = 'ISO27001:2022' AND c.retired_at IS NULL;
  IF n <> {len(CONTROL_RISK_MAP)} THEN
    RAISE EXCEPTION 'ISO管理策の適用初期案が % 件（想定 {len(CONTROL_RISK_MAP)}）', n;
  END IF;

  -- この seed が定義する候補リンクの本数。既存の手動追加分は妨げない。
  SELECT count(*) INTO n
    FROM app.risk_control_links l
    JOIN app.risk_scenarios r ON r.tenant_id = l.tenant_id AND r.id = l.risk_scenario_id
    JOIN catalog.controls c ON c.id = l.control_id
   WHERE l.tenant_id = app.current_tenant()
     AND r.risk_key IN ({risk_keys_sql})
     AND c.framework_key = 'ISO27001:2022' AND c.retired_at IS NULL;
  IF n < {want_control_risk_links} THEN
    RAISE EXCEPTION '自社リスクとISO管理策の候補リンクが % 件（最低想定 {want_control_risk_links}）', n;
  END IF;

  -- ISO 管理策の孤立を残さない。各リンク先は資産と施策へ辿れるリスクである。
  IF EXISTS (
    SELECT 1 FROM catalog.controls c
     WHERE c.framework_key = 'ISO27001:2022' AND c.retired_at IS NULL
       AND NOT EXISTS (
         SELECT 1
           FROM app.risk_control_links l
           JOIN app.risk_scenarios r ON r.tenant_id = l.tenant_id AND r.id = l.risk_scenario_id
          WHERE l.tenant_id = app.current_tenant() AND l.control_id = c.id
            AND r.status = 'active'
            AND EXISTS (SELECT 1 FROM app.risk_scenario_assets ra
                         WHERE ra.tenant_id = r.tenant_id AND ra.risk_scenario_id = r.id)
            AND EXISTS (SELECT 1 FROM app.risk_treatments rt
                         JOIN app.risk_assessments a ON a.tenant_id = rt.tenant_id
                           AND a.id = rt.risk_assessment_id
                         WHERE a.tenant_id = r.tenant_id AND a.risk_scenario_id = r.id
                           AND rt.measure_id IS NOT NULL)
       )
  ) THEN
    RAISE EXCEPTION '資産・施策へ辿れないISO管理策がある';
  END IF;

  -- ISO 対象の自社リスクにも少なくとも1つの管理策を付ける。
  IF EXISTS (
    SELECT 1 FROM app.risk_scenarios r
     JOIN app.risk_scenario_frameworks rf ON rf.tenant_id = r.tenant_id
       AND rf.risk_scenario_id = r.id AND rf.framework_key = 'ISO27001:2022'
     WHERE r.tenant_id = app.current_tenant() AND r.status = 'active'
       AND r.risk_key IN ({iso_risk_keys_sql})
       AND NOT EXISTS (SELECT 1 FROM app.risk_control_links l
                        WHERE l.tenant_id = r.tenant_id AND l.risk_scenario_id = r.id)
  ) THEN
    RAISE EXCEPTION 'ISO対象の自社リスクに管理策が無い';
  END IF;
END $$;
""")

    # 7. 投入結果を数えて出す。件数を見ずに「入れた」と言わない。
    lines.extend([
        "SELECT 'business_register' AS status,"
        " (SELECT count(*) FROM app.assets WHERE tenant_id=app.current_tenant()) AS assets,"
        " (SELECT count(*) FROM app.measures WHERE tenant_id=app.current_tenant()) AS measures,"
        " (SELECT count(*) FROM app.risk_scenarios WHERE tenant_id=app.current_tenant()) AS risks,"
        " (SELECT count(*) FROM app.risk_assessments WHERE tenant_id=app.current_tenant()) AS assessments,"
        " (SELECT count(*) FROM app.risk_treatments WHERE tenant_id=app.current_tenant()) AS treatments,"
        " (SELECT count(*) FROM app.risk_evaluation_snapshots WHERE tenant_id=app.current_tenant()) AS snapshots,"
        " (SELECT count(*) FROM app.control_implementations WHERE tenant_id=app.current_tenant()"
        "    AND valid_to IS NULL AND recorded_until IS NULL) AS control_implementations,"
        " (SELECT count(*) FROM app.risk_control_links WHERE tenant_id=app.current_tenant()) AS risk_control_links;",
        "COMMIT;",
    ])
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="投入せず、流す SQL の行数と件数だけを確かめる（ROLLBACK で終わる）")
    args = parser.parse_args()

    token = read_token()
    dsn = os.environ.get("ISMS_WRITE_DATABASE_URL", "postgres://127.0.0.1/isms_dev?user=app_rw")
    sql = build_sql(token)
    if args.dry_run:
        sql = sql.replace("\nCOMMIT;\n", "\nROLLBACK;\n")
    # トークンは標準入力の SQL 本文で渡す。psql の引数に置くと ps で読めてしまう。
    command = ["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", dsn]
    subprocess.run(command, input=sql, text=True, check=True)
    mode = "dry-run（巻き戻した）" if args.dry_run else "投入"
    print(
        f"business_register_seed: OK（{mode}／資産 {len(ASSETS)} ・施策 {len(MEASURES)} "
        f"・リスク {len(RISKS)} ・ISO管理策 {len(CONTROL_RISK_MAP)}）"
    )


if __name__ == "__main__":
    main()
