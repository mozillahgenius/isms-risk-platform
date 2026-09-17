# -*- coding: utf-8 -*-
"""DB → CSV → 既存 build_risk_map.py で xlsx を再出力する（Phase 0 の後半）。

  python3 phase0/export_xlsx.py --tenant <uuid> --scale biz --out out.xlsx

設計書 7.2 のとおり **既存資産を無改変で呼ぶ**。ここでは CSV を作って渡すだけで、
xlsx の組み立てには一切手を出さない。参照先は環境変数 RISK_MAP_SCRIPTS_DIR
（外部の生成器はこのリポジトリには含めない）。

--scale は必須。既存 CSV の Impact 列は 1 つしか無いので、impact_sec と impact_biz の
どちらを流すかを毎回明示する（設計書 7.2「既定値を持たせない」）。
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
    p = os.path.join(d, 'build_risk_map.py')
    if not os.path.isfile(p):
        raise SystemExit(
            'RISK_MAP_SCRIPTS_DIR が未設定です。外部のレポート生成器 build_risk_map.py を置いた'
            'ディレクトリを指定してください（このリポジトリには含まれません）。')
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tenant', required=True)
    ap.add_argument('--scale', required=True, choices=['sec', 'biz'],
                    help='どちらの影響度尺度を Impact 列へ流すか。省略不可')
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    # SQL へ埋める前に uuid として厳密に検証する（文字列補間の入口を塞ぐ）
    try:
        tenant = str(_uuid.UUID(args.tenant))
    except (ValueError, AttributeError, TypeError):
        raise SystemExit(f'--tenant が uuid ではありません: {args.tenant!r}')

    impact_col = 'impact_sec' if args.scale == 'sec' else 'impact_biz'
    after_col = 'impact_sec_after' if args.scale == 'sec' else 'impact_biz_after'

    # 並び順は Python 側の正規化と揃えるため COLLATE "C"（コードポイント順）を明示する。
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
    # COPY ... HEADER true は 0 件でもヘッダ行を返す。空文字かどうかでは
    # 「そのテナントにデータが無い」を検知できない。データ行を数える。
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
