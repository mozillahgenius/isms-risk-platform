#!/usr/bin/env bash
# Exercise 0046 reversibility on a database created exclusively for this test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${ISMS_TEST_DB:-isms_0046_reverse_$$}"

die() { printf '[0046 reverse] %s\n' "$*" >&2; exit 1; }
assert_sql() {
  local expected="$1" sql="$2" actual
  actual="$(psql -At -v ON_ERROR_STOP=1 -d "$DB" -c "$sql")" || die "assertion query failed"
  [ "$actual" = "$expected" ] || die "expected ${expected}, got ${actual}: ${sql}"
}
down_to_version() {
  local target="$1" count
  count="$(psql -At -v ON_ERROR_STOP=1 -d "$DB" -c "SELECT count(*) FROM public.schema_migrations WHERE version > '$target'")"
  [ "$count" -eq 0 ] || "$ROOT/scripts/migrate.sh" down "$count" >/dev/null
}

[ "$DB" != "isms_dev" ] || die "refuse shared db"
[ "$DB" != "${ISMS_DB:-isms_dev}" ] || die "test db must not be ISMS_DB"
if psql -At -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -qx 1; then
  die "refuse existing database ${DB}"
fi

CREATED=0
cleanup() {
  local rc=$?
  if [ "$CREATED" = "1" ]; then
    dropdb --if-exists "$DB" >/dev/null 2>&1 || rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

createdb "$DB"
CREATED=1
unset DATABASE_URL || true
export ISMS_DB="$DB"

# Establish an actual 0045 baseline using the normal migration runner.
"$ROOT/scripts/migrate.sh" up >/dev/null
down_to_version "0045"
assert_sql "0045" "SELECT max(version) FROM public.schema_migrations"

psql -v ON_ERROR_STOP=1 -d "$DB" <<'SQL'
INSERT INTO catalog.asset_classes_default (key,name_ja,rank,external_share_policy)
VALUES ('internal','fixture internal',2,'approval_required')
ON CONFLICT (key) DO NOTHING;
INSERT INTO app.assets (tenant_id,id,asset_key,name,asset_type,classification)
VALUES
  ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000201','reverse-preexisting','pre-existing RISK','system','internal'),
  ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000202','reverse-added','migration-added RISK','system','internal'),
  ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000203','reverse-released','released then human RISK','system','internal');
INSERT INTO app.asset_frameworks (tenant_id,asset_id,framework_key)
VALUES ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000201','RISK-MANAGEMENT');
SQL

"$ROOT/scripts/migrate.sh" up >/dev/null
down_to_version "0050"
assert_sql "0050" "SELECT max(version) FROM public.schema_migrations"
"$ROOT/scripts/migrate.sh" down 1 >/dev/null
assert_sql "0049" "SELECT max(version) FROM public.schema_migrations"
"$ROOT/scripts/migrate.sh" down 1 >/dev/null
assert_sql "0048" "SELECT max(version) FROM public.schema_migrations"
"$ROOT/scripts/migrate.sh" down 1 >/dev/null
assert_sql "0047" "SELECT max(version) FROM public.schema_migrations"
"$ROOT/scripts/migrate.sh" down 1 >/dev/null
assert_sql "0046" "SELECT max(version) FROM public.schema_migrations"

# Simulate the documented ownership handoff: remove the migration generation,
# mark it released, and re-add the relation with a human generation.
psql -v ON_ERROR_STOP=1 -d "$DB" <<'SQL'
BEGIN;
UPDATE app.framework_backfill_provenance SET ownership_released_at=now()
 WHERE migration_key='0046_management_framework_provenance'
   AND tenant_id='00000000-0000-0000-0000-000000000101' AND entity_type='asset'
   AND entity_id='00000000-0000-0000-0000-000000000203' AND framework_key='RISK-MANAGEMENT';
DELETE FROM app.framework_relation_origins
 WHERE tenant_id='00000000-0000-0000-0000-000000000101' AND entity_type='asset'
   AND entity_id='00000000-0000-0000-0000-000000000203' AND framework_key='RISK-MANAGEMENT';
DELETE FROM app.asset_frameworks
 WHERE tenant_id='00000000-0000-0000-0000-000000000101'
   AND asset_id='00000000-0000-0000-0000-000000000203' AND framework_key='RISK-MANAGEMENT';
INSERT INTO app.asset_frameworks (tenant_id,asset_id,framework_key)
VALUES ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000203','RISK-MANAGEMENT');
INSERT INTO app.framework_relation_origins
  (tenant_id,entity_type,entity_id,framework_key,generation_id,origin_kind,origin_id)
VALUES ('00000000-0000-0000-0000-000000000101','asset','00000000-0000-0000-0000-000000000203','RISK-MANAGEMENT','00000000-0000-0000-0000-000000000303','human','reverse-fixture');
INSERT INTO app.assets (tenant_id,id,asset_key,name,asset_type,classification)
VALUES ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000204','reverse-post-up','post-up human RISK','system','internal');
INSERT INTO app.asset_frameworks (tenant_id,asset_id,framework_key)
VALUES ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000204','RISK-MANAGEMENT');
INSERT INTO app.framework_relation_origins
  (tenant_id,entity_type,entity_id,framework_key,generation_id,origin_kind,origin_id)
VALUES ('00000000-0000-0000-0000-000000000101','asset','00000000-0000-0000-0000-000000000204','RISK-MANAGEMENT','00000000-0000-0000-0000-000000000304','human','reverse-fixture');
COMMIT;
SQL

# A provenance/origin mismatch must abort the rollback and leave 0046 applied.
PRECHECK_LOG="/tmp/isms-0046-down-preflight-$$.log"
psql -v ON_ERROR_STOP=1 -d "$DB" -c "UPDATE app.framework_relation_origins SET origin_id='tampered' WHERE tenant_id='00000000-0000-0000-0000-000000000101' AND entity_type='asset' AND entity_id='00000000-0000-0000-0000-000000000202' AND framework_key='RISK-MANAGEMENT'" >/dev/null
if "$ROOT/scripts/migrate.sh" down 1 >"$PRECHECK_LOG" 2>&1; then
  die "provenance mismatch unexpectedly rolled back"
fi
rg -q "0046 provenance preflight count/hash mismatch" "$PRECHECK_LOG" || die "preflight failure was not reported"
rm -f "$PRECHECK_LOG"
assert_sql "0046" "SELECT max(version) FROM public.schema_migrations"
psql -v ON_ERROR_STOP=1 -d "$DB" -c "UPDATE app.framework_relation_origins SET origin_id='0046_management_framework_provenance' WHERE tenant_id='00000000-0000-0000-0000-000000000101' AND entity_type='asset' AND entity_id='00000000-0000-0000-0000-000000000202' AND framework_key='RISK-MANAGEMENT'" >/dev/null

"$ROOT/scripts/migrate.sh" down 1 >/dev/null
assert_sql "0045" "SELECT max(version) FROM public.schema_migrations"
assert_sql "1" "SELECT count(*) FROM app.asset_frameworks WHERE asset_id='00000000-0000-0000-0000-000000000201' AND framework_key='RISK-MANAGEMENT'"
assert_sql "0" "SELECT count(*) FROM app.asset_frameworks WHERE asset_id='00000000-0000-0000-0000-000000000202' AND framework_key='RISK-MANAGEMENT'"
assert_sql "1" "SELECT count(*) FROM app.asset_frameworks WHERE asset_id='00000000-0000-0000-0000-000000000203' AND framework_key='RISK-MANAGEMENT'"
assert_sql "1" "SELECT count(*) FROM app.asset_frameworks WHERE asset_id='00000000-0000-0000-0000-000000000204' AND framework_key='RISK-MANAGEMENT'"

# M1 itself must round-trip to the exact 0049 relation/provenance state.  Keep
# one pre-existing relation and one missing active relation for every managed
# entity type, so the assertion catches asymmetric asset/risk/measure cleanup.
"$ROOT/scripts/migrate.sh" up >/dev/null
down_to_version "0049"
assert_sql "0049" "SELECT max(version) FROM public.schema_migrations"
# A 0050 rollback is safe only when the origin evidence was created by 0050.
# Keep the legacy relations but remove the older human origins before capturing
# this clean baseline; the later fixture below proves human/service evidence
# blocks the rollback.
psql -v ON_ERROR_STOP=1 -d "$DB" -c "DELETE FROM app.framework_relation_origins WHERE tenant_id='00000000-0000-0000-0000-000000000101' AND entity_id IN ('00000000-0000-0000-0000-000000000203','00000000-0000-0000-0000-000000000204')" >/dev/null
psql -v ON_ERROR_STOP=1 -d "$DB" <<'SQL'
INSERT INTO app.risk_scenarios (tenant_id,id,risk_key,domain,area,phase,theme,measure,frame,summary,status)
VALUES ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000205','m1-reverse-risk','M1','M1',1,'M1','M1','管理可能性','M1 reverse risk','active');
INSERT INTO app.measures (tenant_id,id,measure_key,name,summary,strategy,status)
VALUES ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000206','m1-reverse-measure','M1 reverse measure','M1','mitigate','planned');
SQL
STATE_0049="$(psql -At -v ON_ERROR_STOP=1 -d "$DB" -c "
  SELECT md5(coalesce(string_agg(row_to_json(x)::text, E'\\n' ORDER BY row_to_json(x)::text),''))
  FROM (
    SELECT 'asset_frameworks'::text AS kind, tenant_id::text, asset_id::text AS entity_id, framework_key FROM app.asset_frameworks
    UNION ALL SELECT 'risk_scenario_frameworks', tenant_id::text, risk_scenario_id::text, framework_key FROM app.risk_scenario_frameworks
    UNION ALL SELECT 'measure_frameworks', tenant_id::text, measure_id::text, framework_key FROM app.measure_frameworks
    UNION ALL SELECT 'origins', tenant_id::text, entity_id::text, entity_type||':'||framework_key||':'||generation_id||':'||origin_kind||':'||origin_id FROM app.framework_relation_origins
    UNION ALL SELECT 'provenance', tenant_id::text, entity_id::text, entity_type||':'||framework_key||':'||generation_id||':'||relation_created_by_migration::text||':'||coalesce(ownership_released_at::text,'') FROM app.framework_backfill_provenance
  ) x")"
METADATA_0049="$(psql -At -v ON_ERROR_STOP=1 -d "$DB" -c "
  SELECT md5(string_agg(row_to_json(x)::text, E'\\n' ORDER BY row_to_json(x)::text))
  FROM (
    SELECT p.oid::regprocedure::text AS object_name,p.proowner::regrole::text AS owner,
           p.prosecdef::text AS security_definer,coalesce(p.proacl::text,'') AS acl,
           coalesce(array_to_string(p.proconfig,','),'') AS config
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='app' AND p.proname IN
       ('accept_risk_snapshot','set_management_frameworks','execute_iso_framework_removal',
        'request_iso_framework_removal','approve_iso_framework_removal')
    UNION ALL
    SELECT 'table:app.approvals',c.relowner::regrole::text,'',coalesce(c.relacl::text,''),''
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='app' AND c.relname='approvals'
  ) x")"
"$ROOT/scripts/migrate.sh" up >/dev/null
down_to_version "0050"
assert_sql "0050" "SELECT max(version) FROM public.schema_migrations"
assert_sql "1" "SELECT count(*) FROM app.asset_frameworks WHERE asset_id='00000000-0000-0000-0000-000000000202' AND framework_key='RISK-MANAGEMENT'"
assert_sql "1" "SELECT count(*) FROM app.risk_scenario_frameworks WHERE risk_scenario_id='00000000-0000-0000-0000-000000000205' AND framework_key='RISK-MANAGEMENT'"
assert_sql "1" "SELECT count(*) FROM app.measure_frameworks WHERE measure_id='00000000-0000-0000-0000-000000000206' AND framework_key='RISK-MANAGEMENT'"

# 0049 has no representable form for measure-origin provenance or measure
# removal requests.  A down must fail closed with this post-M1 evidence rather
# than deleting it to satisfy the old entity-type checks.
psql -v ON_ERROR_STOP=1 -d "$DB" <<'SQL'
SET session_replication_role = replica;
INSERT INTO app.measures (tenant_id,id,measure_key,name,summary,strategy,status) VALUES
  ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000207','m1-human-measure','M1 human','fixture','mitigate','retired'),
  ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000208','m1-service-measure','M1 service','fixture','mitigate','retired');
INSERT INTO app.measure_frameworks (tenant_id,measure_id,framework_key) VALUES
  ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000207','RISK-MANAGEMENT'),
  ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000208','RISK-MANAGEMENT');
INSERT INTO app.framework_relation_origins
  (tenant_id,entity_type,entity_id,framework_key,generation_id,origin_kind,origin_id) VALUES
  ('00000000-0000-0000-0000-000000000101','measure','00000000-0000-0000-0000-000000000207','RISK-MANAGEMENT','00000000-0000-0000-0000-000000000307','human','reverse-fixture'),
  ('00000000-0000-0000-0000-000000000101','measure','00000000-0000-0000-0000-000000000208','RISK-MANAGEMENT','00000000-0000-0000-0000-000000000308','service','reverse-fixture');
INSERT INTO app.iso_framework_removal_requests
  (id,tenant_id,entity_type,entity_id,expected_generation_id,before_hash,after_hash,reason,alternate_control,expires_at,requested_by)
VALUES ('00000000-0000-0000-0000-000000000309','00000000-0000-0000-0000-000000000101','measure',
        '00000000-0000-0000-0000-000000000207','00000000-0000-0000-0000-000000000307',
        decode(repeat('aa',32),'hex'),decode(repeat('bb',32),'hex'),'fixture removal','fixture control',now()+interval '1 day',
        '00000000-0000-0000-0000-000000000401');
RESET session_replication_role;
SQL
M1_PRECHECK_LOG="/tmp/isms-0050-down-preflight-$$.log"
if "$ROOT/scripts/migrate.sh" down 1 >"$M1_PRECHECK_LOG" 2>&1; then
  die "0050 measure evidence unexpectedly rolled back"
fi
rg -q "0050 rollback blocked by non-representable management evidence" "$M1_PRECHECK_LOG" || die "0050 evidence preflight failure was not reported"
rm -f "$M1_PRECHECK_LOG"
assert_sql "0050" "SELECT max(version) FROM public.schema_migrations"
assert_sql "2" "SELECT count(*) FROM app.framework_relation_origins WHERE entity_type='measure' AND origin_kind IN ('human','service')"
assert_sql "1" "SELECT count(*) FROM app.iso_framework_removal_requests WHERE entity_type='measure'"
psql -v ON_ERROR_STOP=1 -d "$DB" -c "SET session_replication_role=replica; DELETE FROM app.iso_framework_removal_requests WHERE id='00000000-0000-0000-0000-000000000309'; DELETE FROM app.framework_relation_events WHERE generation_id IN ('00000000-0000-0000-0000-000000000307','00000000-0000-0000-0000-000000000308'); DELETE FROM app.framework_relation_origins WHERE entity_id IN ('00000000-0000-0000-0000-000000000207','00000000-0000-0000-0000-000000000208'); DELETE FROM app.measure_frameworks WHERE measure_id IN ('00000000-0000-0000-0000-000000000207','00000000-0000-0000-0000-000000000208'); DELETE FROM app.measures WHERE id IN ('00000000-0000-0000-0000-000000000207','00000000-0000-0000-0000-000000000208'); RESET session_replication_role;" >/dev/null
"$ROOT/scripts/migrate.sh" down 1 >/dev/null
assert_sql "0049" "SELECT max(version) FROM public.schema_migrations"
STATE_AFTER_DOWN="$(psql -At -v ON_ERROR_STOP=1 -d "$DB" -c "
  SELECT md5(coalesce(string_agg(row_to_json(x)::text, E'\\n' ORDER BY row_to_json(x)::text),''))
  FROM (
    SELECT 'asset_frameworks'::text AS kind, tenant_id::text, asset_id::text AS entity_id, framework_key FROM app.asset_frameworks
    UNION ALL SELECT 'risk_scenario_frameworks', tenant_id::text, risk_scenario_id::text, framework_key FROM app.risk_scenario_frameworks
    UNION ALL SELECT 'measure_frameworks', tenant_id::text, measure_id::text, framework_key FROM app.measure_frameworks
    UNION ALL SELECT 'origins', tenant_id::text, entity_id::text, entity_type||':'||framework_key||':'||generation_id||':'||origin_kind||':'||origin_id FROM app.framework_relation_origins
    UNION ALL SELECT 'provenance', tenant_id::text, entity_id::text, entity_type||':'||framework_key||':'||generation_id||':'||relation_created_by_migration::text||':'||coalesce(ownership_released_at::text,'') FROM app.framework_backfill_provenance
  ) x")"
[ "$STATE_AFTER_DOWN" = "$STATE_0049" ] || die "0050 rollback did not restore the exact 0049 relation/provenance state"
METADATA_AFTER_DOWN="$(psql -At -v ON_ERROR_STOP=1 -d "$DB" -c "
  SELECT md5(string_agg(row_to_json(x)::text, E'\\n' ORDER BY row_to_json(x)::text))
  FROM (
    SELECT p.oid::regprocedure::text AS object_name,p.proowner::regrole::text AS owner,
           p.prosecdef::text AS security_definer,coalesce(p.proacl::text,'') AS acl,
           coalesce(array_to_string(p.proconfig,','),'') AS config
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='app' AND p.proname IN
       ('accept_risk_snapshot','set_management_frameworks','execute_iso_framework_removal',
        'request_iso_framework_removal','approve_iso_framework_removal')
    UNION ALL
    SELECT 'table:app.approvals',c.relowner::regrole::text,'',coalesce(c.relacl::text,''),''
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='app' AND c.relname='approvals'
  ) x")"
[ "$METADATA_AFTER_DOWN" = "$METADATA_0049" ] || die "0050 rollback did not restore exact 0049 function/security/grant metadata"

echo "management_0046_reverse_fixture: PASS"
