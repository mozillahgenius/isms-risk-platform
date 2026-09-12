#!/usr/bin/env bash
# Phase 0 acceptance (design doc Part XII):
#   load the existing xlsx -> DB -> the re-exported xlsx matches the input (machine diff with 0 differences)
#
# Do not treat "no errors" or "the file was generated" as grounds for completion.
# Pass only when there are 0 differences and the semantic mapping (RiskItem->area/phase etc.) is confirmed directly from the DB.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${ISMS_DB:-isms_dev}"
ADMIN="postgres:///$DB"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TENANT='33333333-3333-3333-3333-333333333333'
USER_ID='cccccccc-3333-3333-3333-333333333333'
CRIT_ID='dddddddd-3333-3333-3333-333333333333'

step() { printf '\n\033[36m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
die()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

step "0. 受入用テナントを用意する"
psql -q -v ON_ERROR_STOP=1 "$ADMIN" >/dev/null <<SQL
DELETE FROM app.risk_treatments  WHERE tenant_id = '$TENANT';
DELETE FROM app.risk_assessments WHERE tenant_id = '$TENANT';
DELETE FROM app.risk_scenarios   WHERE tenant_id = '$TENANT';
DELETE FROM app.risk_criteria    WHERE tenant_id = '$TENANT';
DELETE FROM app.sessions         WHERE tenant_id = '$TENANT';
DELETE FROM app.memberships      WHERE tenant_id = '$TENANT';
DELETE FROM app.users            WHERE tenant_id = '$TENANT';
DELETE FROM app.tenants          WHERE id        = '$TENANT';

INSERT INTO app.tenants (id, name, domain, dom_version_id)
VALUES ('$TENANT', 'Phase0 受入用', 'phase0.example',
        (SELECT id FROM catalog.dom_versions WHERE is_current));
INSERT INTO app.users (id, tenant_id, email, display_name)
VALUES ('$USER_ID', '$TENANT', 'phase0@phase0.example', 'Phase0 事務局');
INSERT INTO app.memberships (tenant_id, user_id, role_key)
VALUES ('$TENANT', '$USER_ID', 'secretariat');
INSERT INTO app.risk_criteria (id, tenant_id, dom_version_id, impact_sec_formula,
  band_top_priority, band_action, band_consider, band_accept, valid_from)
SELECT '$CRIT_ID', '$TENANT', d.dom_version_id, d.impact_sec_formula,
       d.band_top_priority, d.band_action, d.band_consider, d.band_accept, current_date
  FROM catalog.risk_criteria_default d
  JOIN catalog.dom_versions v ON v.id = d.dom_version_id AND v.is_current;
SQL
ok "テナント・利用者・リスク基準を作成"

step "1. 入力 fixture を生成する（build_risk_map.py は使わない＝自己整合性の検証にしない）"
python3 "$ROOT/phase0/make_fixture.py" "$WORK/in.xlsx"
ok "$WORK/in.xlsx"

step "2. xlsx → DB"
python3 "$ROOT/phase0/import_xlsx.py" --xlsx "$WORK/in.xlsx" --tenant "$TENANT" --replace

step "3. 意味の写像を DB から直接確認する（列名の付け替えではないことを見る）"
psql -q -v ON_ERROR_STOP=1 "$ADMIN" >/dev/null <<SQL
DO \$\$
DECLARE r record;
BEGIN
  SELECT s.domain, s.area, s.phase, s.theme, s.measure, s.frame, a.prob, a.impact_biz,
         t.prob_after, t.impact_biz_after
    INTO r
    FROM app.risk_scenarios s
    JOIN app.risk_assessments a ON a.tenant_id=s.tenant_id AND a.risk_scenario_id=s.id
    JOIN app.risk_treatments  t ON t.tenant_id=a.tenant_id AND t.risk_assessment_id=a.id
   WHERE s.tenant_id='$TENANT' AND s.summary LIKE '退職者のアカウントが残り%';
  IF r.area <> 'サンプル部門A' OR r.phase <> 1 THEN RAISE EXCEPTION 'RiskItem→area/phase の写像が誤り: % / %', r.area, r.phase; END IF;
  IF r.theme   <> 'サンプルテーマA' THEN RAISE EXCEPTION 'Big→theme の写像が誤り: %', r.theme; END IF;
  IF r.measure <> 'サンプル施策A'   THEN RAISE EXCEPTION 'Mid→measure の写像が誤り: %', r.measure; END IF;
  IF r.frame   <> '管理可能性'           THEN RAISE EXCEPTION 'Frame→frame の写像が誤り: %', r.frame; END IF;
  IF r.prob <> 4 OR r.impact_biz <> 5    THEN RAISE EXCEPTION 'Before の写像が誤り'; END IF;
  IF r.prob_after <> 2 OR r.impact_biz_after <> 4 THEN RAISE EXCEPTION 'After の写像が誤り'; END IF;
END \$\$;
SQL
ok "RiskItem→area/phase / Big→theme / Mid→measure / Before・After の写像が期待どおり"

step "4. DB → xlsx（既存 build_risk_map.py を無改変で呼ぶ）"
python3 "$ROOT/phase0/export_xlsx.py" --tenant "$TENANT" --scale biz --out "$WORK/out.xlsx"

step "5. 機械 diff（正規化済み業務データ）"
python3 "$ROOT/phase0/diff_xlsx.py" "$WORK/in.xlsx" "$WORK/out.xlsx" \
  || die "差分が 0 件ではない"
ok "差分 0 件"

step "6. 逆向き検証: 出力を 1 セルだけ壊すと diff が落ちること"
python3 - "$WORK/out.xlsx" "$WORK/broken.xlsx" <<'PY'
import sys, openpyxl
wb = openpyxl.load_workbook(sys.argv[1])
ws = wb['カルテ_リスクマップ']
ws.cell(row=2, column=6).value = 1          # overwrite ProbBefore
wb.save(sys.argv[2])
PY
if python3 "$ROOT/phase0/diff_xlsx.py" "$WORK/in.xlsx" "$WORK/broken.xlsx" >/dev/null 2>&1; then
  die "壊した出力なのに diff が通ってしまった（検査が効いていない）"
fi
ok "壊した出力では diff が落ちる"

step "7. 逆向き検証: 規則違反の入力が黙って通らないこと"
python3 - "$WORK/bad_header.xlsx" <<'PY'
import sys, openpyxl
wb = openpyxl.Workbook(); ws = wb.active; ws.title = 'カルテ_リスクマップ'
ws.append(['RiskItem','BigCategory','Big','MidCategory','SmallFrame','Summary',
           'ProbBefore','ImpactBefore','ActionPlan','ProbAfter','ImpactAfter'])
wb.save(sys.argv[1])
PY
if python3 -c "
import sys; sys.path.insert(0,'$ROOT/phase0'); import karte
karte.read_karte('$WORK/bad_header.xlsx')" 2>/dev/null; then
  die "列の衝突（Big と BigCategory）が通ってしまった"
fi
ok "列の衝突を検知して落ちる"

python3 - "$WORK/bad_value.xlsx" <<'PY'
import sys, openpyxl
wb = openpyxl.Workbook(); ws = wb.active; ws.title = 'カルテ_リスクマップ'
ws.append(['RiskItem','BigCategory','MidCategory','SmallFrame','Summary',
           'ProbBefore','ImpactBefore','ActionPlan','ProbAfter','ImpactAfter'])
ws.append(['領域','テーマ','施策','精度','要約', 1.5, 3, '対策', 1, 2])
wb.save(sys.argv[1])
PY
if python3 -c "
import sys; sys.path.insert(0,'$ROOT/phase0'); import karte
karte.read_karte('$WORK/bad_value.xlsx')" 2>/dev/null; then
  die "非整数 1.5 が切り捨てられて通ってしまった"
fi
ok "非整数を切り捨てず落ちる"

step "8. AUTO シートのゴールデン（比較対象外にしただけでは破損を検知できないため）"
GOLDEN="$ROOT/phase0/golden/auto_sheets.json"
python3 - "$WORK/out.xlsx" "$WORK/auto.json" <<'PY'
import sys, json, openpyxl
wb = openpyxl.load_workbook(sys.argv[1], data_only=True)
out = {}
for name in ('リスクマップ_AUTO', 'ヒートマップ_AUTO'):
    ws = wb[name]
    out[name] = [[('' if c is None else c) for c in row]
                 for row in ws.iter_rows(values_only=True)]
json.dump(out, open(sys.argv[2], 'w', encoding='utf-8'),
          ensure_ascii=False, sort_keys=True, indent=1)
PY
# Do not build it so that, when there is no golden file, "the current output" is written as the correct answer.
# Even if generation is broken, the first run would always pass, so it would not work as a check (self-approval).
# Require PHASE0_WRITE_GOLDEN=1 to be set explicitly only when regenerating on purpose.
if [ ! -f "$GOLDEN" ]; then
  if [ "${PHASE0_WRITE_GOLDEN:-}" = "1" ]; then
    mkdir -p "$(dirname "$GOLDEN")"
    cp "$WORK/auto.json" "$GOLDEN"
    ok "ゴールデンを新規作成した: ${GOLDEN} (中身を目視で確認して commit すること)"
  else
    die "ゴールデンが無い: ${GOLDEN} (作り直すなら PHASE0_WRITE_GOLDEN=1 を付けて実行)"
  fi
else
  diff -u "$GOLDEN" "$WORK/auto.json" >/dev/null || die "AUTO シートの生成結果がゴールデンと違う"
  ok "AUTO シートの再生成がゴールデンと一致"
fi

step "9. リスクマップマスタは往復対象外。catalog への投入を別に確認する"
psql -q -v ON_ERROR_STOP=1 "$ADMIN" >/dev/null <<'SQL'
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM catalog.risk_scenario_templates WHERE retired_at IS NULL;
  IF n = 0 THEN RAISE EXCEPTION 'risk_scenario_templates が空（load_csv.py を先に流すこと）'; END IF;
  IF NOT EXISTS (SELECT 1 FROM catalog.risk_scenario_templates
                  WHERE area = 'サンプル社内IT' AND phase = 1
                    AND theme  = '端末管理（サンプル）'
                    AND frame  = '管理可能性') THEN
    RAISE EXCEPTION '代表レコードが catalog に入っていない';
  END IF;
  RAISE NOTICE 'risk_scenario_templates: % 件', n;
END $$;
SQL
ok "catalog.risk_scenario_templates に投入済み・代表レコードを確認"

printf '\n\033[32mPhase 0 受入: 合格\033[0m\n'
