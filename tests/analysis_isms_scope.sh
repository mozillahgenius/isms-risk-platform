#!/usr/bin/env bash
# AI分析の ISMS 限定（2026-09-13）: 使い捨て DB に ISMS タグ付き・タグ無しの施策・リスク・資産を混ぜて入れ、
# 画面と同じ関数（web/src/lib/analysisQueries.ts）で次を確かめる。
#   - 全体（ALL）の結果が、範囲で絞る前と同じ（手で数えた期待値と一致）
#   - ISMS（ISO27001:2022）ではタグ付きの項目だけが出る。タグを外すとその項目が消える（逆向き）
#   - 実行記録に範囲が残り、履歴は範囲ごとに分かれる
#   - ISMS 範囲でタグの無い施策を送ると断る（改ざんしたフォーム）
#   - ISMS タグ付きの施策が無いテナントでは、範囲の中の施策が0件になる
set -euo pipefail

DB="${ISMS_DB:-}"
case "$DB" in
  isms_test_*) ;;
  *) echo "analysis_isms_scope: ISMS_DB must be an isolated isms_test_* database" >&2; exit 1 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ADMIN="postgres:///$DB"
TA='53000000-0000-0000-0000-000000000001'
TB='54000000-0000-0000-0000-000000000002'
UA='53000000-0000-0000-0000-000000000011'
UB='54000000-0000-0000-0000-000000000012'
RI='53000000-0000-0000-0000-000000000021'
RN='53000000-0000-0000-0000-000000000022'
MI1='53000000-0000-0000-0000-000000000031'
MI2='53000000-0000-0000-0000-000000000032'
MN='53000000-0000-0000-0000-000000000033'
MB='54000000-0000-0000-0000-000000000034'
AI='53000000-0000-0000-0000-000000000041'
AN='53000000-0000-0000-0000-000000000042'
CRA='53000000-0000-0000-0000-000000000051'
ASI='53000000-0000-0000-0000-000000000061'
ASN='53000000-0000-0000-0000-000000000062'
TOKEN_A='ANALYSIS-TOKEN-A-01234567890123456789012345'
TOKEN_B='ANALYSIS-TOKEN-B-01234567890123456789012345'

# -w: 資格情報が足りなければ入力を待たずにすぐ落とす(2026-09-13 の配備の停止と同じ理由)。
psql -w -q -v ON_ERROR_STOP=1 "$ADMIN" <<SQL
INSERT INTO catalog.dom_versions (id,version,released_at,changelog,is_current)
VALUES ('53000000-0000-0000-0000-000000002026','analysis-test',now(),'analysis fixture',false)
ON CONFLICT (version) DO NOTHING;
INSERT INTO catalog.risk_criteria_default (dom_version_id)
VALUES ('53000000-0000-0000-0000-000000002026')
ON CONFLICT (dom_version_id) DO NOTHING;
INSERT INTO catalog.roles_default (key,name_ja,description,sort_order)
VALUES ('ciso','経営責任者','analysis fixture',1)
ON CONFLICT (key) DO NOTHING;
INSERT INTO catalog.frameworks (key,name_ja,version,source_note)
VALUES ('ISO27001:2022','ISO/IEC 27001','2022','analysis fixture'),
       ('RISK-MANAGEMENT','リソースマネジメント','1.0','analysis fixture')
ON CONFLICT (key) DO NOTHING;
BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO app.tenants (id,name,domain,dom_version_id)
VALUES ('$TA','Analysis A','analysis-a.example','53000000-0000-0000-0000-000000002026'),
       ('$TB','Analysis B','analysis-b.example','53000000-0000-0000-0000-000000002026');
INSERT INTO app.users (tenant_id,id,email,display_name)
VALUES ('$TA','$UA','analysis-a@example.test','Analysis A'),('$TB','$UB','analysis-b@example.test','Analysis B');
INSERT INTO app.memberships (tenant_id,user_id,role_key)
VALUES ('$TA','$UA','ciso'),('$TB','$UB','ciso');
-- リスクシナリオ: RI は ISMS タグ付き、RN はタグ無し(リソースマネジメントだけ)。
INSERT INTO app.risk_scenarios (tenant_id,id,risk_key,domain,area,phase,theme,measure,frame,summary)
VALUES ('$TA','$RI','AN-RI','AN','AN',1,'AN','AN','管理可能性','ISMS risk'),
       ('$TA','$RN','AN-RN','AN','AN',1,'AN','AN','管理可能性','non-ISMS risk');
INSERT INTO app.risk_scenario_frameworks (tenant_id,risk_scenario_id,framework_key)
VALUES ('$TA','$RI','RISK-MANAGEMENT'),('$TA','$RI','ISO27001:2022'),('$TA','$RN','RISK-MANAGEMENT');
-- 施策: MI1・MI2 は ISMS タグ付き、MN はタグ無し。MB は別テナントのタグ無し。
INSERT INTO app.measures (tenant_id,id,measure_key,name,summary,strategy)
VALUES ('$TA','$MI1','AN-MI1','ISMS measure 1','m','mitigate'),
       ('$TA','$MI2','AN-MI2','ISMS measure 2','m','mitigate'),
       ('$TA','$MN','AN-MN','non-ISMS measure','m','mitigate'),
       ('$TB','$MB','AN-MB','other tenant measure','m','mitigate');
INSERT INTO app.measure_frameworks (tenant_id,measure_id,framework_key)
VALUES ('$TA','$MI1','RISK-MANAGEMENT'),('$TA','$MI1','ISO27001:2022'),
       ('$TA','$MI2','RISK-MANAGEMENT'),('$TA','$MI2','ISO27001:2022'),
       ('$TA','$MN','RISK-MANAGEMENT'),('$TB','$MB','RISK-MANAGEMENT');
-- 資産: AI は ISMS タグ付き、AN はタグ無し。
INSERT INTO app.assets (tenant_id,id,asset_key,name,asset_type,classification)
VALUES ('$TA','$AI','AN-AI','ISMS asset','information',(SELECT key FROM catalog.asset_classes_default ORDER BY key LIMIT 1)),
       ('$TA','$AN','AN-AN','non-ISMS asset','information',(SELECT key FROM catalog.asset_classes_default ORDER BY key LIMIT 1));
INSERT INTO app.asset_frameworks (tenant_id,asset_id,framework_key)
VALUES ('$TA','$AI','RISK-MANAGEMENT'),('$TA','$AI','ISO27001:2022'),('$TA','$AN','RISK-MANAGEMENT');
INSERT INTO app.risk_scenario_assets (tenant_id,risk_scenario_id,asset_id)
VALUES ('$TA','$RI','$AI'),('$TA','$RI','$AN'),('$TA','$RN','$AI');
INSERT INTO app.risk_criteria (tenant_id,id,dom_version_id,impact_sec_formula,band_top_priority,band_action,band_consider,band_accept,valid_from)
VALUES ('$TA','$CRA','53000000-0000-0000-0000-000000002026','max_cia','{25}','{16}','{4}','{1}',CURRENT_DATE - 1);
INSERT INTO app.risk_assessments
  (tenant_id,id,risk_scenario_id,risk_criteria_id,status,prob,confidentiality,integrity,availability,impact_sec,impact_biz,assessed_by,approved_by,approved_at,valid_from)
VALUES ('$TA','$ASI','$RI','$CRA','approved',2,3,2,1,3,2,'$UA','$UA',now(),CURRENT_DATE - 1),
       ('$TA','$ASN','$RN','$CRA','approved',2,3,2,1,3,2,'$UA','$UA',now(),CURRENT_DATE - 1);
-- 現在有効な対応: MI1・MI2・MN が RI に、MI1・MI2 が RN に効いている。
INSERT INTO app.risk_treatments (tenant_id,risk_assessment_id,measure_id,strategy,action_plan,valid_from)
VALUES ('$TA','$ASI','$MI1','mitigate','p',CURRENT_DATE - 1),
       ('$TA','$ASI','$MI2','mitigate','p',CURRENT_DATE - 1),
       ('$TA','$ASI','$MN','mitigate','p',CURRENT_DATE - 1),
       ('$TA','$ASN','$MI1','mitigate','p',CURRENT_DATE - 1),
       ('$TA','$ASN','$MI2','mitigate','p',CURRENT_DATE - 1);
-- 評価: RI 固有 4x4=16、RN 固有 3x3=9。MI1 の対策後は RI で 2x2=4、RN で 1x2=2。
INSERT INTO app.risk_evaluation_snapshots (tenant_id,risk_scenario_id,measure_id,stage,assessed_on,probability,impact,rationale)
VALUES ('$TA','$RI',NULL,'inherent',CURRENT_DATE - 1,4,4,'RI inherent'),
       ('$TA','$RN',NULL,'inherent',CURRENT_DATE - 1,3,3,'RN inherent'),
       ('$TA','$RI','$MI1','after_measure',CURRENT_DATE - 1,2,2,'RI after MI1'),
       ('$TA','$RN','$MI1','after_measure',CURRENT_DATE - 1,1,2,'RN after MI1');
INSERT INTO app.incidents (tenant_id,title,related_measure_id)
VALUES ('$TA','incident on ISMS measure','$MI1'),('$TA','incident on non-ISMS measure','$MN');
COMMIT;
SELECT app.create_session('$TA','$UA','$TOKEN_A');
SELECT app.create_session('$TB','$UB','$TOKEN_B');
SQL

cd "$ROOT/web"
ANALYSIS_TEST_DB_URL="postgres:///$DB?user=app_rw" \
ANALYSIS_TEST_ADMIN_URL="$ADMIN" \
ANALYSIS_TEST_TOKEN_A="$TOKEN_A" \
ANALYSIS_TEST_TOKEN_B="$TOKEN_B" \
  npx vitest run tests/analysisScope.db.test.ts
cd "$ROOT"

# 0078 の戻しと再適用を、実行記録が既にある状態で確かめる(試験データは移行の後に入るので、
# 既存の行がある状態での up/down はここでしか通らない。Codex レビュー 2026-09-13 の指摘)。
MIG="$ROOT/scripts/migrate.sh"
# この移行の番号は取り込み順で付け直すことがあるので、ファイル名から読む。後に別の移行が足されても、
# この移行まで(それより後の分も含めて)戻す本数を数えて戻す(`down 1` 固定だと最新の別の移行を戻してしまう)。
SCOPE_VERSION="$(basename "$(ls "$ROOT"/db/migrations/*_simulation_runs_scope.up.sql)" | cut -d_ -f1)"
down_through_scope() {
  local n
  n="$(psql -w -At "$ADMIN" -c "select count(*) from public.schema_migrations where version >= '$SCOPE_VERSION'")"
  [ "$n" -ge 1 ] || return 1
  DATABASE_URL="$ADMIN" "$MIG" down "$n"
}
scope_column() {
  psql -w -At "$ADMIN" -c "select coalesce((select is_nullable from information_schema.columns
    where table_schema='app' and table_name='simulation_runs' and column_name='scope'),'absent')"
}
fail() { echo "analysis_isms_scope: FAIL $*" >&2; exit 1; }
# 1) ISMS 範囲の記録があるうちは、0078 を戻さない。
if down_out="$(down_through_scope 2>&1)"; then
  fail "ISMS 範囲の記録があるのに 0078 を戻せた"
fi
# 断った文言が down.sql のものであり、配備の関門の既知の保護(DOWN_GUARD_MESSAGES)にも載っていること。
# 載っていないと、本番に ISMS の記録ができた後の配備が、復旧の予行で「予期しない理由」として止まる。
guard_msg="$(grep -oE "[0-9]{4} rollback refused: [^']+" "$ROOT"/db/migrations/*_simulation_runs_scope.down.sql | head -1)"
[ -n "$guard_msg" ] || fail "down.sql から拒否の文言を読めない"
printf '%s\n' "$down_out" | grep -Fq "$guard_msg" || fail "down が別の理由で落ちた: $down_out"
grep -Fq "'$guard_msg'" "$ROOT/scripts/deploy_runtime.sh" || fail "DOWN_GUARD_MESSAGES に 0078 の拒否の文言が無い: $guard_msg"
[ "$(scope_column)" = "NO" ] || fail "戻しを断ったのに範囲の列が変わった"
# 2) ISMS 範囲の記録を消せば戻せる。列が消える。
psql -w -q -v ON_ERROR_STOP=1 "$ADMIN" -c "DELETE FROM app.simulation_runs WHERE tenant_id = '$TA' AND scope <> 'ALL'"
down_through_scope >/dev/null || fail "ISMS 範囲の記録が無いのに 0078 を戻せない"
[ "$(scope_column)" = "absent" ] || fail "0078 を戻しても範囲の列が残っている"
# 3) 既存の行がある状態で再び当てると、既存の行は全体(ALL)になり、列は NOT NULL に戻る。
DATABASE_URL="$ADMIN" "$MIG" up >/dev/null || fail "既存の行がある状態で 0078 を当てられない"
[ "$(scope_column)" = "NO" ] || fail "0078 を当て直した後、範囲の列が NOT NULL でない"
[ "$(psql -w -At "$ADMIN" -c "select count(*) filter (where scope = 'ALL') || '/' || count(*) from app.simulation_runs where tenant_id = '$TA'")" = "1/1" ] \
  || fail "当て直した後の既存の行が全体(ALL)になっていない"
echo "analysis_isms_scope: OK (ALL unchanged, ISMS tag-only, reverse, scope recorded, tampered form rejected, empty ISMS scope, 0078 down refused with ISMS runs, down/up with existing rows)"
