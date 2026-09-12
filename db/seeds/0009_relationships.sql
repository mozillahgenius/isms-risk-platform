-- 0009: initial links between standard controls, framework mappings, and risk templates
--
-- What is registered here are "candidate mappings in the catalog"; they do not imply operational
-- implementation, approval, or existence of evidence. Without fabricating standard text or implementation evidence, build reviewable
-- initial mappings from codes, standard control names, and existing risk areas / control themes.
-- Every INSERT is idempotent on natural keys so re-running does not add rows.

SET ROLE schema_owner;

-- ISO27001:2013 was an empty placeholder for migration, so it is retired from the source of truth.
-- Only the frames/tags left in old DBs are cleaned up; the ISO27001:2022 catalog is kept.
DELETE FROM app.risk_scenario_frameworks WHERE framework_key = 'ISO27001:2013';
DELETE FROM app.measure_frameworks WHERE framework_key = 'ISO27001:2013';
DELETE FROM app.asset_frameworks WHERE framework_key = 'ISO27001:2013';
DELETE FROM catalog.policy_frameworks WHERE framework_key = 'ISO27001:2013';
DELETE FROM catalog.risk_template_frameworks WHERE framework_key = 'ISO27001:2013';
DELETE FROM catalog.control_frameworks WHERE framework_key = 'ISO27001:2013';
DELETE FROM catalog.frameworks WHERE key = 'ISO27001:2013';

UPDATE catalog.frameworks
   SET source_note = 'ISO/IEC 27001:2022 Annex A の管理策コード・名称（93件）の初期カタログ。詳細な適用判断・実施証拠・SoA は別途レビューする。'
 WHERE key = 'ISO27001:2022';

-- ISO/IEC 27001:2022 Annex A (organizational 37, people 8, physical 14, technological 34 = 93).
-- The standard's text is not copied into guidance_md; only short standard names are kept.
INSERT INTO catalog.controls (framework_key, code, title_ja, theme, guidance_md)
VALUES
  ('ISO27001:2022', 'A.5.1', '情報セキュリティのための方針群', '組織的管理策', '標準名称の初期カタログ。適用範囲・責任者・レビュー周期は自社で定義する。'),
  ('ISO27001:2022', 'A.5.2', '情報セキュリティの役割及び責任', '組織的管理策', '標準名称の初期カタログ。役割と責任分担は自社で定義する。'),
  ('ISO27001:2022', 'A.5.3', '職務の分離', '組織的管理策', '標準名称の初期カタログ。職務分離の対象と代替承認を自社で定義する。'),
  ('ISO27001:2022', 'A.5.4', '経営陣の責任', '組織的管理策', '標準名称の初期カタログ。経営陣の関与とレビュー方法は自社で定義する。'),
  ('ISO27001:2022', 'A.5.5', '関係当局との連絡', '組織的管理策', '標準名称の初期カタログ。連絡先と報告手順は自社で定義する。'),
  ('ISO27001:2022', 'A.5.6', '特別な利害関係団体との連絡', '組織的管理策', '標準名称の初期カタログ。情報交換先と利用方法は自社で定義する。'),
  ('ISO27001:2022', 'A.5.7', '脅威インテリジェンス', '組織的管理策', '標準名称の初期カタログ。収集・評価・共有方法は自社で定義する。'),
  ('ISO27001:2022', 'A.5.8', 'プロジェクトマネジメントにおける情報セキュリティ', '組織的管理策', '標準名称の初期カタログ。プロジェクト開始から完了までの確認点は自社で定義する。'),
  ('ISO27001:2022', 'A.5.9', '情報及びその他の関連資産の目録', '組織的管理策', '標準名称の初期カタログ。資産台帳の項目・責任者・更新周期は自社で定義する。'),
  ('ISO27001:2022', 'A.5.10', '情報及びその他の関連資産の許容される利用', '組織的管理策', '標準名称の初期カタログ。利用ルールと違反時の扱いは自社で定義する。'),
  ('ISO27001:2022', 'A.5.11', '資産の返却', '組織的管理策', '標準名称の初期カタログ。異動・退職・契約終了時の返却手順は自社で定義する。'),
  ('ISO27001:2022', 'A.5.12', '情報の分類', '組織的管理策', '標準名称の初期カタログ。分類基準と取扱いは自社で定義する。'),
  ('ISO27001:2022', 'A.5.13', '情報のラベル付け', '組織的管理策', '標準名称の初期カタログ。ラベルの付与・変更方法は自社で定義する。'),
  ('ISO27001:2022', 'A.5.14', '情報の転送', '組織的管理策', '標準名称の初期カタログ。転送経路・暗号化・承認要件は自社で定義する。'),
  ('ISO27001:2022', 'A.5.15', 'アクセス制御', '組織的管理策', '標準名称の初期カタログ。アクセス方針と定期レビューは自社で定義する。'),
  ('ISO27001:2022', 'A.5.16', 'アイデンティティ管理', '組織的管理策', '標準名称の初期カタログ。識別子の発行・変更・廃止は自社で定義する。'),
  ('ISO27001:2022', 'A.5.17', '認証情報', '組織的管理策', '標準名称の初期カタログ。認証情報の発行・保護・再設定は自社で定義する。'),
  ('ISO27001:2022', 'A.5.18', 'アクセス権', '組織的管理策', '標準名称の初期カタログ。付与・変更・棚卸し・削除は自社で定義する。'),
  ('ISO27001:2022', 'A.5.19', 'サプライヤー関係における情報セキュリティ', '組織的管理策', '標準名称の初期カタログ。サプライヤー評価と監督方法は自社で定義する。'),
  ('ISO27001:2022', 'A.5.20', 'サプライヤー契約における情報セキュリティの取扱い', '組織的管理策', '標準名称の初期カタログ。契約上の要求事項は自社で定義する。'),
  ('ISO27001:2022', 'A.5.21', 'ICTサプライチェーンにおける情報セキュリティの管理', '組織的管理策', '標準名称の初期カタログ。供給網のリスク確認は自社で定義する。'),
  ('ISO27001:2022', 'A.5.22', 'サプライヤーサービスの監視、レビュー及び変更管理', '組織的管理策', '標準名称の初期カタログ。サービス評価と変更承認は自社で定義する。'),
  ('ISO27001:2022', 'A.5.23', 'クラウドサービス利用における情報セキュリティ', '組織的管理策', '標準名称の初期カタログ。クラウド選定・利用・終了の基準は自社で定義する。'),
  ('ISO27001:2022', 'A.5.24', '情報セキュリティインシデント管理の計画及び準備', '組織的管理策', '標準名称の初期カタログ。対応体制・連絡網・演習方法は自社で定義する。'),
  ('ISO27001:2022', 'A.5.25', '情報セキュリティ事象の評価及び決定', '組織的管理策', '標準名称の初期カタログ。事象の判定基準とエスカレーションは自社で定義する。'),
  ('ISO27001:2022', 'A.5.26', '情報セキュリティインシデントへの対応', '組織的管理策', '標準名称の初期カタログ。封じ込め・復旧・報告の手順は自社で定義する。'),
  ('ISO27001:2022', 'A.5.27', '情報セキュリティインシデントからの学習', '組織的管理策', '標準名称の初期カタログ。原因分析と再発防止の方法は自社で定義する。'),
  ('ISO27001:2022', 'A.5.28', '証拠の収集', '組織的管理策', '標準名称の初期カタログ。証拠保全・記録・引渡しの方法は自社で定義する。'),
  ('ISO27001:2022', 'A.5.29', '業務の中断中における情報セキュリティ', '組織的管理策', '標準名称の初期カタログ。中断時の保護水準と復旧判断は自社で定義する。'),
  ('ISO27001:2022', 'A.5.30', '事業継続のためのICTの備え', '組織的管理策', '標準名称の初期カタログ。復旧目標・代替手段・演習方法は自社で定義する。'),
  ('ISO27001:2022', 'A.5.31', '法令、規制及び契約上の要求事項', '組織的管理策', '標準名称の初期カタログ。要求事項の特定・更新・遵守確認は自社で定義する。'),
  ('ISO27001:2022', 'A.5.32', '知的財産権', '組織的管理策', '標準名称の初期カタログ。権利・ライセンス・利用条件の管理は自社で定義する。'),
  ('ISO27001:2022', 'A.5.33', '記録の保護', '組織的管理策', '標準名称の初期カタログ。保存期間・改ざん防止・廃棄方法は自社で定義する。'),
  ('ISO27001:2022', 'A.5.34', 'プライバシー及び個人を特定できる情報（PII）の保護', '組織的管理策', '標準名称の初期カタログ。個人情報の取扱いと本人対応は自社で定義する。'),
  ('ISO27001:2022', 'A.5.35', '情報セキュリティの独立したレビュー', '組織的管理策', '標準名称の初期カタログ。独立性・範囲・頻度・是正確認は自社で定義する。'),
  ('ISO27001:2022', 'A.5.36', '情報セキュリティのための方針群、規則及び標準への準拠', '組織的管理策', '標準名称の初期カタログ。適合確認と例外管理は自社で定義する。'),
  ('ISO27001:2022', 'A.5.37', '文書化した運用手順', '組織的管理策', '標準名称の初期カタログ。手順の承認・配布・改訂・記録は自社で定義する。'),
  ('ISO27001:2022', 'A.6.1', '審査', '人的管理策', '標準名称の初期カタログ。採用時の確認範囲と記録は自社で定義する。'),
  ('ISO27001:2022', 'A.6.2', '雇用条件', '人的管理策', '標準名称の初期カタログ。雇用契約上の責任と義務は自社で定義する。'),
  ('ISO27001:2022', 'A.6.3', '情報セキュリティの意識向上、教育及び訓練', '人的管理策', '標準名称の初期カタログ。対象者・内容・頻度・受講記録は自社で定義する。'),
  ('ISO27001:2022', 'A.6.4', '懲戒手続', '人的管理策', '標準名称の初期カタログ。違反時の公正な手続は自社で定義する。'),
  ('ISO27001:2022', 'A.6.5', '雇用の終了又は変更後の責任', '人的管理策', '標準名称の初期カタログ。異動・退職時の責任移管は自社で定義する。'),
  ('ISO27001:2022', 'A.6.6', '秘密保持契約又は守秘義務契約', '人的管理策', '標準名称の初期カタログ。対象情報・期間・例外は自社で定義する。'),
  ('ISO27001:2022', 'A.6.7', 'リモートワーク', '人的管理策', '標準名称の初期カタログ。場所・端末・通信・環境の要件は自社で定義する。'),
  ('ISO27001:2022', 'A.6.8', '情報セキュリティ事象の報告', '人的管理策', '標準名称の初期カタログ。報告窓口・期限・報告対象は自社で定義する。'),
  ('ISO27001:2022', 'A.7.1', '物理的セキュリティ境界', '物理的管理策', '標準名称の初期カタログ。境界と保護対象は自社で定義する。'),
  ('ISO27001:2022', 'A.7.2', '物理的入退室', '物理的管理策', '標準名称の初期カタログ。入退室の認証・記録・来訪者管理は自社で定義する。'),
  ('ISO27001:2022', 'A.7.3', 'オフィス、部屋及び施設のセキュリティ', '物理的管理策', '標準名称の初期カタログ。施設ごとの保護措置は自社で定義する。'),
  ('ISO27001:2022', 'A.7.4', '物理的セキュリティの監視', '物理的管理策', '標準名称の初期カタログ。監視範囲・記録・確認方法は自社で定義する。'),
  ('ISO27001:2022', 'A.7.5', '物理的及び環境的脅威からの保護', '物理的管理策', '標準名称の初期カタログ。災害・環境リスクへの対策は自社で定義する。'),
  ('ISO27001:2022', 'A.7.6', 'セキュリティを保つべき領域での作業', '物理的管理策', '標準名称の初期カタログ。作業ルールと許可者は自社で定義する。'),
  ('ISO27001:2022', 'A.7.7', 'クリアデスク及びクリアスクリーン', '物理的管理策', '標準名称の初期カタログ。机上・画面の情報保護ルールは自社で定義する。'),
  ('ISO27001:2022', 'A.7.8', '装置の設置及び保護', '物理的管理策', '標準名称の初期カタログ。設置場所・盗難・損傷対策は自社で定義する。'),
  ('ISO27001:2022', 'A.7.9', '構外にある資産のセキュリティ', '物理的管理策', '標準名称の初期カタログ。持出し・保管・返却のルールは自社で定義する。'),
  ('ISO27001:2022', 'A.7.10', '記憶媒体', '物理的管理策', '標準名称の初期カタログ。媒体の管理・輸送・廃棄は自社で定義する。'),
  ('ISO27001:2022', 'A.7.11', 'サポートユーティリティ', '物理的管理策', '標準名称の初期カタログ。電源・空調・通信等の維持方法は自社で定義する。'),
  ('ISO27001:2022', 'A.7.12', 'ケーブル配線のセキュリティ', '物理的管理策', '標準名称の初期カタログ。配線の保護・経路・点検は自社で定義する。'),
  ('ISO27001:2022', 'A.7.13', '装置の保守', '物理的管理策', '標準名称の初期カタログ。保守作業・委託先・記録は自社で定義する。'),
  ('ISO27001:2022', 'A.7.14', '装置の安全な廃棄又は再利用', '物理的管理策', '標準名称の初期カタログ。データ消去と廃棄確認は自社で定義する。'),
  ('ISO27001:2022', 'A.8.1', '利用者エンドポイント機器', '技術的管理策', '標準名称の初期カタログ。端末の設定・利用・管理は自社で定義する。'),
  ('ISO27001:2022', 'A.8.2', '特権アクセス権', '技術的管理策', '標準名称の初期カタログ。特権の付与・利用・監視は自社で定義する。'),
  ('ISO27001:2022', 'A.8.3', '情報へのアクセス制限', '技術的管理策', '標準名称の初期カタログ。情報単位のアクセス制限は自社で定義する。'),
  ('ISO27001:2022', 'A.8.4', 'ソースコードへのアクセス', '技術的管理策', '標準名称の初期カタログ。リポジトリの権限とレビューは自社で定義する。'),
  ('ISO27001:2022', 'A.8.5', 'セキュアな認証', '技術的管理策', '標準名称の初期カタログ。認証方式・強度・保護は自社で定義する。'),
  ('ISO27001:2022', 'A.8.6', '容量・性能の管理', '技術的管理策', '標準名称の初期カタログ。容量監視・予測・対応は自社で定義する。'),
  ('ISO27001:2022', 'A.8.7', 'マルウェアに対する保護', '技術的管理策', '標準名称の初期カタログ。検知・防止・更新・対応は自社で定義する。'),
  ('ISO27001:2022', 'A.8.8', '技術的脆弱性の管理', '技術的管理策', '標準名称の初期カタログ。情報収集・評価・修正期限は自社で定義する。'),
  ('ISO27001:2022', 'A.8.9', '構成管理', '技術的管理策', '標準名称の初期カタログ。標準構成・変更・棚卸しは自社で定義する。'),
  ('ISO27001:2022', 'A.8.10', '情報の削除', '技術的管理策', '標準名称の初期カタログ。削除要求・期限・確認方法は自社で定義する。'),
  ('ISO27001:2022', 'A.8.11', 'データマスキング', '技術的管理策', '標準名称の初期カタログ。対象データ・方式・利用場面は自社で定義する。'),
  ('ISO27001:2022', 'A.8.12', 'データ漏えい防止', '技術的管理策', '標準名称の初期カタログ。検知・遮断・例外管理は自社で定義する。'),
  ('ISO27001:2022', 'A.8.13', '情報のバックアップ', '技術的管理策', '標準名称の初期カタログ。対象・頻度・保管・復元確認は自社で定義する。'),
  ('ISO27001:2022', 'A.8.14', '情報処理施設の冗長性', '技術的管理策', '標準名称の初期カタログ。冗長化の対象と切替方法は自社で定義する。'),
  ('ISO27001:2022', 'A.8.15', 'ログ取得', '技術的管理策', '標準名称の初期カタログ。取得対象・保存期間・改ざん防止は自社で定義する。'),
  ('ISO27001:2022', 'A.8.16', '監視活動', '技術的管理策', '標準名称の初期カタログ。監視対象・閾値・対応者は自社で定義する。'),
  ('ISO27001:2022', 'A.8.17', 'クロックの同期', '技術的管理策', '標準名称の初期カタログ。時刻源・許容差・確認方法は自社で定義する。'),
  ('ISO27001:2022', 'A.8.18', '特権ユーティリティプログラムの使用', '技術的管理策', '標準名称の初期カタログ。利用者・用途・記録は自社で定義する。'),
  ('ISO27001:2022', 'A.8.19', '運用システムへのソフトウェアの導入', '技術的管理策', '標準名称の初期カタログ。導入承認・検証・ロールバックは自社で定義する。'),
  ('ISO27001:2022', 'A.8.20', 'ネットワークセキュリティ', '技術的管理策', '標準名称の初期カタログ。ネットワーク保護と監視は自社で定義する。'),
  ('ISO27001:2022', 'A.8.21', 'ネットワークサービスのセキュリティ', '技術的管理策', '標準名称の初期カタログ。サービス要件と提供者管理は自社で定義する。'),
  ('ISO27001:2022', 'A.8.22', 'ネットワークの分離', '技術的管理策', '標準名称の初期カタログ。ゾーン・接続・例外の管理は自社で定義する。'),
  ('ISO27001:2022', 'A.8.23', 'ウェブフィルタリング', '技術的管理策', '標準名称の初期カタログ。対象・カテゴリ・例外は自社で定義する。'),
  ('ISO27001:2022', 'A.8.24', '暗号の利用', '技術的管理策', '標準名称の初期カタログ。暗号方式・鍵管理・適用範囲は自社で定義する。'),
  ('ISO27001:2022', 'A.8.25', 'セキュア開発ライフサイクル', '技術的管理策', '標準名称の初期カタログ。開発工程ごとのセキュリティ要求は自社で定義する。'),
  ('ISO27001:2022', 'A.8.26', 'アプリケーションセキュリティの要求事項', '技術的管理策', '標準名称の初期カタログ。要件定義・受入条件は自社で定義する。'),
  ('ISO27001:2022', 'A.8.27', 'セキュリティに配慮したシステムアーキテクチャ及びエンジニアリングの原則', '技術的管理策', '標準名称の初期カタログ。設計原則とレビュー方法は自社で定義する。'),
  ('ISO27001:2022', 'A.8.28', 'セキュアコーディング', '技術的管理策', '標準名称の初期カタログ。コーディング規約・レビュー・教育は自社で定義する。'),
  ('ISO27001:2022', 'A.8.29', '開発及び受入れにおけるセキュリティテスト', '技術的管理策', '標準名称の初期カタログ。テスト範囲・合格条件・記録は自社で定義する。'),
  ('ISO27001:2022', 'A.8.30', '外部委託による開発', '技術的管理策', '標準名称の初期カタログ。委託先の要求事項と受入れは自社で定義する。'),
  ('ISO27001:2022', 'A.8.31', '開発、テスト及び本番環境の分離', '技術的管理策', '標準名称の初期カタログ。環境間の権限・データ・移送は自社で定義する。'),
  ('ISO27001:2022', 'A.8.32', '変更管理', '技術的管理策', '標準名称の初期カタログ。変更の申請・承認・検証・記録は自社で定義する。'),
  ('ISO27001:2022', 'A.8.33', 'テスト用情報', '技術的管理策', '標準名称の初期カタログ。テストデータの匿名化・保護・廃棄は自社で定義する。'),
  ('ISO27001:2022', 'A.8.34', '監査テスト中の情報システムの保護', '技術的管理策', '標準名称の初期カタログ。監査時の影響抑制と承認は自社で定義する。')
ON CONFLICT (framework_key, code) DO UPDATE
   SET title_ja = EXCLUDED.title_ja,
       theme = EXCLUDED.theme,
       guidance_md = EXCLUDED.guidance_md,
       retired_at = NULL;

-- Resync tags so existing controls can be referenced from multiple frameworks.
INSERT INTO catalog.control_frameworks (control_id, framework_key)
SELECT c.id, c.framework_key
  FROM catalog.controls c
 WHERE c.retired_at IS NULL
ON CONFLICT DO NOTHING;

INSERT INTO catalog.control_frameworks (control_id, framework_key)
SELECT c.id, 'RISK-MANAGEMENT'
  FROM catalog.controls c
 WHERE c.retired_at IS NULL
ON CONFLICT DO NOTHING;

-- Initial IPO-KARTE -> ISO mapping table.
-- It does not claim a single exact match; it picks up to 8 candidates from existing control names/themes.
-- Standard controls with no candidate found are provisionally linked to a representative information-security control.
WITH iso_patterns(code, pattern) AS (
  VALUES
    ('A.5.1', '規程|方針|ポリシー|ルール'),
    ('A.5.2', '権限|責任|組織|担当|役割'),
    ('A.5.3', '職務分離|職務分掌|相互牽制|承認'),
    ('A.5.4', '経営|取締役|監督|責任者'),
    ('A.5.5', '法令|当局|官公庁|報告'),
    ('A.5.6', '団体|外部|情報交換|コミュニケーション'),
    ('A.5.7', '脅威|リスク|情報収集|分析'),
    ('A.5.8', 'プロジェクト|業務|プロセス|開発'),
    ('A.5.9', '情報資産|資産|台帳|文書|データ'),
    ('A.5.10', '情報|資産|利用|取扱|使用'),
    ('A.5.11', '返却|退職|異動|貸与|資産'),
    ('A.5.12', '分類|機密|情報資産|情報'),
    ('A.5.13', 'ラベル|表示|機密|情報'),
    ('A.5.14', '転送|共有|開示|通信|情報'),
    ('A.5.15', 'アクセス|権限|情報|システム'),
    ('A.5.16', 'アカウント|ユーザー|利用者|ID|権限'),
    ('A.5.17', '認証|パスワード|資格|アカウント'),
    ('A.5.18', 'アクセス|権限|承認|利用者'),
    ('A.5.19', '委託|取引先|サプライヤー|ベンダー'),
    ('A.5.20', '契約|委託|取引先|機密'),
    ('A.5.21', '委託|取引先|供給|サプライチェーン'),
    ('A.5.22', '委託|取引先|契約|評価|モニタリング'),
    ('A.5.23', 'クラウド|外部|システム|委託'),
    ('A.5.24', 'インシデント|事故|危機|緊急|対応'),
    ('A.5.25', 'インシデント|事故|評価|報告|リスク'),
    ('A.5.26', 'インシデント|事故|対応|復旧|報告'),
    ('A.5.27', '再発防止|改善|事故|インシデント|学習'),
    ('A.5.28', '証拠|記録|監査|調査'),
    ('A.5.29', '事業継続|災害|危機|業務|復旧'),
    ('A.5.30', 'バックアップ|復旧|事業継続|システム'),
    ('A.5.31', '法令|規制|契約|コンプライアンス|法務'),
    ('A.5.32', '知的財産|著作権|ライセンス|契約'),
    ('A.5.33', '記録|文書|保存|証憑|帳票'),
    ('A.5.34', '個人情報|個人|プライバシー|情報'),
    ('A.5.35', '監査|レビュー|モニタリング|内部統制'),
    ('A.5.36', 'コンプライアンス|準拠|監査|規程|ルール'),
    ('A.5.37', '手順|業務|マニュアル|運用|規程'),
    ('A.6.1', '採用|人事|身元|審査'),
    ('A.6.2', '雇用|就業|人事|労務|契約'),
    ('A.6.3', '教育|研修|訓練|従業員|人事'),
    ('A.6.4', '懲戒|就業|人事|規程'),
    ('A.6.5', '退職|異動|人事|労務|権限'),
    ('A.6.6', '秘密保持|守秘|機密|契約'),
    ('A.6.7', 'テレワーク|リモート|在宅|端末|情報'),
    ('A.6.8', '報告|事故|インシデント|従業員'),
    ('A.7.1', '施設|建物|物理|入退|セキュリティ'),
    ('A.7.2', '入退|施設|入館|物理'),
    ('A.7.3', '施設|建物|オフィス|物理'),
    ('A.7.4', '監視|入退|施設|物理|防犯'),
    ('A.7.5', '災害|環境|安全|施設|危機'),
    ('A.7.6', '施設|物理|安全|作業'),
    ('A.7.7', '机|画面|書類|情報|物理'),
    ('A.7.8', '設備|機器|資産|施設|物理'),
    ('A.7.9', '持出|資産|機器|設備'),
    ('A.7.10', '媒体|記録|データ|廃棄'),
    ('A.7.11', '電源|空調|設備|施設'),
    ('A.7.12', '配線|ネットワーク|設備|施設'),
    ('A.7.13', '保守|設備|機器|委託'),
    ('A.7.14', '廃棄|資産|機器|データ'),
    ('A.8.1', '端末|PC|パソコン|機器|情報システム'),
    ('A.8.2', '特権|管理者|権限|アクセス'),
    ('A.8.3', 'アクセス|情報|権限|データ'),
    ('A.8.4', 'ソースコード|開発|リポジトリ|システム'),
    ('A.8.5', '認証|パスワード|アクセス|システム'),
    ('A.8.6', '容量|性能|システム|業務'),
    ('A.8.7', 'ウイルス|マルウェア|不正|セキュリティ'),
    ('A.8.8', '脆弱性|セキュリティ|システム|IT'),
    ('A.8.9', '構成|設定|システム|IT'),
    ('A.8.10', '削除|データ|情報|廃棄'),
    ('A.8.11', 'マスキング|個人情報|データ'),
    ('A.8.12', '漏えい|情報|データ|個人情報'),
    ('A.8.13', 'バックアップ|データ|復旧|システム'),
    ('A.8.14', '冗長|可用性|システム|設備'),
    ('A.8.15', 'ログ|記録|監査|システム'),
    ('A.8.16', '監視|ログ|システム|不正'),
    ('A.8.17', '時刻|ログ|システム|同期'),
    ('A.8.18', '特権|管理者|ユーティリティ|システム'),
    ('A.8.19', 'ソフトウェア|導入|システム|変更'),
    ('A.8.20', 'ネットワーク|通信|IT|セキュリティ'),
    ('A.8.21', 'ネットワーク|通信|サービス|セキュリティ'),
    ('A.8.22', 'ネットワーク|分離|接続|セキュリティ'),
    ('A.8.23', 'ウェブ|Web|インターネット|フィルタ'),
    ('A.8.24', '暗号|暗号化|鍵|情報'),
    ('A.8.25', '開発|システム|セキュリティ|プロセス'),
    ('A.8.26', 'アプリケーション|開発|システム|要件'),
    ('A.8.27', '設計|アーキテクチャ|システム|開発'),
    ('A.8.28', '開発|コード|プログラム|システム'),
    ('A.8.29', 'テスト|検査|開発|受入'),
    ('A.8.30', '委託|開発|取引先|外部'),
    ('A.8.31', '開発|テスト|本番|環境|システム'),
    ('A.8.32', '変更|システム|承認|運用'),
    ('A.8.33', 'テスト|データ|情報|開発'),
    ('A.8.34', '監査|テスト|システム|検査')
), candidates AS (
  SELECT i.id AS iso_id, c.id AS ipo_id,
         row_number() OVER (PARTITION BY i.id ORDER BY c.code) AS rn
    FROM iso_patterns p
    JOIN catalog.controls i
      ON i.framework_key = 'ISO27001:2022' AND i.code = p.code AND i.retired_at IS NULL
    JOIN catalog.controls c
      ON c.framework_key = 'IPO-KARTE' AND c.retired_at IS NULL
     AND (c.title_ja || ' ' || coalesce(c.theme, '')) ~ p.pattern
)
INSERT INTO catalog.framework_mappings (from_control_id, to_control_id, relation)
SELECT ipo_id, iso_id, 'related'
  FROM candidates
 WHERE rn <= 8
ON CONFLICT DO NOTHING;

-- Even when no keyword matches, do not leave a standard control isolated in the mapping table.
-- The provisional link target is not fixed to a specific control code (the loaded control catalog can be swapped).
-- Prefer controls whose name/theme is close to information security; otherwise the first control in code order.
INSERT INTO catalog.framework_mappings (from_control_id, to_control_id, relation)
SELECT c.id, i.id, 'related'
  FROM catalog.controls i
  CROSS JOIN LATERAL (
    SELECT x.id FROM catalog.controls x
     WHERE x.framework_key = 'IPO-KARTE' AND x.retired_at IS NULL
     ORDER BY ((x.title_ja || ' ' || coalesce(x.theme, '')) ~ 'セキュリティ|情報|IT') DESC, x.code
     LIMIT 1
  ) c
 WHERE i.framework_key = 'ISO27001:2022'
   AND i.retired_at IS NULL
   AND NOT EXISTS (
     SELECT 1 FROM catalog.framework_mappings m WHERE m.to_control_id = i.id
   )
ON CONFLICT DO NOTHING;

-- Initial ISO candidates per risk area. Multiple candidates are attached to one risk, but
-- this does not mean "this control is implemented". Evaluation and adoption happen in register review.
WITH area_codes(area_pattern, codes) AS (
  VALUES
    ('人事|労務|採用|教育', ARRAY['A.5.11','A.5.15','A.5.16','A.5.18','A.5.34','A.6.1','A.6.2','A.6.3','A.6.4','A.6.5','A.6.6','A.6.7','A.6.8']),
    -- Physical, network, and development controls are also linked to the existing generic "internal IT" risk template.
    -- Not confined to industry-specific templates, so all 93 controls are reachable from at least one template.
    ('社内IT', ARRAY['A.7.1','A.7.2','A.7.3','A.7.4','A.7.5','A.7.6','A.7.7','A.7.8','A.7.9','A.7.10','A.7.11','A.7.12','A.7.13','A.7.14','A.8.4','A.8.6','A.8.11','A.8.14','A.8.17','A.8.18','A.8.19','A.8.21','A.8.23','A.8.27','A.8.28','A.8.31','A.8.33','A.8.34']),
    ('情報|社内IT|セキュリティ|システム|データ|IT', ARRAY['A.5.9','A.5.10','A.5.12','A.5.14','A.5.15','A.5.16','A.5.17','A.5.18','A.5.23','A.5.24','A.5.25','A.5.26','A.5.27','A.5.29','A.5.30','A.5.33','A.5.34','A.8.1','A.8.2','A.8.3','A.8.5','A.8.7','A.8.8','A.8.9','A.8.10','A.8.12','A.8.13','A.8.15','A.8.16','A.8.20','A.8.22','A.8.24']),
    ('購買|調達|委託|取引先|サプライヤー', ARRAY['A.5.19','A.5.20','A.5.21','A.5.22','A.5.23','A.5.31','A.5.32','A.6.6','A.8.30']),
    ('品質|検査|不良|クレーム|改善', ARRAY['A.5.8','A.5.24','A.5.25','A.5.26','A.5.27','A.5.28','A.5.29','A.5.30','A.5.37','A.8.25','A.8.26','A.8.29','A.8.32']),
    ('広報|ブランド|広告|情報公開|SNS|コミュニケーション', ARRAY['A.5.5','A.5.6','A.5.10','A.5.13','A.5.14','A.5.24','A.5.26','A.5.31','A.5.34']),
    ('経理|会計|財務|請求|売上|税務|決算|予算|支払|資金', ARRAY['A.5.9','A.5.12','A.5.15','A.5.18','A.5.31','A.5.33','A.5.34','A.8.13','A.8.15','A.8.16']),
    ('法務|契約|規程|文書|法令|コンプライアンス|総務', ARRAY['A.5.1','A.5.2','A.5.3','A.5.4','A.5.10','A.5.20','A.5.31','A.5.32','A.5.33','A.5.34','A.5.35','A.5.36','A.5.37']),
    ('監査|リスク|内部統制|危機|モニタリング|経営', ARRAY['A.5.1','A.5.2','A.5.3','A.5.4','A.5.7','A.5.24','A.5.25','A.5.27','A.5.28','A.5.29','A.5.30','A.5.35','A.5.36']),
    ('業務|プロセス|運営|サービス', ARRAY['A.5.1','A.5.8','A.5.10','A.5.15','A.5.18','A.5.24','A.5.26','A.5.29','A.5.30','A.5.37','A.8.9','A.8.32'])
), risk_iso AS (
  SELECT r.id AS template_id, x.code
    FROM catalog.risk_scenario_templates r
    JOIN area_codes a ON r.area ~ a.area_pattern
    CROSS JOIN LATERAL unnest(a.codes) AS x(code)
   WHERE r.retired_at IS NULL
)
INSERT INTO catalog.risk_template_controls (template_id, control_id)
SELECT ri.template_id, c.id
  FROM risk_iso ri
  JOIN catalog.controls c
    ON c.framework_key = 'ISO27001:2022' AND c.code = ri.code AND c.retired_at IS NULL
ON CONFLICT DO NOTHING;

-- Also attach candidate mappings between risk areas and existing IPO control themes.
WITH area_patterns(area_pattern, control_pattern) AS (
  VALUES
    ('人事|労務|採用|教育', '人事|労務|採用|教育|従業員|個人情報'),
    ('情報|社内IT|セキュリティ|システム|データ|IT', '情報|IT|システム|アクセス|認証|バックアップ|ネットワーク|データ|ログ|脆弱性'),
    ('購買|調達|委託|取引先|サプライヤー', '購買|調達|取引先|委託|サプライヤー|契約'),
    ('品質|検査|不良|クレーム|改善', '品質|検査|不良|クレーム|改善|プロセス|業務'),
    ('広報|ブランド|広告|情報公開|SNS|コミュニケーション', '広報|ブランド|広告|情報公開|コミュニケーション|顧客|情報'),
    ('経理|会計|財務|請求|売上|税務|決算|予算|支払|資金', '経理|会計|財務|請求|売上|税務|決算|予算|支払|資金|会計'),
    ('法務|契約|規程|文書|法令|コンプライアンス|総務', '法務|契約|規程|文書|法令|コンプライアンス|総務|取締役|承認'),
    ('監査|リスク|内部統制|危機|モニタリング|経営', '監査|リスク|内部統制|危機|モニタリング|経営|承認|報告'),
    ('業務|プロセス|運営|サービス', '業務|プロセス|運営|サービス|品質|チェック')
), risk_ipo AS (
  SELECT r.id AS template_id, c.id AS control_id,
         row_number() OVER (PARTITION BY r.id ORDER BY c.code) AS rn
    FROM catalog.risk_scenario_templates r
    JOIN area_patterns a ON r.area ~ a.area_pattern
    JOIN catalog.controls c
      ON c.framework_key = 'IPO-KARTE' AND c.retired_at IS NULL
     AND (c.title_ja || ' ' || coalesce(c.theme, '')) ~ a.control_pattern
   WHERE r.retired_at IS NULL
)
INSERT INTO catalog.risk_template_controls (template_id, control_id)
SELECT template_id, control_id
  FROM risk_ipo
 WHERE rn <= 12
ON CONFLICT DO NOTHING;

-- Even if area names change in the future, do not create isolated risks; link them to a minimal risk-management control.
-- The link target is not fixed to a specific control code. Prefer controls whose name/theme contains the word for "risk",
-- otherwise the first control in code order.
INSERT INTO catalog.risk_template_controls (template_id, control_id)
SELECT r.id, c.id
  FROM catalog.risk_scenario_templates r
  CROSS JOIN LATERAL (
    SELECT x.id FROM catalog.controls x
     WHERE x.framework_key = 'IPO-KARTE' AND x.retired_at IS NULL
     ORDER BY ((x.title_ja || ' ' || coalesce(x.theme, '')) ~ 'リスク') DESC, x.code
     LIMIT 1
  ) c
 WHERE r.retired_at IS NULL
   AND NOT EXISTS (
     SELECT 1 FROM catalog.risk_template_controls rtc WHERE rtc.template_id = r.id
   )
ON CONFLICT DO NOTHING;

-- Minimal load invariants. Detect partial seed loss at load time rather than on screen.
DO $$
DECLARE
  n int;
BEGIN
  SELECT count(*) INTO n
    FROM catalog.controls
   WHERE framework_key = 'ISO27001:2022' AND retired_at IS NULL;
  IF n <> 93 THEN
    RAISE EXCEPTION 'ISO27001:2022 Annex A の統制が % 件（93 件でなければならない）', n;
  END IF;
  IF EXISTS (
    SELECT 1 FROM catalog.controls
     WHERE framework_key = 'ISO27001:2022' AND retired_at IS NULL
       AND code !~ '^A\.[5-8]\.[0-9]{1,2}$'
  ) THEN
    RAISE EXCEPTION 'ISO27001:2022 に Annex A 形式でないコードがある';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM catalog.framework_mappings) THEN
    RAISE EXCEPTION 'フレームワーク対応表が 0 件';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM catalog.controls i
     WHERE i.framework_key = 'ISO27001:2022' AND i.retired_at IS NULL
       AND NOT EXISTS (
         SELECT 1 FROM catalog.framework_mappings m WHERE m.to_control_id = i.id
       )
  ) THEN
    RAISE EXCEPTION '対応表に孤立した ISO 管理策がある';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM catalog.controls i
     WHERE i.framework_key = 'ISO27001:2022' AND i.retired_at IS NULL
       AND NOT EXISTS (
         SELECT 1 FROM catalog.risk_template_controls rtc WHERE rtc.control_id = i.id
       )
  ) THEN
    RAISE EXCEPTION 'リスク雛形との対応に孤立した ISO 管理策がある';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM catalog.risk_template_controls) THEN
    RAISE EXCEPTION 'リスク雛形と統制の紐付けが 0 件';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM catalog.risk_scenario_templates r
     WHERE r.retired_at IS NULL
       AND NOT EXISTS (
         SELECT 1 FROM catalog.risk_template_controls rtc WHERE rtc.template_id = r.id
       )
  ) THEN
    RAISE EXCEPTION '統制に紐付かないリスク雛形がある';
  END IF;
END $$;

RESET ROLE;
