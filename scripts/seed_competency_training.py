#!/usr/bin/env python3
"""自社（テナント）の力量要件と教育・訓練の初期案を冪等に投入する。

入れるもの:
  1. 力量要件   app.competency_requirements（標準ロールごとに要る力量）
  2. 教育・訓練 app.trainings（ISMS 対象のタグ付き）

**入れないもの**: 充足の評価（app.competency_fulfillments）と受講記録
（app.training_records）。どちらも「誰が」を伴う実績であり、実際に評価・受講した
事実が無いまま入れると、証跡の捏造になる。人と実績は運用側で入れる。

すべて **初期案・未承認**。description にその旨を残す。

冪等の効き方:
  - 力量要件は (role, required_competency) で突き合わせ、説明文を収束させる
  - 教育は (fiscal_year, title) で突き合わせ、説明文とタグを収束させる
  - **既存行の削除はしない**。運用が足したものを消さないため

内容の出所: catalog.roles_default の役割定義と、catalog.calendar_events_default の
教育行事。標準運用モデルに無いものを足していない。

  python3 scripts/seed_competency_training.py [--dry-run]
"""

from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

SOURCE = "標準ロール定義と年間行事を元にした初期案。未承認"

# --- 力量要件 ---------------------------------------------------------------
# (ロール, 要る力量, 説明)
# 役割の定義（catalog.roles_default.description）を、確かめられる行動に開いたもの。
REQUIREMENTS = [
    ("ciso", "リスク受容の判断",
     "残留リスクを受容するかを判断し、判断の根拠と日付を記録できる。受容は委譲しない。"),
    ("ciso", "マネジメントレビューの主宰",
     "監査結果・測定結果・インシデント・リスクの状況を入力として評価し、決定事項を残せる。"),
    ("ciso", "例外・逸脱の承認",
     "標準から外れる運用を、理由・代替策・期限つきで承認し、記録できる。"),
    ("secretariat", "リスクアセスメントの実施",
     "資産とリスクを台帳へ起こし、基準どおりに評価して根拠を書ける。"),
    ("secretariat", "統制の実施記録と証跡の管理",
     "統制ごとに実施したことの証跡を、後から第三者が辿れる形で残せる。"),
    ("secretariat", "コネクタ設定と収集結果の確認",
     "外部サービスからの収集を設定し、読めなかった期間を読めなかったこととして記録できる。"),
    ("secretariat", "是正処置の管理",
     "不適合を起票し、原因・処置・期限・完了確認まで追える。"),
    ("risk_owner", "自部門のリスクの特定と評価",
     "自部門で起こりうることを挙げ、同じ物差しで評価できる。"),
    ("risk_owner", "是正処置の実行",
     "割り当てられた処置を期限内に実行し、結果を報告できる。"),
    ("auditor", "内部監査の計画と実施",
     "監査計画を作り、記録と設定の実測で運用を確かめられる。自分が実施した業務は監査しない。"),
    ("auditor", "監査調書の作成",
     "確かめた事実と根拠を、第三者が追える調書として残せる。"),
    ("employee", "規程の理解と同意",
     "自分に関係する規程を読み、同意したことを記録に残せる。"),
    ("employee", "インシデントの報告",
     "おかしいと気づいたときに、決められた経路へ決められた期限内に報告できる。"),
    ("employee", "自端末の状態確認",
     "暗号化・画面施錠・更新の適用を自分で確かめられる。"),
]

# --- 教育・訓練 -------------------------------------------------------------
# (年度, 題名, 説明, タグ)
# 年間行事（annual_training / event_onboarding）に対応するものだけを置く。
FISCAL_YEAR = 2026
TRAININGS = [
    (FISCAL_YEAR, "情報セキュリティ年次教育",
     "全員対象。方針・規程・実際に起きた事例・報告の方法を扱う。年に 1 回。",
     ["isms"]),
    (FISCAL_YEAR, "入社時 情報セキュリティ教育",
     "入社・業務委託開始のつど。規程の同意、端末登録、報告経路を扱う。",
     ["isms"]),
    (FISCAL_YEAR, "リスクマネジメント基礎",
     "リスクの見つけ方と評価の物差し、受容の考え方。事務局とリスクオーナー向け。",
     ["risk-management"]),
    (FISCAL_YEAR, "インシデント対応訓練",
     "想定事例で報告経路・初動・外部連絡の期限を通して確かめる。年に 1 回。",
     ["isms", "risk-management"]),
]


def literal(value: object) -> str:
    if value is None:
        return "NULL"
    text = str(value).replace("'", "''")
    return f"'{text}'"


def text_array(values: list[str]) -> str:
    inner = ",".join(literal(v) for v in values)
    return f"ARRAY[{inner}]::text[]"


def read_token() -> str:
    value = os.environ.get("ISMS_WEB_TENANT_TOKEN", "").strip()
    if value:
        return value
    env_path = ROOT / "web" / ".env.local"
    if env_path.exists():
        for line in env_path.read_text(encoding="utf-8").splitlines():
            if line.startswith("ISMS_WEB_TENANT_TOKEN="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit(
        "ISMS_WEB_TENANT_TOKEN がありません。web/.env.local または環境変数を確認してください。"
    )


def build_sql(token: str) -> str:
    out: list[str] = ["BEGIN;", f"SELECT app.set_tenant_context({literal(token)});"]

    for role, competency, description in REQUIREMENTS:
        note = f"{description}（{SOURCE}）"
        out.append(
            "INSERT INTO app.competency_requirements "
            "(tenant_id, role, required_competency, description)\n"
            f"SELECT app.current_tenant(), {literal(role)}, {literal(competency)}, {literal(note)}\n"
            " WHERE NOT EXISTS (SELECT 1 FROM app.competency_requirements r\n"
            f"                    WHERE r.tenant_id = app.current_tenant()\n"
            f"                      AND r.role = {literal(role)}\n"
            f"                      AND r.required_competency = {literal(competency)});"
        )
        out.append(
            "UPDATE app.competency_requirements\n"
            f"   SET description = {literal(note)}, updated_at = now()\n"
            f" WHERE tenant_id = app.current_tenant()\n"
            f"   AND role = {literal(role)}\n"
            f"   AND required_competency = {literal(competency)}\n"
            f"   AND description IS DISTINCT FROM {literal(note)};"
        )

    for year, title, description, tags in TRAININGS:
        note = f"{description}（{SOURCE}）"
        out.append(
            "INSERT INTO app.trainings (tenant_id, title, fiscal_year, description, tags, source_system)\n"
            f"SELECT app.current_tenant(), {literal(title)}, {year}, {literal(note)}, "
            f"{text_array(tags)}, 'manual'\n"
            " WHERE NOT EXISTS (SELECT 1 FROM app.trainings t\n"
            f"                    WHERE t.tenant_id = app.current_tenant()\n"
            f"                      AND t.fiscal_year = {year}\n"
            f"                      AND t.title = {literal(title)});"
        )
        out.append(
            "UPDATE app.trainings\n"
            f"   SET description = {literal(note)}, tags = {text_array(tags)}, updated_at = now()\n"
            f" WHERE tenant_id = app.current_tenant()\n"
            f"   AND fiscal_year = {year}\n"
            f"   AND title = {literal(title)}\n"
            f"   AND (description IS DISTINCT FROM {literal(note)} OR tags IS DISTINCT FROM {text_array(tags)});"
        )

    out.append(
        "SELECT 'competency_training' AS status,\n"
        "       (SELECT count(*) FROM app.competency_requirements) AS requirements,\n"
        "       (SELECT count(*) FROM app.trainings) AS trainings,\n"
        "       (SELECT count(*) FROM app.trainings\n"
        "         WHERE tags && ARRAY['isms','risk-management']::text[]) AS trainings_isms;"
    )
    out.append("COMMIT;")
    return "\n".join(out) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="投入せず、流す SQL の件数だけを確かめる（ROLLBACK で終わる）",
    )
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
        f"competency_training_seed: OK（{mode}／力量要件 {len(REQUIREMENTS)} "
        f"・教育 {len(TRAININGS)}）"
    )


if __name__ == "__main__":
    main()
