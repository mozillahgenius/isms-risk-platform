# -*- coding: utf-8 -*-
"""DB -> CSV -> re-export the xlsx with the existing build_risk_map.py (second half of Phase 0).

  python3 phase0/export_xlsx.py --tenant <uuid> --scale biz --out out.xlsx

As per design doc 7.2, **the existing asset is called unmodified**. This only builds the CSV and hands it over,
never touching the xlsx assembly. The location comes from the environment variable RISK_MAP_SCRIPTS_DIR
(required; the generator is not included in this repository).

--scale is required. The existing CSV has only one Impact column, so which of impact_sec and impact_biz
to feed must be stated explicitly every time (design doc 7.2 "no defaults").
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import uuid as _uuid

HERE = os.path.dirname(os.path.abspath(__file__))


def db_url():
    return os.environ.get('DATABASE_URL') or f"postgres:///{os.environ.get('ISMS_DB', 'isms_dev')}"


def builder_path():
    d = os.environ.get('RISK_MAP_SCRIPTS_DIR', '')
    if not d:
        raise SystemExit(
            'RISK_MAP_SCRIPTS_DIR が未設定です。外部のレポート生成器 build_risk_map.py を置いた'
            'ディレクトリを指定してください（このリポジトリには含まれません）。')
    p = os.path.join(d, 'build_risk_map.py')
    if not os.path.isfile(p):
        raise SystemExit(
            f'build_risk_map.py が見つかりません: {p}\n'
            'RISK_MAP_SCRIPTS_DIR で build_risk_map.py のあるディレクトリを指してください。')
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tenant', required=True)
    ap.add_argument('--scale', required=True, choices=['sec', 'biz'],
                    help='どちらの影響度尺度を Impact 列へ流すか。省略不可')
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    # Strictly validate as a uuid before embedding in SQL (closes the string-interpolation entry point)
    try:
        tenant = str(_uuid.UUID(args.tenant))
    except (ValueError, AttributeError, TypeError):
        raise SystemExit(f'--tenant が uuid ではありません: {args.tenant!r}')

    impact_col = 'impact_sec' if args.scale == 'sec' else 'impact_biz'
    after_col = 'impact_sec_after' if args.scale == 'sec' else 'impact_biz_after'

    # Specify COLLATE "C" (code point order) explicitly so ordering matches the Python-side normalization.
    query = f"""
COPY (
  SELECT CASE WHEN s.phase BETWEEN 1 AND 5
              THEN s.domain || '（Phase' || s.phase::text || '）'
              ELSE s.domain END AS "RiskItem",
         s.theme       AS "Big",
         s.measure     AS "Mid",
         s.frame       AS "Frame",
         s.summary     AS "Summary",
         a.prob        AS "ProbBefore",
         a.{impact_col} AS "ImpactBefore",
         t.action_plan AS "Action",
         t.prob_after  AS "ProbAfter",
         t.{after_col} AS "ImpactAfter"
    FROM app.risk_scenarios s
    JOIN app.risk_assessments a
      ON a.tenant_id = s.tenant_id AND a.risk_scenario_id = s.id
     AND a.valid_to IS NULL AND a.recorded_until IS NULL
    LEFT JOIN app.risk_treatments t
      ON t.tenant_id = a.tenant_id AND t.risk_assessment_id = a.id
     AND t.valid_to IS NULL AND t.recorded_until IS NULL
   WHERE s.tenant_id = '{tenant}' AND s.status = 'active'
   ORDER BY (CASE WHEN s.phase BETWEEN 1 AND 5
                  THEN s.domain || '（Phase' || s.phase::text || '）'
                  ELSE s.domain END) COLLATE "C",
            s.theme COLLATE "C", s.measure COLLATE "C",
            s.frame COLLATE "C", s.summary COLLATE "C"
) TO STDOUT WITH (FORMAT csv, HEADER true)
"""
    p = subprocess.run(['psql', '-v', 'ON_ERROR_STOP=1', '-q', '-A', '-t', db_url(),
                        '-c', query], text=True, capture_output=True)
    if p.returncode != 0:
        sys.stderr.write(p.stdout + p.stderr)
        raise SystemExit('DB からの抽出に失敗しました')
    # COPY ... HEADER true returns a header row even for 0 rows. Checking for an empty string
    # cannot detect "the tenant has no data". Count the data rows.
    lines = [ln for ln in p.stdout.splitlines() if ln.strip()]
    if len(lines) < 2:
        raise SystemExit(f'抽出結果が 0 件です（テナント {tenant}）')

    with tempfile.NamedTemporaryFile('w', suffix='.csv', delete=False,
                                     encoding='utf-8') as f:
        f.write(p.stdout)
        csv_path = f.name

    try:
        b = builder_path()
        r = subprocess.run([sys.executable, b, csv_path, args.out],
                           text=True, capture_output=True)
        if r.returncode != 0:
            sys.stderr.write(r.stdout + r.stderr)
            raise SystemExit('build_risk_map.py が失敗しました')
        print(r.stdout.strip())
        print(f'再出力: {args.out}（尺度={args.scale}）')
    finally:
        os.unlink(csv_path)


if __name__ == '__main__':
    main()
