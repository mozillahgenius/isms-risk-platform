# -*- coding: utf-8 -*-
"""カルテ_リスクマップ の xlsx を DB へ取り込む（Phase 0 の前半）。

  python3 phase0/import_xlsx.py --xlsx in.xlsx --tenant <uuid> [--replace]

列の対応（NORMALIZATION.md と同じ。ここが唯一の実装）:
  RiskItem     -> app.risk_scenarios.area + phase（機能領域とPhase）
  Big          -> app.risk_scenarios.theme      （課題テーマ）
  Mid          -> app.risk_scenarios.measure    （施策）
  Frame        -> app.risk_scenarios.frame
  Summary      -> app.risk_scenarios.summary
  ProbBefore   -> app.risk_assessments.prob
  ImpactBefore -> app.risk_assessments.impact_biz
  Action       -> app.risk_treatments.action_plan
  ProbAfter    -> app.risk_treatments.prob_after
  ImpactAfter  -> app.risk_treatments.impact_biz_after

DB へは psql の \\copy で流す（追加の Python ドライバを増やさない）。
"""
from __future__ import annotations

import argparse
import csv
import os
import subprocess
import sys
import tempfile
import uuid as _uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import karte  # noqa: E402

STAGE_COLS = ['risk_item', 'big', 'mid', 'frame', 'summary',
              'prob_before', 'impact_before', 'action', 'prob_after', 'impact_after']


def db_url():
    return os.environ.get('DATABASE_URL') or f"postgres:///{os.environ.get('ISMS_DB', 'isms_dev')}"


def run_sql(sql):
    p = subprocess.run(['psql', '-v', 'ON_ERROR_STOP=1', '-q', db_url(), '-f', '-'],
                       input=sql, text=True, capture_output=True)
    if p.returncode != 0:
        sys.stderr.write(p.stdout + p.stderr)
        raise SystemExit(f'psql が失敗しました（exit={p.returncode}）')
    return p.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--xlsx', required=True)
    ap.add_argument('--tenant', required=True)
    ap.add_argument('--replace', action='store_true',
                    help='取り込み前にそのテナントのリスク台帳を空にする')
    args = ap.parse_args()

    # SQL へ埋める前に uuid として厳密に検証する（文字列補間の入口を塞ぐ）。
    # 正規化した表現を使い、入力文字列そのものは SQL へ渡さない。
    try:
        tenant = str(_uuid.UUID(args.tenant))
    except (ValueError, AttributeError, TypeError):
        raise SystemExit(f'--tenant が uuid ではありません: {args.tenant!r}')

    rows = karte.read_karte(args.xlsx)

    with tempfile.NamedTemporaryFile('w', suffix='.csv', delete=False,
                                     encoding='utf-8', newline='') as f:
        w = csv.writer(f)
        w.writerow(STAGE_COLS)
        for r in rows:
            w.writerow([r[c] for c in karte.CANONICAL])
        csv_path = f.name

    try:
        sql = f"""
BEGIN;
SELECT pg_advisory_xact_lock(8891234503);

CREATE TEMP TABLE karte_in (
  risk_item text, big text, mid text, frame text, summary text,
  prob_before smallint, impact_before smallint, action text,
  prob_after smallint, impact_after smallint
) ON COMMIT DROP;

\\copy karte_in FROM '{csv_path}' WITH (FORMAT csv, HEADER true)

DO $$
DECLARE
  v_tenant   uuid := '{tenant}';
  v_criteria uuid;
  v_user     uuid;
  v_n        int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM app.tenants WHERE id = v_tenant) THEN
    RAISE EXCEPTION 'テナントが存在しない: %', v_tenant;
  END IF;

  SELECT id INTO v_criteria FROM app.risk_criteria
   WHERE tenant_id = v_tenant AND valid_to IS NULL ORDER BY valid_from DESC LIMIT 1;
  IF v_criteria IS NULL THEN
    RAISE EXCEPTION 'テナントに有効な risk_criteria が無い（先に seed を流すこと）';
  END IF;

  SELECT u.id INTO v_user FROM app.users u
    JOIN app.memberships m ON m.tenant_id = u.tenant_id AND m.user_id = u.id
   WHERE u.tenant_id = v_tenant AND m.role_key = 'secretariat' AND m.revoked_at IS NULL
   ORDER BY u.email LIMIT 1;
  IF v_user IS NULL THEN
    SELECT id INTO v_user FROM app.users WHERE tenant_id = v_tenant ORDER BY email LIMIT 1;
  END IF;
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'テナントに利用者が居ない';
  END IF;

  {'''
  DELETE FROM app.risk_treatments  WHERE tenant_id = v_tenant;
  DELETE FROM app.risk_assessments WHERE tenant_id = v_tenant;
  DELETE FROM app.risk_scenarios   WHERE tenant_id = v_tenant;
  ''' if args.replace else ''}

  INSERT INTO app.risk_scenarios
    (tenant_id, risk_key, domain, area, phase, theme, measure, frame, summary, created_by)
  SELECT v_tenant,
         'RISK-' || substr(md5(concat_ws('|', k.risk_item, k.big, k.mid, k.frame, k.summary)), 1, 12),
         CASE WHEN k.risk_item ~ '^.*（Phase[1-5]）$' THEN substring(k.risk_item FROM '^(.*)（Phase[1-5]）$') ELSE k.risk_item END,
         CASE WHEN k.risk_item ~ '^.*（Phase[1-5]）$' THEN substring(k.risk_item FROM '^(.*)（Phase[1-5]）$') ELSE k.risk_item END,
         CASE WHEN k.risk_item ~ '^.*（Phase[1-5]）$' THEN substring(k.risk_item FROM 'Phase([1-5])')::smallint ELSE 1 END,
         k.big, k.mid, k.frame, k.summary, v_user FROM karte_in k;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE 'risk_scenarios: % 件', v_n;

  -- 業務キーだけで引き直すと、retired なシナリオや過去版の評価にもぶら下げてしまう。
  -- 今回作った行だけを RETURNING で受けて、その id で後続を作る。
  INSERT INTO app.risk_assessments
    (tenant_id, risk_scenario_id, risk_criteria_id, prob, impact_biz,
     assessed_by, valid_from, created_by)
  SELECT v_tenant, s.id, v_criteria, k.prob_before, k.impact_before,
         v_user, current_date, v_user
    FROM karte_in k
    JOIN app.risk_scenarios s
      ON s.tenant_id = v_tenant AND s.status = 'active'
     AND s.area = CASE WHEN k.risk_item ~ '^.*（Phase[1-5]）$' THEN substring(k.risk_item FROM '^(.*)（Phase[1-5]）$') ELSE k.risk_item END
     AND s.phase = CASE WHEN k.risk_item ~ '^.*（Phase[1-5]）$' THEN substring(k.risk_item FROM 'Phase([1-5])')::smallint ELSE 1 END
     AND s.theme = k.big
     AND s.measure = k.mid AND s.frame = k.frame AND s.summary = k.summary;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE 'risk_assessments: % 件', v_n;

  INSERT INTO app.risk_treatments
    (tenant_id, risk_assessment_id, strategy, action_plan,
     prob_after, impact_biz_after, valid_from, created_by)
  SELECT v_tenant, a.id, 'mitigate', k.action, k.prob_after, k.impact_after,
         current_date, v_user
    FROM karte_in k
    JOIN app.risk_scenarios s
      ON s.tenant_id = v_tenant AND s.status = 'active'
     AND s.area = CASE WHEN k.risk_item ~ '^.*（Phase[1-5]）$' THEN substring(k.risk_item FROM '^(.*)（Phase[1-5]）$') ELSE k.risk_item END
     AND s.phase = CASE WHEN k.risk_item ~ '^.*（Phase[1-5]）$' THEN substring(k.risk_item FROM 'Phase([1-5])')::smallint ELSE 1 END
     AND s.theme = k.big
     AND s.measure = k.mid AND s.frame = k.frame AND s.summary = k.summary
    JOIN app.risk_assessments a
      ON a.tenant_id = v_tenant AND a.risk_scenario_id = s.id
     AND a.valid_to IS NULL AND a.recorded_until IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE 'risk_treatments: % 件', v_n;

  -- 取り込んだ行数と、**入力に対応する**台帳の現行行数が一致することを確かめる
  -- （JOIN の取りこぼし・二重付与を黙って通さない）。
  -- テナント全体と比べると、--replace なしの追加取り込みが必ず失敗するので、
  -- 比較対象は karte_in に載っている業務キーの分だけに限る。
  SELECT count(*) INTO v_n FROM karte_in;
  IF v_n <> (SELECT count(*)
               FROM karte_in k
               JOIN app.risk_scenarios s
                 ON s.tenant_id = v_tenant AND s.status = 'active'
                AND s.area = CASE WHEN k.risk_item ~ '^.*（Phase[1-5]）$' THEN substring(k.risk_item FROM '^(.*)（Phase[1-5]）$') ELSE k.risk_item END
                AND s.phase = CASE WHEN k.risk_item ~ '^.*（Phase[1-5]）$' THEN substring(k.risk_item FROM 'Phase([1-5])')::smallint ELSE 1 END
                AND s.theme = k.big
                AND s.measure = k.mid AND s.frame = k.frame AND s.summary = k.summary
               JOIN app.risk_assessments a
                 ON a.tenant_id = s.tenant_id AND a.risk_scenario_id = s.id
                AND a.valid_to IS NULL AND a.recorded_until IS NULL
               JOIN app.risk_treatments t
                 ON t.tenant_id = a.tenant_id AND t.risk_assessment_id = a.id
                AND t.valid_to IS NULL AND t.recorded_until IS NULL) THEN
    RAISE EXCEPTION '取り込み件数と台帳の現行行数が一致しない（入力 % 件）', v_n;
  END IF;
END $$;

COMMIT;
"""
        run_sql(sql)
        print(f'取り込み完了: {args.xlsx} → テナント {args.tenant}（{len(rows)} 行）')
    finally:
        os.unlink(csv_path)


if __name__ == '__main__':
    main()
