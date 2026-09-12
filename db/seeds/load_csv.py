# -*- coding: utf-8 -*-
"""Load the control catalog CSV into catalog.

  python3 db/seeds/load_csv.py [--scripts-dir <dir>]

--scripts-dir (or env var LEGAL_SCRIPTS_DIR) defaults to db/seeds/snapshots.
Only a small fictional sample is bundled. Put your own catalog in another directory
with the same columns and relative paths, and point to it.

Loads:
  control_check/control_requirements_master.csv -> catalog.controls（framework_key='IPO-KARTE'）
  risk_map/risk_map_master.csv                  -> catalog.risk_scenario_templates

Policy:
  - Validate the CSV before loading (encoding, column count, empty values, duplicates). Load nothing if even one row is broken
  - Idempotent. ON CONFLICT DO UPDATE on natural keys
  - **Set retired_at on rows that disappeared from the input** (DO UPDATE alone would leave the old rows)
  - Verify representative records, not just counts (verify_seeds.sql cross-checks after loading)
"""
from __future__ import annotations

import argparse
import csv
import io
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_SCRIPTS = os.path.join(ROOT, 'db', 'seeds', 'snapshots')
FRAMES = ('管理可能性', '精度', 'スピード')


def db_url():
    return os.environ.get('DATABASE_URL') or f"postgres:///{os.environ.get('ISMS_DB', 'isms_dev')}"


def read_csv_checked(path, required_cols, label):
    """Read and validate the CSV. Raises if broken."""
    with open(path, 'rb') as f:
        raw = f.read()
    try:
        text = raw.decode('utf-8')
    except UnicodeDecodeError as e:
        raise SystemExit(f'{label}: UTF-8 として読めない（{e}）')
    if '\r\n' in text:
        text = text.replace('\r\n', '\n')
    rows = list(csv.DictReader(io.StringIO(text)))
    if not rows:
        raise SystemExit(f'{label}: データ行が 0')
    missing = [c for c in required_cols if c not in rows[0]]
    if missing:
        raise SystemExit(f'{label}: 必要な列が無い {missing}')
    for i, r in enumerate(rows, start=2):
        if len(r) != len(rows[0]):
            raise SystemExit(f'{label} 行{i}: 列数が不一致')
        for c in required_cols:
            if r.get(c) is None or str(r[c]).strip() == '':
                raise SystemExit(f'{label} 行{i}: {c} が空')
    return rows


def run_sql(sql):
    p = subprocess.run(['psql', '-v', 'ON_ERROR_STOP=1', '-q', db_url(), '-f', '-'],
                       input=sql, text=True, capture_output=True)
    if p.returncode != 0:
        sys.stderr.write(p.stdout + p.stderr)
        raise SystemExit(f'psql が失敗しました（exit={p.returncode}）')
    sys.stdout.write(p.stdout)


def load_controls(scripts_dir):
    path = os.path.join(scripts_dir, 'control_check', 'control_requirements_master.csv')
    cols = ['大項目記号', '大項目', '中項目', '小項目コード', '小項目', '要請No', '要請事項']
    rows = read_csv_checked(path, cols, 'control_requirements_master.csv')

    seen = set()
    out = []
    for i, r in enumerate(rows, start=2):
        # code = <category symbol>-<subitem code>(<requirement No>) e.g. A-30-10-10(3)
        req_no = r['要請No'].strip().strip('()（）')
        code = f"{r['大項目記号'].strip()}-{r['小項目コード'].strip()}({req_no})"
        if code in seen:
            raise SystemExit(f'control_requirements_master.csv 行{i}: code の重複 {code}')
        seen.add(code)
        out.append((code, r['要請事項'].strip(),
                    f"{r['大項目'].strip()} / {r['中項目'].strip()} / {r['小項目'].strip()}"))
    return out


def load_templates(scripts_dir):
    path = os.path.join(scripts_dir, 'risk_map', 'risk_map_master.csv')
    cols = ['RiskItem', 'Big', 'Mid', 'Frame', 'Summary', 'Action']
    rows = read_csv_checked(path, cols, 'risk_map_master.csv')

    seen = set()
    out = []
    for i, r in enumerate(rows, start=2):
        raw_domain = r['RiskItem'].strip()
        m = re.fullmatch(r'(.+)（Phase([1-5])）', raw_domain)
        if not m:
            raise SystemExit(f'risk_map_master.csv 行{i}: RiskItem の Phase 表記が不正 ({raw_domain})')
        area = m.group(1).strip()
        phase = int(m.group(2))
        frame = r['Frame'].strip()
        if frame not in FRAMES:
            raise SystemExit(f'risk_map_master.csv 行{i}: Frame が {"/".join(FRAMES)} 以外 ({frame})')
        key = (area, phase, r['Big'].strip(), r['Mid'].strip(), frame, r['Summary'].strip())
        if key in seen:
            raise SystemExit(f'risk_map_master.csv 行{i}: 業務キーの重複')
        seen.add(key)
        out.append(key + (r['Action'].strip(),))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--scripts-dir', default=os.environ.get('LEGAL_SCRIPTS_DIR', DEFAULT_SCRIPTS))
    args = ap.parse_args()
    if not os.path.isdir(args.scripts_dir):
        raise SystemExit(f'カタログ CSV のディレクトリが見つかりません: {args.scripts_dir}')

    controls = load_controls(args.scripts_dir)
    templates = load_templates(args.scripts_dir)
    print(f'検査 OK: 統制 {len(controls)} 件 / リスクテンプレート {len(templates)} 件')

    with tempfile.TemporaryDirectory() as td:
        cpath = os.path.join(td, 'controls.csv')
        with open(cpath, 'w', encoding='utf-8', newline='') as f:
            w = csv.writer(f)
            w.writerow(['code', 'title_ja', 'theme'])
            w.writerows(controls)
        tpath = os.path.join(td, 'templates.csv')
        with open(tpath, 'w', encoding='utf-8', newline='') as f:
            w = csv.writer(f)
            w.writerow(['domain', 'phase', 'theme', 'measure', 'frame', 'summary', 'default_action'])
            w.writerows(templates)

        run_sql(f"""
BEGIN;
SELECT pg_advisory_xact_lock(8891234501);
SET ROLE schema_owner;

CREATE TEMP TABLE ctl_in (code text, title_ja text, theme text) ON COMMIT DROP;
\\copy ctl_in FROM '{cpath}' WITH (FORMAT csv, HEADER true)

INSERT INTO catalog.controls (framework_key, code, title_ja, theme)
SELECT 'IPO-KARTE', code, title_ja, theme FROM ctl_in
ON CONFLICT (framework_key, code) DO UPDATE
  SET title_ja = EXCLUDED.title_ja, theme = EXCLUDED.theme, retired_at = NULL;

INSERT INTO catalog.control_frameworks (control_id, framework_key)
SELECT c.id, 'IPO-KARTE'
  FROM catalog.controls c JOIN ctl_in i ON i.code = c.code
 WHERE c.framework_key = 'IPO-KARTE'
ON CONFLICT DO NOTHING;

-- Controls removed from the input are retired (not physically deleted, because the app side references them via FK)
UPDATE catalog.controls c SET retired_at = now()
 WHERE c.framework_key = 'IPO-KARTE' AND c.retired_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM ctl_in i WHERE i.code = c.code);

CREATE TEMP TABLE tpl_in (domain text, phase smallint, theme text, measure text,
                          frame text, summary text, default_action text) ON COMMIT DROP;
\\copy tpl_in FROM '{tpath}' WITH (FORMAT csv, HEADER true)

INSERT INTO catalog.risk_scenario_templates
  (domain, area, phase, theme, measure, frame, summary, default_action)
SELECT domain, domain, phase, theme, measure, frame, summary, default_action FROM tpl_in
ON CONFLICT (domain, phase, theme, measure, frame, summary) DO UPDATE
  SET default_action = EXCLUDED.default_action, retired_at = NULL;

INSERT INTO catalog.risk_template_frameworks (template_id, framework_key)
SELECT t.id, 'RISK-MANAGEMENT'
  FROM catalog.risk_scenario_templates t
  JOIN tpl_in i ON i.domain = t.domain AND i.phase = t.phase
              AND i.theme = t.theme AND i.measure = t.measure
              AND i.frame = t.frame AND i.summary = t.summary
ON CONFLICT DO NOTHING;

UPDATE catalog.risk_scenario_templates t SET retired_at = now()
 WHERE t.retired_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM tpl_in i
                    WHERE i.domain = t.domain AND i.phase = t.phase
                      AND i.theme = t.theme
                      AND i.measure = t.measure AND i.frame = t.frame
                      AND i.summary = t.summary);

RESET ROLE;
COMMIT;
""")
    print('投入完了')


if __name__ == '__main__':
    main()
