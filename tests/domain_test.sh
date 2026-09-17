#!/usr/bin/env bash
# ドメイン制約の受入試験（設計書 Phase 1 受入 2,3,4,5,11,12,13 と リスク基準 1.5）。
# 「制約があること」ではなく「違反が実際に拒否されること」を見る。
set -uo pipefail

DB="${ISMS_DB:-isms_dev}"
ADMIN="postgres:///$DB"
TA='11111111-1111-1111-1111-111111111111'
UA='aaaaaaaa-0000-0000-0000-000000000001'
TOKEN_A='TOKEN-A-0123456789012345678901234567890123'

pass=0; fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
ng() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

expect_ok() {
  local label="$1" sql="$2" out
  out=$(psql -At -v ON_ERROR_STOP=1 "$ADMIN" <<<"$sql" 2>&1)
  if [ $? -eq 0 ]; then ok "$label"; else ng "$label -- $(head -2 <<<"$out" | tr '\n' ' ')"; fi
}
expect_err() {
  local label="$1" sql="$2" want="${3:-}" out
  out=$(psql -At -v ON_ERROR_STOP=1 "$ADMIN" <<<"$sql" 2>&1)
  if [ $? -eq 0 ]; then ng "$label -- 失敗するはずが成功した"
  elif [ -n "$want" ] && ! grep -q "$want" <<<"$out"; then
    ng "$label -- 別の理由で失敗: $(head -2 <<<"$out" | tr '\n' ' ')"
  else ok "$label"; fi
}

echo "== ドメイン制約の受入試験 =="

psql -q -v ON_ERROR_STOP=1 "$ADMIN" >/dev/null <<SQL
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
-- app.risk_criteria は履歴なので削除できない（0017）。作り直さず upsert で揃える。
DELETE FROM app.risk_treatments; DELETE FROM app.risk_assessments;
DELETE FROM app.risk_scenarios;
DELETE FROM app.control_implementations; DELETE FROM app.deviations;
DELETE FROM audit.audit_log;
-- 標準リスク基準の検査に使う「どのテナントも使っていない DOM 版」。
-- 配布済み版は 0017 で不変になったので、トリガの試験はこちらで行う。
INSERT INTO catalog.dom_versions (id, version, released_at, changelog, is_current)
VALUES ('00000000-0000-0000-0000-0000000000ff','test-unused', now(), '試験用', false)
ON CONFLICT (version) DO NOTHING;
INSERT INTO catalog.risk_criteria_default (dom_version_id)
VALUES ('00000000-0000-0000-0000-0000000000ff')
ON CONFLICT (dom_version_id) DO NOTHING;
INSERT INTO catalog.risk_criteria_default (dom_version_id)
  VALUES ('00000000-0000-0000-0000-000000002026')
  ON CONFLICT (dom_version_id) DO NOTHING;
INSERT INTO catalog.frameworks (key, name_ja, version)
  VALUES ('TEST-FW','試験用フレームワーク','1') ON CONFLICT (key) DO NOTHING;
INSERT INTO catalog.controls (id, framework_key, code, title_ja)
  VALUES ('99999999-0000-0000-0000-000000000001','TEST-FW','T.1','試験用統制')
  ON CONFLICT (framework_key, code) DO NOTHING;
INSERT INTO app.risk_criteria (id, tenant_id, dom_version_id, impact_sec_formula,
  band_top_priority, band_action, band_consider, band_accept, valid_from)
VALUES ('cccccccc-0000-0000-0000-000000000001','$TA','00000000-0000-0000-0000-000000002026',
  'max_cia','{15,16,20,25}','{8,9,10,12}','{3,4,5,6}','{1,2}', current_date)
ON CONFLICT (tenant_id, id) DO NOTHING;
INSERT INTO app.risk_scenarios (id, tenant_id, risk_key, domain, theme, measure, frame, summary)
VALUES ('dddddddd-0000-0000-0000-000000000001','$TA','TEST-RISK-001','経理・税務','与信管理','与信フロー',
        '管理可能性','フロー未整備で与信判断が属人化する');
SELECT app.set_management_frameworks_human(
  'risk_scenario','dddddddd-0000-0000-0000-000000000001',ARRAY['RISK-MANAGEMENT']);
COMMIT;
SQL

echo "-- リスク基準（設計書 1.5.2）"
expect_ok "5x5 の全 25 組が 4 区分のいずれかに一意に該当する" "
DO \$\$
DECLARE p int; i int; lv int; n int; c record;
BEGIN
  SELECT * INTO c FROM catalog.risk_criteria_default
    WHERE dom_version_id='00000000-0000-0000-0000-000000002026';
  FOR p IN 1..5 LOOP FOR i IN 1..5 LOOP
    lv := p * i;
    n := (CASE WHEN lv = ANY(c.band_top_priority) THEN 1 ELSE 0 END)
       + (CASE WHEN lv = ANY(c.band_action)       THEN 1 ELSE 0 END)
       + (CASE WHEN lv = ANY(c.band_consider)     THEN 1 ELSE 0 END)
       + (CASE WHEN lv = ANY(c.band_accept)       THEN 1 ELSE 0 END);
    IF n <> 1 THEN
      RAISE EXCEPTION 'prob=% impact=% level=% が % 個の区分に該当', p, i, lv, n;
    END IF;
  END LOOP; END LOOP;
END \$\$;"

# 配布済み DOM 版は 0017 で不変になったので、どのテナントも使っていない版で試す
expect_err "14 値を覆わないバンドはトリガが拒否する" "
UPDATE catalog.risk_criteria_default SET band_accept = '{1,7}'
 WHERE dom_version_id='00000000-0000-0000-0000-0000000000ff';" \
"5x5 cannot produce"

echo "-- 受入 #13 impact_sec は算定式と一致しなければ拒否"
expect_ok "max_cia と一致する impact_sec は通る" "
INSERT INTO app.risk_assessments (id, tenant_id, risk_scenario_id, risk_criteria_id,
  prob, confidentiality, integrity, availability, impact_sec, impact_biz,
  assessed_by, valid_from)
VALUES ('eeeeeeee-0000-0000-0000-000000000001','$TA','dddddddd-0000-0000-0000-000000000001',
  'cccccccc-0000-0000-0000-000000000001', 3, 4, 2, 1, 4, 3, '$UA', current_date);"

expect_err "算定式と食い違う impact_sec は DB が拒否する" "
INSERT INTO app.risk_assessments (tenant_id, risk_scenario_id, risk_criteria_id,
  prob, confidentiality, integrity, availability, impact_sec, assessed_by, valid_from)
VALUES ('$TA','dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001',
  3, 4, 2, 1, 2, '$UA', current_date + 400);" \
"does not match formula"

echo "-- 受入 #12 残存リスク"
expect_err "同一サイクルで 残存 > 固有 は拒否される" "
INSERT INTO app.risk_treatments (tenant_id, risk_assessment_id, strategy, action_plan,
  prob_after, impact_sec_after, valid_from)
VALUES ('$TA','eeeeeeee-0000-0000-0000-000000000001','mitigate','対策',5,5, current_date);" \
"cannot exceed inherent risk"

expect_err "再評価での上昇は理由が無ければ拒否される" "
INSERT INTO app.risk_treatments (tenant_id, risk_assessment_id, strategy, action_plan,
  prob_after, impact_sec_after, valid_from)
VALUES ('$TA','eeeeeeee-0000-0000-0000-000000000001','mitigate','対策',5,5,
        current_date + 365);" \
"increase_reason is required"

expect_ok "再評価での上昇は理由があれば通る" "
INSERT INTO app.risk_treatments (tenant_id, risk_assessment_id, strategy, action_plan,
  prob_after, impact_sec_after, increase_reason, valid_from)
VALUES ('$TA','eeeeeeee-0000-0000-0000-000000000001','mitigate','対策',5,5,
        '事業環境の変化により再評価で上昇', current_date + 365);"

echo "-- 受入 #11 SoA（除外理由なしはブロック）"
expect_err "統制を除外するのに理由が無ければ登録できない" "
INSERT INTO app.control_implementations (tenant_id, control_id, applicability)
SELECT '$TA', id, 'excluded' FROM catalog.controls LIMIT 1;" \
"violates check constraint"

echo "-- 受入 #2/#3/#4 逸脱"
expect_err "理由なしの逸脱は登録できない" "
INSERT INTO app.deviations (tenant_id, kind, target_key, override, reason, weight,
  requested_by, status, approved_by, approved_at, expires_at)
VALUES ('$TA','check_disable','CHK-SHARE-001','{}','   ',3,'$UA','active','$UA',now(),
        now() + interval '30 days');" \
"violates check constraint"

expect_err "チェック無効化に代替統制が無ければ登録できない" "
INSERT INTO app.deviations (tenant_id, kind, target_key, override, reason, weight,
  requested_by, status, approved_by, approved_at, expires_at)
VALUES ('$TA','check_disable','CHK-SHARE-001','{}','人手で見るため',3,'$UA','active','$UA',
        now(), now() + interval '30 days');" \
"violates check constraint"

expect_err "承認者・期限なしで active にはできない" "
INSERT INTO app.deviations (tenant_id, kind, target_key, override, reason,
  compensating_control, weight, requested_by, status)
VALUES ('$TA','check_disable','CHK-SHARE-001','{}','人手で見るため','月次の目視棚卸',3,
        '$UA','active');" \
"violates check constraint"

expect_err "チェック無効化の期限が 180 日を超えると拒否される" "
INSERT INTO app.deviations (tenant_id, kind, target_key, override, reason,
  compensating_control, weight, requested_by, status, approved_by, approved_at, expires_at)
VALUES ('$TA','check_disable','CHK-SHARE-001','{}','人手で見るため','月次の目視棚卸',3,
        '$UA','active','$UA', now(), now() + interval '181 days');" \
"violates check constraint"

expect_ok "180 日以内なら登録できる" "
INSERT INTO app.deviations (id, tenant_id, kind, target_key, override, reason,
  compensating_control, weight, requested_by, status, approved_by, approved_at, expires_at)
VALUES ('ffffffff-0000-0000-0000-000000000001','$TA','check_disable','CHK-SHARE-001','{}',
        '人手で見るため','月次の目視棚卸',3,'$UA','active','$UA', now(),
        now() + interval '180 days');"

expect_ok "期限切れの逸脱は expire_deviations で expired になり標準へ戻る" "
DO \$\$
DECLARE n int;
BEGIN
  UPDATE app.deviations SET approved_at = now() - interval '10 days',
                            expires_at  = now() - interval '1 day'
   WHERE id='ffffffff-0000-0000-0000-000000000001';
  n := app.expire_deviations();
  IF n < 1 THEN RAISE EXCEPTION 'expire_deviations が 0 件'; END IF;
  IF (SELECT status FROM app.deviations WHERE id='ffffffff-0000-0000-0000-000000000001')
     <> 'expired' THEN RAISE EXCEPTION 'status が expired になっていない'; END IF;
  IF (SELECT is_deviated FROM app.effective_risk_criteria WHERE tenant_id='$TA') THEN
    RAISE EXCEPTION '失効後も逸脱が有効扱いになっている';
  END IF;
END \$\$;"

echo "-- 逸脱: 承認時刻が無いと期限上限が効かない穴"
expect_err "approved_at なしで active にはできない（無いと期限上限が素通りする）" "
INSERT INTO app.deviations (tenant_id, kind, target_key, override, reason,
  compensating_control, weight, requested_by, status, approved_by, expires_at)
VALUES ('$TA','check_disable','CHK-X','{}','理由','代替統制',3,'$UA','active','$UA',
        now() + interval '10 years');" \
"violates check constraint"

# 上書き自体は整合しているもの（14 値を覆う）を 2 本入れて、同時 1 本の制約を見る
expect_err "リスク基準の逸脱は 1 テナントに同時 1 本まで" "
INSERT INTO app.deviations (tenant_id, kind, target_key, override, reason, weight,
  requested_by, status, approved_by, approved_at, expires_at)
VALUES ('$TA','risk_band','bands','{\"band_accept\":[1],\"band_consider\":[2,3,4,5,6]}',
        '緩めたい',5,'$UA','active','$UA', now(), now() + interval '30 days'),
       ('$TA','risk_band','bands','{\"band_accept\":[1,2,3],\"band_consider\":[4,5,6]}',
        'こちらも',5,'$UA','active','$UA', now(), now() + interval '30 days');" \
"duplicate key value"

echo "-- 逸脱の上書き値（0016）"
expect_err "5x5 では起こり得ない値を含む上書きは拒否される" "
INSERT INTO app.deviations (tenant_id, kind, target_key, override, reason, weight,
  requested_by, status, approved_by, approved_at, expires_at)
VALUES ('$TA','risk_band','band_accept','{\"band_accept\":[99]}','緩めたい',5,'$UA','active',
        '$UA', now(), now() + interval '30 days');" \
"起こり得ない値"

expect_err "配列でない上書きは黙って標準へ落とさず拒否される" "
INSERT INTO app.deviations (tenant_id, kind, target_key, override, reason, weight,
  requested_by, status, approved_by, approved_at, expires_at)
VALUES ('$TA','risk_band','band_accept','{\"band_accept\":\"1,2\"}','緩めたい',5,'$UA','active',
        '$UA', now(), now() + interval '30 days');" \
"配列でなければ"

expect_err "上書き後に 14 値を覆わなくなる指定は拒否される" "
INSERT INTO app.deviations (tenant_id, kind, target_key, override, reason, weight,
  requested_by, status, approved_by, approved_at, expires_at)
VALUES ('$TA','risk_band','band_accept','{\"band_accept\":[1]}','2 を外したい',5,'$UA','active',
        '$UA', now(), now() + interval '30 days');" \
"過不足なく覆っていない"

expect_ok "整合した上書き（受容を 1 だけにし、要検討へ 2 を移す）は通る" "
INSERT INTO app.deviations (tenant_id, kind, target_key, override, reason, weight,
  requested_by, status, approved_by, approved_at, expires_at)
VALUES ('$TA','risk_band','bands','{\"band_accept\":[1],\"band_consider\":[2,3,4,5,6]}',
        '受容の幅を狭める',5,'$UA','active','$UA', now(), now() + interval '30 days');"

echo "-- リスク基準版の不変性（0016）"
expect_err "凍結した基準版の算定式は書き換えられない" "
UPDATE app.risk_criteria SET impact_sec_formula = 'avg_cia'
 WHERE id = 'cccccccc-0000-0000-0000-000000000001';" \
"凍結された版"

expect_ok "版を閉じて新しい版を作るのは通る" "
INSERT INTO app.risk_criteria (id, tenant_id, dom_version_id, impact_sec_formula,
  band_top_priority, band_action, band_consider, band_accept, valid_from)
VALUES ('cccccccc-0000-0000-0000-0000000000ff','$TA',
  '00000000-0000-0000-0000-000000002026','max_cia',
  '{15,16,20,25}','{8,9,10,12}','{3,4,5,6}','{1,2}', current_date - 10)
ON CONFLICT (tenant_id, id) DO NOTHING;
UPDATE app.risk_criteria SET valid_to = current_date - 1
 WHERE id = 'cccccccc-0000-0000-0000-0000000000ff' AND valid_to IS NULL;"

expect_err "閉じた版を開き直せない（valid_to は一方向）" "
UPDATE app.risk_criteria SET valid_to = NULL
 WHERE id = 'cccccccc-0000-0000-0000-0000000000ff';" \
"開き直し"

expect_err "閉じた版の終了日を付け替えられない" "
UPDATE app.risk_criteria SET valid_to = current_date + 5
 WHERE id = 'cccccccc-0000-0000-0000-0000000000ff';" \
"開き直し"

expect_err "基準版は削除できない（過去時点の再現に必要）" "
DELETE FROM app.risk_criteria WHERE id = 'cccccccc-0000-0000-0000-0000000000ff';" \
"削除できない"

expect_err "配布済み DOM 版の期限（due_days）も変更できない" "
UPDATE catalog.risk_criteria_default SET due_days_action = 120
 WHERE dom_version_id = '00000000-0000-0000-0000-000000002026';" \
"配布済みの DOM 版"

expect_err "標準基準の dom_version_id は付け替えられない" "
UPDATE catalog.risk_criteria_default
   SET dom_version_id = '00000000-0000-0000-0000-0000000000ff'
 WHERE dom_version_id = '00000000-0000-0000-0000-000000002026';" \
"dom_version_id は変更できない"

expect_err "不正なまま失効した逸脱を active へ戻せない" "
DO \$\$
BEGIN
  DELETE FROM app.deviations WHERE tenant_id='$TA' AND kind='risk_band';
  -- 検査を素通りする経路（トリガを一時的に外す）で不正な行を作る
  ALTER TABLE app.deviations DISABLE TRIGGER trg_validate_deviation_override_ins;
  INSERT INTO app.deviations (id, tenant_id, kind, target_key, override, reason, weight,
    requested_by, status)
  VALUES ('ffffffff-0000-0000-0000-0000000000dd','$TA','risk_band','bands',
          '{\"band_accept\":[99]}','不正な残骸',5,'$UA','expired');
  ALTER TABLE app.deviations ENABLE TRIGGER trg_validate_deviation_override_ins;
END \$\$;
UPDATE app.deviations
   SET status='active', approved_by='$UA', approved_at=now(),
       expires_at=now() + interval '30 days'
 WHERE id='ffffffff-0000-0000-0000-0000000000dd';" \
"起こり得ない値"

expect_ok "後片付け" "
DELETE FROM app.deviations WHERE id='ffffffff-0000-0000-0000-0000000000dd';"

expect_err "有効な risk_band 逸脱があるテナントの DOM 版は切り替えられない" "
INSERT INTO app.deviations (id, tenant_id, kind, target_key, override, reason, weight,
  requested_by, status, approved_by, approved_at, expires_at)
VALUES ('ffffffff-0000-0000-0000-0000000000cc','$TA','risk_band','bands',
        '{\"band_accept\":[1],\"band_consider\":[2,3,4,5,6]}','切替の試験',5,'$UA','active',
        '$UA', now(), now() + interval '30 days');
UPDATE app.tenants SET dom_version_id='00000000-0000-0000-0000-0000000000ff'
 WHERE id='$TA';" \
"DOM 版は切り替えられない"

expect_ok "後片付け（逸脱を消す）" "
DELETE FROM app.deviations WHERE id='ffffffff-0000-0000-0000-0000000000cc';"

expect_err "配布済み DOM 版の標準リスク基準は変更できない" "
UPDATE catalog.risk_criteria_default SET band_accept = '{1,2}', band_consider = '{3,4,5,6}',
       impact_sec_formula = 'avg_cia'
 WHERE dom_version_id = '00000000-0000-0000-0000-000000002026';" \
"配布済みの DOM 版"

expect_ok "期限切れ処理は override 検査に巻き込まれず走る" "
DO \$\$
DECLARE n int;
BEGIN
  -- 先行のテストが残した active な risk_band 逸脱を畳む（同時 1 本の制約があるため）
  DELETE FROM app.deviations WHERE tenant_id='$TA' AND kind='risk_band';
  INSERT INTO app.deviations (id, tenant_id, kind, target_key, override, reason, weight,
    requested_by, status, approved_by, approved_at, expires_at)
  VALUES ('ffffffff-0000-0000-0000-0000000000ee','$TA','risk_band','bands',
          '{\"band_accept\":[1],\"band_consider\":[2,3,4,5,6]}','棚卸し用',5,'$UA','active',
          '$UA', now() - interval '10 days', now() - interval '1 day');
  n := app.expire_deviations();
  IF n < 1 THEN RAISE EXCEPTION 'expire_deviations が 0 件'; END IF;
  DELETE FROM app.deviations WHERE id = 'ffffffff-0000-0000-0000-0000000000ee';
END \$\$;"

echo "-- 統制の分類（theme）: 正規形でない値を保存させない（0023）"
# 「その統制の分類は何か」の定義が画面・一覧・件数の 3 か所に分かれていて、
# 前後に空白の入った値が 1 件在るだけで互いに食い違った。値の側を 1 通りに固定する。
expect_ok "分類は NULL にできる（分類なしを表す）" "
INSERT INTO catalog.controls (id, framework_key, code, title_ja, theme)
VALUES ('99999999-0000-0000-0000-0000000000a1','TEST-FW','T.CANON.NULL','分類なし', NULL);"
expect_ok "正規形の分類は保存できる" "
INSERT INTO catalog.controls (id, framework_key, code, title_ja, theme)
VALUES ('99999999-0000-0000-0000-0000000000a2','TEST-FW','T.CANON.OK','正規形','甲 / 乙');"
# code は 1 件ずつ変える。使い回すと、制約が無いときに 1 件目が入ってしまい、
# 2 件目以降が「一意制約違反」という**別の理由**で落ちて、検査が働いたように見える。
canon_i=0
for bad_label in "前後に空白:' 甲 / 乙 '" "空白のみ:'   '" "区切りだけ:' / '" "空文字:''" "空の段:'甲 /  / 乙'"; do
  label="${bad_label%%:*}"; val="${bad_label#*:}"
  canon_i=$((canon_i + 1))
  expect_err "分類が正規形でない（${label}）と拒否される" "
INSERT INTO catalog.controls (framework_key, code, title_ja, theme)
VALUES ('TEST-FW','T.CANON.NG.${canon_i}','非正規形', ${val});" "controls_theme_canonical"
done
expect_ok "分類の検証に使った行を片付ける" "
DELETE FROM catalog.controls
 WHERE id IN ('99999999-0000-0000-0000-0000000000a1','99999999-0000-0000-0000-0000000000a2');"

echo "-- ID・ライセンス台帳"
expect_ok "外部ID同期前の利用者を複数登録できる" "
INSERT INTO app.identity_principals
  (id, tenant_id, provider, primary_email, display_name)
VALUES
  ('10000000-0000-0000-0000-000000000001','$TA','google_workspace','one@example.invalid','一人目'),
  ('10000000-0000-0000-0000-000000000002','$TA','google_workspace','two@example.invalid','二人目');"

expect_ok "外部IDが異なれば同期済み利用者を登録できる" "
UPDATE app.identity_principals
   SET external_id='gws-user-1'
 WHERE tenant_id='$TA' AND id='10000000-0000-0000-0000-000000000001';"

expect_err "同じprovider外部IDの重複を拒否する" "
UPDATE app.identity_principals
   SET external_id='gws-user-1'
 WHERE tenant_id='$TA' AND id='10000000-0000-0000-0000-000000000002';" \
"identity_principals_external_id_idx"

expect_ok "ライセンス要求の参照fixtureを作成できる" "
INSERT INTO app.application_catalog (id, tenant_id, app_key, name, provider)
VALUES
  ('20000000-0000-0000-0000-000000000001','$TA','app-a','App A','provider-a'),
  ('20000000-0000-0000-0000-000000000002','$TA','app-b','App B','provider-b');
INSERT INTO app.license_catalog (id, tenant_id, application_id, sku_key, name)
VALUES ('30000000-0000-0000-0000-000000000001','$TA',
        '20000000-0000-0000-0000-000000000001','sku-a','SKU A');"

expect_err "別システムのapplicationとSKUを組み合わせた要求を拒否する" "
INSERT INTO app.provisioning_requests
  (tenant_id, request_id, idempotency_key, action, provider, principal_id,
   application_id, license_id, reason, requested_by_email)
VALUES
  ('$TA','40000000-0000-0000-0000-000000000001','identity-test-key-0001',
   'license.assign','google_workspace','10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000001',
   '参照整合性テスト','admin@example.invalid');" \
"provisioning_requests_tenant_id_license_id_application_id_fkey"

expect_err "app_rwから発行履歴を直接作成できない" "
BEGIN;
SET LOCAL ROLE app_rw;
SELECT app.set_tenant_context('TOKEN-A-0123456789012345678901234567890123');
INSERT INTO app.provisioning_requests
  (tenant_id, request_id, idempotency_key, action, provider, principal_id,
   application_id, license_id, reason, requested_by_email)
VALUES
  ('$TA','40000000-0000-0000-0000-000000000002','identity-test-key-0002',
   'license.assign','google_workspace','10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001',
   '直接書込拒否テスト','admin@example.invalid');
ROLLBACK;" \
"permission denied"

expect_err "app_rwから外部ID状態を直接作成できない" "
BEGIN;
SET LOCAL ROLE app_rw;
SELECT app.set_tenant_context('TOKEN-A-0123456789012345678901234567890123');
INSERT INTO app.identity_principals
  (tenant_id, provider, primary_email, display_name)
VALUES ('$TA','google_workspace','forged@example.invalid','偽装利用者');
ROLLBACK;" \
"permission denied"

expect_err "app_rwからアプリcatalogを直接作成できない" "
BEGIN;
SET LOCAL ROLE app_rw;
SELECT app.set_tenant_context('TOKEN-A-0123456789012345678901234567890123');
INSERT INTO app.application_catalog (tenant_id, app_key, name, provider)
VALUES ('$TA','forged-app','偽装App','forged-provider');
ROLLBACK;" \
"permission denied"

expect_err "app_rwからライセンスcatalogを直接変更できない" "
BEGIN;
SET LOCAL ROLE app_rw;
SELECT app.set_tenant_context('TOKEN-A-0123456789012345678901234567890123');
UPDATE app.license_catalog SET seat_limit=999
 WHERE tenant_id='$TA' AND id='30000000-0000-0000-0000-000000000001';
ROLLBACK;" \
"permission denied"

expect_err "app_rwから付与済みライセンスを偽装できない" "
BEGIN;
SET LOCAL ROLE app_rw;
SELECT app.set_tenant_context('TOKEN-A-0123456789012345678901234567890123');
INSERT INTO app.entitlement_assignments
  (tenant_id, principal_id, license_id, state, assigned_at)
VALUES ('$TA','10000000-0000-0000-0000-000000000001',
        '30000000-0000-0000-0000-000000000001','assigned',now());
ROLLBACK;" \
"permission denied"

expect_err "draft要求に承認時刻を偽装できない" "
INSERT INTO app.provisioning_requests
  (tenant_id, request_id, idempotency_key, action, provider, principal_id,
   reason, requested_by_email, status, approved_at)
VALUES
  ('$TA','40000000-0000-0000-0000-000000000003','identity-test-key-0003',
   'identity.create','google_workspace','10000000-0000-0000-0000-000000000001',
   '時系列制約テスト','admin@example.invalid','draft',now());" \
"violates check constraint"

echo "-- リスク基準: 未知の算定式を素通りさせない"
expect_err "risk_criteria に未知の算定式は入れられない" "
INSERT INTO app.risk_criteria (tenant_id, dom_version_id, impact_sec_formula,
  band_top_priority, band_action, band_consider, band_accept, valid_from)
VALUES ('$TA','00000000-0000-0000-0000-000000002026','sum_cia',
  '{15,16,20,25}','{8,9,10,12}','{3,4,5,6}','{1,2}', current_date + 1000);" \
"violates check constraint"

echo "-- セッション: 停止・閉鎖されたら文脈を作れない"
expect_ok "利用者を suspended にすると既存トークンが通らなくなる" "
DO \$\$
DECLARE v_tenant uuid;
BEGIN
  UPDATE app.users SET status='suspended' WHERE tenant_id='$TA' AND id='$UA';
  BEGIN
    v_tenant := app.set_tenant_context('TOKEN-A-0123456789012345678901234567890123');
    RAISE EXCEPTION '停止した利用者のトークンが通ってしまった';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;   -- 期待どおり拒否された
  END;
  UPDATE app.users SET status='active' WHERE tenant_id='$TA' AND id='$UA';
END \$\$;"

expect_ok "テナントを closed にすると既存トークンが通らなくなる" "
DO \$\$
DECLARE v_tenant uuid;
BEGIN
  UPDATE app.tenants SET status='closed' WHERE id='$TA';
  BEGIN
    v_tenant := app.set_tenant_context('TOKEN-A-0123456789012345678901234567890123');
    RAISE EXCEPTION '閉鎖したテナントのトークンが通ってしまった';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  UPDATE app.tenants SET status='active' WHERE id='$TA';
END \$\$;"

echo "-- 受入 #5 監査ログのハッシュチェーン"
expect_err "T-09: auditlogd の直接 INSERT は追記入口を迂回できない" "
SET ROLE auditlogd;
INSERT INTO audit.audit_log (
  chain_seq, tenant_id, occurred_at, appended_at, actor_id, actor_type,
  action, hash, signature
) VALUES (99, '$TA', now(), now(), '$UA', 'user', 'direct.insert',
          '\\x00'::bytea, '\\x00'::bytea);
RESET ROLE;" "permission denied"

expect_ok "チェーン検証が緑になる" "
SET ROLE auditlogd;
SELECT audit.append('$TA', now(), '$UA', 'user', 'risk.update', 'risk_assessment',
                    'eeeeeeee-0000-0000-0000-000000000001', '{\"prob\":[2,3]}', 'テスト',
                    '\\x00'::bytea);
SELECT audit.append('$TA', now(), '$UA', 'user', 'deviation.approve', 'deviation',
                    'ffffffff-0000-0000-0000-000000000001', '{}', 'テスト', '\\x00'::bytea);
RESET ROLE;
DO \$\$
DECLARE v record;
BEGIN
  SELECT * INTO v FROM audit.verify_chain();
  IF NOT v.ok THEN RAISE EXCEPTION 'チェーン検証が赤（seq=%）', v.first_bad_seq; END IF;
  IF v.checked <> 2 THEN RAISE EXCEPTION '検査件数が想定外: %', v.checked; END IF;
END \$\$;"

expect_ok "1 行改ざんしたコピーでは検証が赤になる（逆向き検証）" "
DO \$\$
DECLARE v record;
BEGIN
  -- 所有者権限で 1 行だけ書き換える（アプリロールにはこの経路が無い）
  UPDATE audit.audit_log SET action = '改ざん' WHERE chain_seq = 1;
  SELECT * INTO v FROM audit.verify_chain();
  IF v.ok THEN RAISE EXCEPTION '改ざんを検知できていない'; END IF;
  IF v.first_bad_seq <> 1 THEN RAISE EXCEPTION '検知位置が誤り: %', v.first_bad_seq; END IF;
  UPDATE audit.audit_log SET action = 'risk.update' WHERE chain_seq = 1;
  SELECT * INTO v FROM audit.verify_chain();
  IF NOT v.ok THEN RAISE EXCEPTION '復元後に緑へ戻らない'; END IF;
END \$\$;"

printf '\n  合計: \033[32m%d PASS\033[0m / \033[31m%d FAIL\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
