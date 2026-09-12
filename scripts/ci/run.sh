#!/usr/bin/env bash
# Quality gate (the parts of design doc 11.5 implemented so far).
# Exits non-zero if any step fails. Nothing passes until everything is green.
#
#   scripts/ci/run.sh
#
# DB used: ISMS_CI_DB (default isms_ci). It is recreated, so existing data is lost.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CIDB="${ISMS_CI_DB:-isms_ci}"

step() { printf '\n\033[36m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
die()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

export ISMS_DB="$CIDB"
unset DATABASE_URL || true

# Control catalog CSVs. Default is the bundled fictional sample. Point LEGAL_SCRIPTS_DIR at your own catalog.
SNAPSHOT_DIR="$ROOT/db/seeds/snapshots"
CATALOG_DIR="${LEGAL_SCRIPTS_DIR:-$SNAPSHOT_DIR}"
csv_rows() { # $1 = CSV path. Number of data rows excluding the header (newlines inside quotes count as one row)
  python3 -c 'import csv,sys; print(sum(1 for _ in csv.DictReader(open(sys.argv[1], encoding="utf-8"))))' "$1"
}

step "0. 実行環境"
psql -At -d postgres -c "select version()" | head -1
printf '  \033[33m注意\033[0m 設計書は PostgreSQL 16 前提。この機は上の版で検証している。\n'
printf '        PG16 での検証は Docker が使える環境で別途行うこと（未実施）。\n'

step "1. 同梱サンプルカタログの SHA-256 突合"
(cd "$SNAPSHOT_DIR" && shasum -a 256 -c SHA256SUMS) >/dev/null \
  || die "db/seeds/snapshots/SHA256SUMS と一致しない"
ok "db/seeds/snapshots/SHA256SUMS"

step "2. 空 DB へ全 DDL を適用する"
dropdb --if-exists "$CIDB" >/dev/null
createdb "$CIDB"
"$ROOT/scripts/migrate.sh" up >/dev/null 2>&1 || die "up が失敗"
APPLIED=$(psql -At -d "$CIDB" -c "select count(*) from public.schema_migrations")
TOTAL=$(ls "$ROOT"/db/migrations/*.up.sql | wc -l | tr -d ' ')
[ "$APPLIED" = "$TOTAL" ] || die "適用数が不一致 ($APPLIED / $TOTAL)"
ok "$TOTAL 本すべて適用"

step "3. RLS 網羅・ロール属性・実効権限"
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/scripts/ci/check_rls.sql" >/dev/null \
  || die "check_rls.sql が落ちた"
ok "check_rls.sql"

step "4. 巻き戻し（up → down → up）と、無関係オブジェクトの保全"
# Place a sentinel in a separate schema to see whether down deletes too much.
psql -q -v ON_ERROR_STOP=1 -d "$CIDB" >/dev/null <<'SQL'
CREATE SCHEMA IF NOT EXISTS sentinel;
CREATE TABLE IF NOT EXISTS sentinel.keepme (id int primary key, note text);
INSERT INTO sentinel.keepme VALUES (1, '消えてはいけない') ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION sentinel.keepfn() RETURNS int LANGUAGE sql AS 'SELECT 1';
SQL
# Record the object list before migrations and check it matches exactly after down
SNAP_BEFORE=$(psql -At -d "$CIDB" -c "
  select coalesce(string_agg(x,E'\n' order by x),'') from (
    select n.nspname||'.'||c.relname as x from pg_class c
      join pg_namespace n on n.oid=c.relnamespace
     where n.nspname not in ('pg_catalog','information_schema','pg_toast')
  ) t")

"$ROOT/scripts/migrate.sh" down all >/dev/null 2>&1 || die "down が失敗"

SNAP_AFTER=$(psql -At -d "$CIDB" -c "
  select coalesce(string_agg(x,E'\n' order by x),'') from (
    select n.nspname||'.'||c.relname as x from pg_class c
      join pg_namespace n on n.oid=c.relnamespace
     where n.nspname not in ('pg_catalog','information_schema','pg_toast')
  ) t")

# After down, only "pre-migration objects + schema_migrations" should remain
EXPECTED=$(printf '%s\npublic.schema_migrations\npublic.schema_migrations_pkey\n' "" | sort -u)
psql -At -d "$CIDB" -c "select count(*) from sentinel.keepme where id=1" | grep -qx 1 \
  || die "sentinel テーブルの行が消えた（down が過剰）"
psql -At -d "$CIDB" -c "select sentinel.keepfn()" | grep -qx 1 \
  || die "sentinel 関数が消えた（down が過剰）"
psql -At -d "$CIDB" -c "
  select count(*) from pg_namespace where nspname in ('app','catalog','audit')" \
  | grep -qx 0 || die "down 後もスキーマが残っている"
# Roles are cluster-wide, so it is correct for them to remain while another DB in the same cluster
# (e.g. for development) references them. Here we check that "dependencies from this DB are gone".
psql -At -d "$CIDB" -c "
  select count(*) from pg_shdepend d
    join pg_roles ro on ro.oid = d.refobjid
   where ro.rolname in ('schema_owner','app_rw','app_ro','auditlogd','audit_verifier')
     and d.dbid = (select oid from pg_database where datname = current_database())" \
  | grep -qx 0 || die "down 後もこの DB のオブジェクトがロールに依存している"
ok "down で自分の作ったものだけが消え、sentinel は残った"

"$ROOT/scripts/migrate.sh" up >/dev/null 2>&1 || die "down 後の up が失敗"
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/scripts/ci/check_rls.sql" >/dev/null \
  || die "再適用後に check_rls.sql が落ちた"
ok "up → down → up が通る"

step "5. seed（冪等性・件数・代表レコード）"
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0002_checks_core.sql" >/dev/null
ISMS_DB="$CIDB" python3 "$ROOT/db/seeds/0003_connectors.py" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0004_phase2_checks.sql" >/dev/null
ISMS_DB="$CIDB" python3 "$ROOT/db/seeds/0005_agent_definition.py" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0006_phase3_device_checks.sql" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0007_policies_core.sql" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0008_policies_extended.sql" >/dev/null
python3 "$ROOT/db/seeds/load_csv.py" --scripts-dir "$CATALOG_DIR" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0009_relationships.sql" >/dev/null
C1=$(psql -At -d "$CIDB" -c "
  select (select count(*) from catalog.controls)||'/'||
         (select count(*) from catalog.risk_scenario_templates)||'/'||
         (select count(*) from catalog.calendar_events_default)||'/'||
         (select count(*) from catalog.policies_default)||'/'||
         (select count(*) from catalog.roles_default)||'/'||
         (select count(*) from catalog.asset_classes_default)||'/'||
         (select count(*) from catalog.checks)||'/'||
         (select count(*) from catalog.connector_manifests)")
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0002_checks_core.sql" >/dev/null
ISMS_DB="$CIDB" python3 "$ROOT/db/seeds/0003_connectors.py" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0004_phase2_checks.sql" >/dev/null
ISMS_DB="$CIDB" python3 "$ROOT/db/seeds/0005_agent_definition.py" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0006_phase3_device_checks.sql" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0007_policies_core.sql" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0008_policies_extended.sql" >/dev/null
python3 "$ROOT/db/seeds/load_csv.py" --scripts-dir "$CATALOG_DIR" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/db/seeds/0009_relationships.sql" >/dev/null
C2=$(psql -At -d "$CIDB" -c "
  select (select count(*) from catalog.controls)||'/'||
         (select count(*) from catalog.risk_scenario_templates)||'/'||
         (select count(*) from catalog.calendar_events_default)||'/'||
         (select count(*) from catalog.policies_default)||'/'||
         (select count(*) from catalog.roles_default)||'/'||
         (select count(*) from catalog.asset_classes_default)||'/'||
         (select count(*) from catalog.checks)||'/'||
         (select count(*) from catalog.connector_manifests)")
[ "$C1" = "$C2" ] || die "seed を 2 回流すと件数が変わる (冪等でない): ${C1} -> ${C2}"
# Controls = CSV controls + the 93 of ISO/IEC 27001:2022 Annex A (0009). Risk templates = CSV row count.
N_CTL=$(csv_rows "$CATALOG_DIR/control_check/control_requirements_master.csv")
N_TPL=$(csv_rows "$CATALOG_DIR/risk_map/risk_map_master.csv")
WANT="$((N_CTL + 93))/${N_TPL}/14/28/5/4/20/2"
[ "$C1" = "$WANT" ] || die "seed の件数が期待値と違う: $C1 (期待 $WANT)"
ok "2 回流しても件数が変わらない: ${C2}"

psql -v ON_ERROR_STOP=1 -q -d "$CIDB" -f "$ROOT/scripts/ci/check_seeds.sql" >/dev/null \
  || die "check_seeds.sql が落ちた"
ok "check_seeds.sql"

step "6. テナント分離・テナント文脈（app_rw / app_ro の実接続）"
"$ROOT/tests/rls_test.sh" >/dev/null || die "rls_test.sh が落ちた"
ok "rls_test.sh"

step "7. ドメイン制約"
"$ROOT/tests/domain_test.sh" >/dev/null || die "domain_test.sh が落ちた"
ok "domain_test.sh"

step "8. Management M2/M3 と 0046 逆向き検証（使い捨て DB）"
ISMS_DB="$CIDB" ISMS_TEST_DB="isms_test_management_gate_$$" "$ROOT/tests/run_isolated.sh" >/dev/null \
  || die "management isolated acceptance が落ちた"
ok "isms_risk_read_model / management_workflows / management_0046_reverse_fixture"

step "9. Phase 0（xlsx 往復・差分 0 件）"
if [ -z "${RISK_MAP_SCRIPTS_DIR:-}" ]; then
  printf '  \033[33mSKIP\033[0m RISK_MAP_SCRIPTS_DIR 未設定（外部の build_risk_map.py が必要。README 参照）\n'
else
  "$ROOT/phase0/run_acceptance.sh" >/dev/null || die "Phase 0 受入が落ちた"
  ok "phase0/run_acceptance.sh"
fi

step "10. チェック機能（checker）— 落ちることを確かめてから合否を出す"
"$ROOT/tests/checker_test.sh" >/dev/null || die "checker_test.sh が落ちた"
ok "checker_test.sh"

step "11. Phase 3a macOS agent（enroll → posture → 改変拒否）"
"$ROOT/tests/agent_acceptance_test.sh" >/dev/null || die "agent_acceptance_test.sh が落ちた"
ok "agent_acceptance_test.sh"

step "12. backoffice → ISMS HR identity link（存在しないHR IDの逆向き検証）"
python3 "$ROOT/scripts/hr_identity_link.py" --self-test >/dev/null \
  || die "hr_identity_link.py --self-test が落ちた"
ok "hr_identity_link.py --self-test"

step "13. role別pgpass生成"
python3 "$ROOT/scripts/configure_db_roles.py" --self-test >/dev/null \
  || die "configure_db_roles.py --self-test が落ちた"
"$ROOT/tests/configure_db_roles_test.sh" >/dev/null \
  || die "configure_db_roles_test.sh が落ちた"
ok "configure_db_roles.py self-test / libpq integration"

printf '\n\033[32m品質ゲート: 全て緑\033[0m\n'
printf '未実施のゲート（設計書 11.5 のうち Phase 2 以降）:\n'
printf '  - コネクタの外部 API 実接続（記録済みレスポンスの再生は make connector-test で実施）\n'
printf '  - PostgreSQL 16 での検証（Docker が要る）\n'
