#!/usr/bin/env python3
"""自社テナントの ISO 27001:2022 管理策の実態判定を反映する。

このファイルは、設計書上の対応候補を「運用中」「設計中」へ昇格する
明示的な判定表。証跡そのものや SoA の承認を作るものではないため、
``verified`` へは上げない。また、既に上位の状態になっている記録を
seed で巻き戻さない。

判定の根拠は 2026-08-15 時点の自社運用記録と本番 DB の実測に限定する。
未確認の物理管理策・人的管理策・実機チェックはこの表に入れず、
``not_started`` のまま残す。
"""

from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path

from seed_business_register import literal, read_token


ROOT = Path(__file__).resolve().parents[1]
STATUS_RANK = {
    "not_started": 0,
    "designing": 1,
    "operating": 2,
    "verified": 3,
}


OPERATING_CONTROLS = {
    "A.5.9": "自社テナントの現行資産台帳18件を本番DBで管理している。",
    "A.5.12": "資産台帳18件に confidential / internal / top_secret の分類を付与している。",
    "A.5.15": "isms-platform のテナント文脈・RLS・RBACによるアクセス制御を本番で稼働させている。",
    "A.5.16": "組織・ユーザー・membershipを本番台帳で管理し、テナント境界を適用している。",
    "A.5.23": "Google Workspace連携1件をactiveで運用し、直近の主要資源取り込みを成功記録している。",
    "A.5.25": "自社リスクシナリオ24件と評価履歴を現行リスク台帳として管理している。",
    "A.5.33": "Kanameの監査記録、Git、isms-platformの履歴テーブルを追記前提で運用している。",
    "A.8.1": "KanameのDevice Control Planeを実装し、社内Mac 5台へagentを配布済み。isms-platform側の実機posture取り込みは未完了。",
    "A.8.3": "RLS・tenant context・DB権限ゲートによる情報アクセス制限を本番で実装している。",
    "A.8.4": "ソースコードをGitHubリポジトリで管理し、開発と本番配備の経路を分けている。",
    "A.8.15": "監査ログとcheckerのapp.check_runsを本番で記録している。",
    "A.8.16": "checker、ops-heartbeat、operations画面による運用監視を稼働させている。",
    "A.8.20": "公開Web経路とtailnet限定のdevice-proxy経路を分離して運用している。",
    "A.8.21": "HTTPS公開サービスとtailnet内サービスのネットワーク経路を構成・運用している。",
    "A.8.22": "公開経路、tailnet経路、DBのtenant RLSを分離している。",
    "A.8.24": "TLS、Ed25519署名、HMAC受領証を実装し、受入テストを通過している。",
    "A.8.25": "CI・レビュー・build/deployゲートをGitHub/mainと本番配備に適用している。",
    "A.8.28": "固定allowlist、任意query拒否、秘密情報検査をコードとテストで実装している。",
    "A.8.29": "unit・acceptance・negative verificationをCIで運用している。",
    "A.8.31": "ローカル・CI・本番(managed-device-02)を分離し、fixture用DBで検証している。",
    "A.8.32": "Gitコミット、バックアップ、build、外形確認を含む変更手順で本番反映している。",
    "A.8.33": "テスト用fixtureを隔離DBで使用し、実顧客データを検証に使っていない。",
}


DESIGNING_CONTROLS = {
    "A.5.1": "標準方針28件と本文は本番へ展開済みだが、現行版のapproved_atが未設定のため設計中とする。",
    "A.5.2": "役割・責任の規程とmembershipはあるが、現行の有効membershipは1件で役割分担の運用確認が未完了。",
    "A.5.3": "職務分離のDB制約・設計はあるが、自社運用での複数役割分担を確認できていない。",
    "A.5.4": "経営責任の規程は展開済みだが、承認・レビュー記録の運用証跡が未登録。",
    "A.5.10": "許容利用の規程は存在するが、承認済み版と利用者確認の記録が未登録。",
    "A.5.13": "資産分類は登録済みだが、情報ラベルの付与・表示運用は未確認。",
    "A.5.14": "共有・転送チェックは実行済みだが、個別の共有前レビュー記録への紐付けが未完了。",
    "A.5.17": "SSO・鍵管理の技術基盤はあるが、認証情報の棚卸し証跡が未完了。",
    "A.5.18": "アクセス権管理の仕組みはあるが、現行IAMチェックで3件の違反があり是正中。",
    "A.5.19": "委託先管理の枠組みはあるが、現行TPRチェックで38件の違反があり是正中。",
    "A.5.20": "委託先契約を扱う台帳・規程はあるが、契約単位の要求事項確認が未完了。",
    "A.5.21": "ICTサプライチェーンの確認枠はあるが、委託先チェックの未解消事項が残っている。",
    "A.5.22": "連携資源の取り込みは稼働しているが、委託先サービスの定期レビュー記録が未完了。",
    "A.5.24": "インシデント規程・記録先はあるが、準備状況の演習・証跡確認が未完了。",
    "A.5.26": "インシデントと是正処置の記録機構はあるが、対応演習の完了記録が未登録。",
    "A.5.27": "学習・是正の記録機構はあるが、インシデントからの反映実績を確認できていない。",
    "A.5.28": "checkerの実行履歴はあるが、app.evidencesと管理策の根拠紐付けは0件。",
    "A.5.29": "事業中断時の規程はあるが、復旧を含む実運用の確認が未完了。",
    "A.5.30": "VPS・Mac mini・バックアップの構成はあるが、継続性の実地試験が未完了。",
    "A.5.31": "法令・契約要求事項の規程は展開済みだが、要求事項一覧の承認・レビューが未完了。",
    "A.5.32": "Git等の知的財産管理基盤はあるが、権利・ライセンスの定期確認記録が未完了。",
    "A.5.34": "個人情報保護規程と資産台帳はあるが、実データを用いたプライバシーレビューが未完了。",
    "A.5.36": "標準checkerと監視規程はあるが、ISO管理策への検査・根拠紐付けが未完了。",
    "A.5.37": "運用手順の基盤はあるが、管理策ごとの承認済み手順と実施記録が未完了。",
    "A.6.5": "終了・変更手続の規程はあるが、IAMチェックの未解消事項があり運用確認中。",
    "A.6.7": "リモート・モバイル機器の規程と技術基盤はあるが、利用者単位の確認記録が未完了。",
    "A.6.8": "事象報告の規程・記録先はあるが、報告訓練または実績を確認できていない。",
    "A.8.5": "認証基盤は稼働しているが、現行IAMチェックで3件の違反があり是正中。",
    "A.8.8": "脆弱性・パッチ管理の規程とCIはあるが、定期的な実測結果の記録が未完了。",
    "A.8.9": "本番設定・配備手順は存在するが、構成ベースラインの継続的な照合が未完了。",
    "A.8.13": "バックアップ経路とcronの権限問題は確認済みだが、復元試験の証跡が未完了。",
    "A.8.26": "アプリケーションセキュリティ要求事項は設計・テストに反映しているが、要求事項台帳の運用が未完了。",
    "A.8.27": "セキュリティ設計原則は設計書・受入条件に反映しているが、全システムへの適用確認が未完了。",
}


# システム機能が本番で動いているものは、個別の承認・証拠・是正が残っていても
# 「運用中」とする。運用中は「検証済み」や「違反なし」を意味しない。
SYSTEM_OPERATING_CONTROLS = {
    "A.5.1": "規程28件・版管理・本文一致チェックを本番で運用している。承認済み版の有効化は未完了。",
    "A.5.2": "役割・責任規程とmembership管理を本番で運用している。現行membershipは1件。",
    "A.5.3": "職務分離をDB制約と監査人ロール制約で実装している。実組織の分担確認は別途必要。",
    "A.5.10": "許容利用規程を本番で管理している。利用者確認の記録は未登録。",
    "A.5.14": "Google Workspaceの共有・公開資源チェックを本番で運用している。個別レビュー記録は未紐付け。",
    "A.5.17": "SSO・OAuth・秘密参照を含む認証情報の管理経路を本番で運用している。棚卸しは継続中。",
    "A.5.18": "アクセス権管理とIAMチェックを本番で運用している。現行チェックの違反3件は是正中。",
    "A.5.19": "委託先台帳・評価・TPRチェックを本番で運用している。違反38件は是正中。",
    "A.5.20": "委託先契約要求事項を規程・ベンダー台帳・評価機能で管理している。契約単位の確認は継続中。",
    "A.5.21": "ICTサプライチェーンを連携台帳・委託先評価・チェックで管理している。未解消事項あり。",
    "A.5.22": "連携資源の実行履歴と成功・失敗状態を本番で記録している。定期レビューは継続中。",
    "A.5.24": "インシデント規程・記録・是正処置の機能を本番で運用している。演習は未完了。",
    "A.5.26": "インシデント・finding・corrective actionの状態管理を本番で運用している。対応実績は別途蓄積中。",
    "A.5.27": "是正処置・レビュー・規程改訂を記録できる機能を本番で運用している。反映実績は未確認。",
    "A.5.28": "checker実行履歴・evidence・管理策リンクの記録機能を本番で運用している。根拠リンクは現在0件。",
    "A.5.29": "事業中断・継続の規程、資産、タスクを本番台帳で管理している。復旧確認は未完了。",
    "A.5.30": "ICT継続性をVPS・Mac mini・バックアップ・監視の台帳と運用機能で管理している。実地試験は未完了。",
    "A.5.31": "法令・契約要求事項の規程と資産・ベンダー台帳を本番で管理している。要求事項レビューは継続中。",
    "A.5.34": "PII保護規程、資産分類、リスク台帳を本番で運用している。実データレビューは未完了。",
    "A.5.35": "監査プログラム・監査・レビューの記録機能を本番で提供している。独立レビュー実績は未登録。",
    "A.5.36": "checker・逸脱・是正の機能を本番で運用している。ISO管理策ごとの根拠紐付けは未完了。",
    "A.5.37": "規程・チェック・年間行事・タスクを本番で管理し、運用手順の台帳を提供している。",
    "A.6.5": "退職・変更に関係するmembership、共有権限チェックを本番で運用している。IAM違反は是正中。",
    "A.6.7": "Device Control Planeとテレワーク・モバイル規程を本番で運用している。利用者確認は継続中。",
    "A.6.8": "インシデント・finding・報告記録の機能を本番で運用している。訓練・実績は未登録。",
    "A.8.2": "RBAC、特権ロール制約、アクセス権チェックを本番で運用している。個別の権限是正は継続中。",
    "A.8.5": "SSO・RLS・認証境界とIAMチェックを本番で運用している。現行違反3件は検証済みとは扱わない。",
    "A.8.7": "端末agentのmalware/EDR状態収集項目とendpointチェックを実装している。実機チェックは未実行。",
    "A.8.8": "脆弱性・パッチ規程、CI、チェックカタログを本番で運用している。定期実測は継続中。",
    "A.8.9": "構成・migration・seed・build/deploy手順をGitと本番で運用している。ベースライン照合は継続中。",
    "A.8.13": "バックアップ経路とcronの権限確認を実施し、バックアップ運用を本番で管理している。復元試験は未完了。",
    "A.8.26": "アプリケーションセキュリティ要求事項を設計・migration・受入テストへ反映している。台帳化は継続中。",
}


def build_sql(token: str) -> str:
    lines = ["BEGIN;", f"SELECT app.set_tenant_context({literal(token)});"]
    updates = [(code, "operating", reason) for code, reason in OPERATING_CONTROLS.items()]
    updates.extend((code, "operating", reason) for code, reason in SYSTEM_OPERATING_CONTROLS.items())
    updates.extend(
        (code, "designing", reason)
        for code, reason in DESIGNING_CONTROLS.items()
        if code not in OPERATING_CONTROLS and code not in SYSTEM_OPERATING_CONTROLS
    )

    for code, status, rationale in updates:
        rank = STATUS_RANK[status]
        lines.append(
            "UPDATE app.control_implementations ci "
            "SET status = CASE "
            f"WHEN CASE ci.status WHEN 'not_started' THEN 0 WHEN 'designing' THEN 1 "
            f"WHEN 'operating' THEN 2 WHEN 'verified' THEN 3 END >= {rank} "
            "THEN ci.status ELSE " + literal(status) + " END, "
            "rationale = " + literal(f"実態判定（2026-08-15）: {rationale}") + ", "
            "updated_at = now() "
            "FROM catalog.controls c "
            "WHERE ci.control_id = c.id AND ci.tenant_id = app.current_tenant() "
            "AND ci.valid_to IS NULL AND ci.recorded_until IS NULL "
            "AND c.framework_key = 'ISO27001:2022' AND c.code = " + literal(code) + ";"
        )

    lines.extend([
        "SELECT status, count(*) FROM app.control_implementations "
        "WHERE tenant_id = app.current_tenant() AND valid_to IS NULL AND recorded_until IS NULL "
        "GROUP BY status ORDER BY status;",
        "COMMIT;",
    ])
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="SQLを実行するがCOMMITせずROLLBACKする")
    args = parser.parse_args()

    token = read_token()
    dsn = os.environ.get("ISMS_WRITE_DATABASE_URL", "postgres://127.0.0.1/isms_dev?user=app_rw")
    sql = build_sql(token)
    if args.dry_run:
        sql = sql.replace("\nCOMMIT;\n", "\nROLLBACK;\n")
    subprocess.run(
        ["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", dsn],
        input=sql,
        text=True,
        check=True,
    )
    mode = "dry-run（巻き戻した）" if args.dry_run else "反映"
    print(
        f"control_implementation_status: OK（{mode}／運用中 "
        f"{len(OPERATING_CONTROLS) + len(SYSTEM_OPERATING_CONTROLS)}件 "
        f"・設計中 {len(DESIGNING_CONTROLS) - len(set(DESIGNING_CONTROLS) & (set(OPERATING_CONTROLS) | set(SYSTEM_OPERATING_CONTROLS)))}件）"
    )


if __name__ == "__main__":
    main()
