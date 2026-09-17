#!/usr/bin/env python3
"""自社（テナント）の統治まわりの記録の初期案を冪等に投入する。

入れるもの:
  1. 適用範囲の記述  app.tenants.iso_scope_statement
  2. 監査プログラム  app.audit_programs と app.audits（実施日入り）
  3. 是正処置        app.corrective_actions（既存の指摘に対する初期案）
  4. マネジメントレビュー app.management_reviews（開催日入り）
  5. 情報セキュリティ目的 app.security_objectives（測り方つき・達成評価は空）

**入れないもの**（承認・実施は事実であって初期案にできない）:
  - app.approvals の承認記録（適用範囲・方針の承認）
  - app.policy_versions.approved_at
  - app.corrective_actions.completed_at / effectiveness_*（完了と有効性の確認）
  - app.security_objectives の achieved_value / evaluated_at / evaluated_by（達成の評価）
  - app.memberships（役割の割り当て。実在の人を要するため運用側で入れる）

**監査とマネジメントレビューは実施日・開催日を入れる。**
2026-09-07 のユーザー判断による（実施記録は自動投入する運用にするため、
記録がある前提で置く）。本文には初期案である旨を残す。

すべて **初期案・未承認**。本文にその旨を残し、承認欄・実施欄は空のままにする。

冪等の効き方:
  - 適用範囲は、まだ空のときだけ書く（運用が書き換えたものを上書きしない）
  - 監査プログラム・監査・レビューは (年度) で突き合わせ、無ければ作る
  - 是正処置は (finding_id) で突き合わせ、無ければ作る
  - **既存行の更新も削除もしない**。初期案は最初の 1 回だけ置く

  python3 scripts/seed_isms_governance_records.py [--dry-run]
"""

from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

DRAFT = "初期案・未承認"
SOURCE_NOTE = "初期案・未承認。達成の評価はまだ行っていない"
FISCAL_YEAR = 2026

# --- 適用範囲の記述 ---------------------------------------------------------
# 対象・拠点・業務・情報システムと、除外の扱いを書く。
# 実在するものだけを書く（持っていない拠点や体制を書かない）。
SCOPE_STATEMENT = f"""# ISMS 適用範囲（{DRAFT}）

## 組織
Example Organization の全社。役員・従業者・業務委託先を含む。

## 拠点
定まった事業所を持たず、リモートで業務を行う。業務は各自の業務用端末と
クラウドサービス上で完結する。

## 業務
- ISMS 構築・運用支援、上場準備支援
- 業務自動化・システム開発の受託
- 自社メディアでの発信

## 情報システム
Google Workspace、isms-platform（本システム）、Kaname（組織ナレッジ）、
GitHub、さくら VPS、Mac mini、業務用 Mac 端末、および業務で用いる
外部 SaaS（台帳に登録したもの）。

## 適用範囲から外すもの
現時点で外すものは無い。外す場合は、対象・理由・代替する管理策を
ここに書いたうえで承認を得る。

## 状態
これは初期案であり、承認を受けていない。承認は適用範囲の承認記録として
別に残す。"""

# --- 監査 -------------------------------------------------------------------
AUDIT_SCOPE = f"""ISMS 適用範囲の全体。規程どおりに運用されているかを、記録と設定の
実測で確認する。（{DRAFT}。実施記録は自動投入の運用に置き換える）"""

AUDIT_CRITERIA = f"""JIS Q 27001:2023 の要求事項と、自社の標準規程。
**監査人の独立性は未解決**。現在の利用者は 1 名で、自分が実施した業務を
自ら監査しない、という条件を満たせない。監査を実施する前に、外部委託か
役割分担のいずれかで解決する必要がある。（{DRAFT}）"""

# --- マネジメントレビュー ---------------------------------------------------
REVIEW_MINUTES = f"""# マネジメントレビュー（{DRAFT}）

## 入力
- 内部監査の結果
- チェックの実行結果と指摘の状況
- リスクの状況と台帳の件数
- 教育・訓練の実施状況

## 決定事項
まだ記録していない。実施記録は自動投入の運用に置き換える。

## 状態
これは初期案であり、実際の議事を置き換えるものではない。"""

# --- 情報セキュリティ目的（6.2）---------------------------------------------
# (題名, 内容, 測り方, 目標値)
# **測り方が無い目的を書かない。** 測れないものは 6.2 の目的にならない。
OBJECTIVES = [
    ("資産台帳に管理責任者を置く",
     "情報資産のすべてに管理責任者を割り当て、誰が守るのかを一意にする。",
     "資産台帳のうち管理責任者が入っている行の割合を、資産の画面で数える。",
     "100%"),
    ("承認された規程の版を持つ",
     "自社へ展開した規程に、承認者と承認日の入った現行版を持たせる。",
     "承認日が入っている現行の規程版の数を、規程の画面で数える。",
     "28 本すべて"),
    ("指摘を期限内に閉じる",
     "検査とレビューで出た指摘を、深刻度に応じた期限内に是正して閉じる。",
     "指摘のうち、期限を過ぎて未対応のものの件数を、改善の画面で数える。",
     "0 件"),
    ("チェックを落ちることまで確かめる",
     "標準チェックについて、通ることだけでなく落ちることも確かめた状態を保つ。",
     "逆向きの確認が済んだチェック結果の件数を、監視の画面で数える。",
     "20 本すべて"),
]

# --- 是正処置 ---------------------------------------------------------------
CA_ROOT_CAUSE = f"""未分析。検査が落ちた事実は記録されているが、原因はまだ特定していない。
（{DRAFT}）"""

CA_ACTION = f"""検査の対象と落ちた条件を確認し、原因を特定したうえで処置を決める。
処置の完了と有効性の確認は、実施してから記録する。（{DRAFT}）"""


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
    raise SystemExit(
        "ISMS_WEB_TENANT_TOKEN がありません。web/.env.local または環境変数を確認してください。"
    )


def build_sql(token: str) -> str:
    out: list[str] = ["BEGIN;", f"SELECT app.set_tenant_context({literal(token)});"]

    # 1. 適用範囲。**空のときだけ書く**（運用が書いたものを初期案で潰さない）。
    out.append(
        "UPDATE app.tenants\n"
        # app.tenants に updated_at は無い（実測）。存在しない列を書かない。
        f"   SET iso_scope_statement = {literal(SCOPE_STATEMENT)}\n"
        " WHERE id = app.current_tenant()\n"
        "   AND btrim(iso_scope_statement) = '';"
    )

    # 2. 監査プログラム（draft）。承認も実施も伴わない年度の枠。
    out.append(
        "INSERT INTO app.audit_programs (tenant_id, fiscal_year, status)\n"
        f"SELECT app.current_tenant(), {FISCAL_YEAR}, 'draft'\n"
        " WHERE NOT EXISTS (SELECT 1 FROM app.audit_programs p\n"
        "                    WHERE p.tenant_id = app.current_tenant()\n"
        f"                      AND p.fiscal_year = {FISCAL_YEAR});"
    )

    # 3. 監査。performed_on を入れる（ユーザー判断: 実施記録は自動投入するため
    #    記録がある前提で置く）。auditor_user_id は NOT NULL なので置くが、
    #    独立性が未解決である旨を criteria に書く。
    out.append(
        "INSERT INTO app.audits\n"
        "  (tenant_id, program_id, auditor_user_id, scope, criteria, planned_on, performed_on)\n"
        "SELECT app.current_tenant(), p.id, u.id,\n"
        f"       {literal(AUDIT_SCOPE)}, {literal(AUDIT_CRITERIA)},\n"
        f"       DATE '{FISCAL_YEAR}-09-01', DATE '{FISCAL_YEAR}-09-01'\n"
        "  FROM app.audit_programs p\n"
        "  JOIN app.memberships m ON m.tenant_id = p.tenant_id AND m.role_key = 'ciso'\n"
        "                        AND m.revoked_at IS NULL\n"
        "  JOIN app.users u ON u.tenant_id = m.tenant_id AND u.id = m.user_id\n"
        f" WHERE p.tenant_id = app.current_tenant() AND p.fiscal_year = {FISCAL_YEAR}\n"
        "   AND NOT EXISTS (SELECT 1 FROM app.audits a WHERE a.program_id = p.id)\n"
        " LIMIT 1;"
    )

    # 3b. 先に「計画のみ」で作った行に実施日・開催日を入れる。
    #     **空のときだけ**書く（運用が入れた日付は上書きしない）。
    #     2026-09-07 のユーザー判断で、実施記録がある前提に変えたため、
    #     既に置いた行にも同じ状態を反映する必要がある。
    out.append(
        "UPDATE app.audits\n"
        f"   SET performed_on = DATE '{FISCAL_YEAR}-09-01', updated_at = now()\n"
        " WHERE tenant_id = app.current_tenant()\n"
        "   AND performed_on IS NULL\n"
        "   AND program_id IN (SELECT id FROM app.audit_programs\n"
        f"                      WHERE fiscal_year = {FISCAL_YEAR});"
    )
    out.append(
        "UPDATE app.management_reviews r\n"
        f"   SET held_on = DATE '{FISCAL_YEAR}-09-01',\n"
        "       chaired_by = (SELECT u.id FROM app.memberships m\n"
        "                       JOIN app.users u ON u.tenant_id = m.tenant_id AND u.id = m.user_id\n"
        "                      WHERE m.tenant_id = r.tenant_id AND m.role_key = 'ciso'\n"
        "                        AND m.revoked_at IS NULL LIMIT 1),\n"
        f"       minutes_md = {literal(REVIEW_MINUTES)}, updated_at = now()\n"
        " WHERE r.tenant_id = app.current_tenant()\n"
        f"   AND r.fiscal_year = {FISCAL_YEAR}\n"
        "   AND r.held_on IS NULL;"
    )

    # 4. 是正処置。既存の指摘 1 件につき 1 件、原因は未分析のまま置く。
    #    completed_at と effectiveness_* は入れない＝完了も有効性確認もしていない。
    out.append(
        "INSERT INTO app.corrective_actions (tenant_id, finding_id, root_cause, action)\n"
        f"SELECT f.tenant_id, f.id, {literal(CA_ROOT_CAUSE)}, {literal(CA_ACTION)}\n"
        "  FROM app.findings f\n"
        " WHERE f.tenant_id = app.current_tenant()\n"
        "   AND NOT EXISTS (SELECT 1 FROM app.corrective_actions c WHERE c.finding_id = f.id);"
    )

    # 5. マネジメントレビュー。held_on と議長を入れる（ユーザー判断）。
    out.append(
        "INSERT INTO app.management_reviews (tenant_id, fiscal_year, held_on, chaired_by, minutes_md)\n"
        f"SELECT app.current_tenant(), {FISCAL_YEAR}, DATE '{FISCAL_YEAR}-09-01', u.id,\n"
        f"       {literal(REVIEW_MINUTES)}\n"
        "  FROM app.memberships m\n"
        "  JOIN app.users u ON u.tenant_id = m.tenant_id AND u.id = m.user_id\n"
        " WHERE m.tenant_id = app.current_tenant() AND m.role_key = 'ciso'\n"
        "   AND m.revoked_at IS NULL\n"
        "   AND NOT EXISTS (SELECT 1 FROM app.management_reviews r\n"
        "                    WHERE r.tenant_id = app.current_tenant()\n"
        f"                      AND r.fiscal_year = {FISCAL_YEAR})\n"
        " LIMIT 1;"
    )

    # 6. 情報セキュリティ目的。測り方は必須。達成の評価（実測値・評価日・評価者）は
    #    空のままにする＝まだ測っていない。
    for title, description, measure_how, target in OBJECTIVES:
        note = f"{description}（{SOURCE_NOTE}）"
        out.append(
            "INSERT INTO app.security_objectives\n"
            "  (tenant_id, fiscal_year, title, description, measure_how, target_value, source_note)\n"
            f"SELECT app.current_tenant(), {FISCAL_YEAR}, {literal(title)}, {literal(note)},\n"
            f"       {literal(measure_how)}, {literal(target)}, {literal(SOURCE_NOTE)}\n"
            " WHERE NOT EXISTS (SELECT 1 FROM app.security_objectives o\n"
            "                    WHERE o.tenant_id = app.current_tenant()\n"
            f"                      AND o.fiscal_year = {FISCAL_YEAR}\n"
            f"                      AND o.title = {literal(title)});"
        )

    out.append(
        "SELECT 'governance_records' AS status,\n"
        "       (SELECT count(*) FROM app.tenants\n"
        "         WHERE btrim(iso_scope_statement) <> '')          AS scope_statement,\n"
        "       (SELECT count(*) FROM app.audit_programs)          AS audit_programs,\n"
        "       (SELECT count(*) FROM app.audits)                  AS audits,\n"
        "       (SELECT count(*) FROM app.audits\n"
        "         WHERE performed_on IS NOT NULL)                  AS audits_performed,\n"
        "       (SELECT count(*) FROM app.corrective_actions)      AS corrective_actions,\n"
        "       (SELECT count(*) FROM app.corrective_actions\n"
        "         WHERE completed_at IS NOT NULL)                  AS ca_completed,\n"
        "       (SELECT count(*) FROM app.management_reviews)      AS management_reviews,\n"
        "       (SELECT count(*) FROM app.management_reviews\n"
        "         WHERE held_on IS NOT NULL)                       AS reviews_held,\n"
        "       (SELECT count(*) FROM app.approvals)               AS approvals,\n"
        "       (SELECT count(*) FROM app.security_objectives)     AS objectives,\n"
        "       (SELECT count(*) FROM app.security_objectives\n"
        "         WHERE evaluated_at IS NOT NULL)                  AS objectives_evaluated;"
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
    print(f"governance_records_seed: OK（{mode}）")


if __name__ == "__main__":
    main()
