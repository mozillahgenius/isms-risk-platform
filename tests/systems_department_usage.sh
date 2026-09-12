#!/usr/bin/env bash
# Acceptance for 0061: members can edit systems in use and auditors cannot;
# department usage records; asset location (system FK + free text); department view aggregation.
#
# Verify not only "passes" but also "fails for the intended reason".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${ISMS_TEST_DB:-isms_systems_$$}"
die() { printf '[systems] %s\n' "$*" >&2; exit 1; }
expect_fail_because() {
  local want="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then die "unexpected success: $*"; fi
  case "$out" in
    *"$want"*) ;;
    *) die "failed for the wrong reason (want '$want'): $out" ;;
  esac
}
sql() { psql -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

[ "$DB" != "isms_dev" ] || die "refuse shared db"
psql -At -d postgres -c "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -qx 1 && die "refuse existing database"
createdb "$DB"; trap 'dropdb --if-exists "$DB" >/dev/null 2>&1' EXIT
export ISMS_DB="$DB"; unset DATABASE_URL || true
"$ROOT/scripts/migrate.sh" up >/dev/null
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null

T1=10000000-0000-4000-8000-000000000001
T2=20000000-0000-4000-8000-000000000001
sql <<'SQL'
INSERT INTO catalog.asset_classes_default(key,name_ja,rank,external_share_policy)
  VALUES ('internal','社内限定',2,'approval_required') ON CONFLICT DO NOTHING;
INSERT INTO app.tenants(id,name,domain,dom_version_id)
  SELECT '10000000-0000-4000-8000-000000000001','one','one.test',id FROM catalog.dom_versions LIMIT 1;
INSERT INTO app.tenants(id,name,domain,dom_version_id)
  SELECT '20000000-0000-4000-8000-000000000001','two','two.test',id FROM catalog.dom_versions LIMIT 1;
INSERT INTO app.users(tenant_id,id,email,display_name) VALUES
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000011','ciso@one.test','ciso'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000014','member@one.test','member'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000015','auditor@one.test','auditor'),
 ('20000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000011','ciso@two.test','other');
INSERT INTO app.memberships(tenant_id,user_id,role_key) VALUES
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000011','ciso'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000014','employee'),
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000015','auditor'),
 ('20000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000011','ciso');
SQL

token_for() { sql -c "SET ROLE auth_svc; SELECT app.create_session('$1','$2','$3',interval '1 hour'); RESET ROLE" >/dev/null; }
CISO_T=ciso-token-00000000000000000000000000000001
MEM_T=member-token-0000000000000000000000000000004
AUD_T=auditor-token-00000000000000000000000000005
OTHER_T=other-token-00000000000000000000000000000005
token_for "$T1" 10000000-0000-4000-8000-000000000011 "$CISO_T"
token_for "$T1" 10000000-0000-4000-8000-000000000014 "$MEM_T"
token_for "$T1" 10000000-0000-4000-8000-000000000015 "$AUD_T"
token_for "$T2" 20000000-0000-4000-8000-000000000011 "$OTHER_T"

call_as() {
  PGPASSWORD='' psql -Atq -v ON_ERROR_STOP=1 -U app_rw -d "$DB" \
    -c "BEGIN; SELECT app.set_tenant_context('$1'); $2 COMMIT;"
}

# --- 0045's controls are not removed (direct DML is still disallowed) -------------------------
# Keep 0045's design of "write only after adding dedicated RPCs" as is.
expect_fail_because 'permission denied for table application_catalog' call_as "$CISO_T" \
  "INSERT INTO app.application_catalog(tenant_id,app_key,name,provider) VALUES(app.current_tenant(),'direct','直接','x');"

# --- Systems in use are editable by members (the request's "each member edits") -------
SYS_ID="$(call_as "$MEM_T" "SELECT app.create_system('google-workspace','Google Workspace','google','active');" | tail -1 | tr -d ' ')"
[ -n "$SYS_ID" ] || die "member could not register a system"
[ "$(sql -At -c "SELECT name FROM app.application_catalog WHERE app_key='google-workspace'")" = 'Google Workspace' ] \
  || die "system was not stored"
call_as "$MEM_T" "SELECT app.update_system('$SYS_ID'::uuid,'Google Workspace (社内)','google','active');" >/dev/null
[ "$(sql -At -c "SELECT name FROM app.application_catalog WHERE app_key='google-workspace'")" = 'Google Workspace (社内)' ] \
  || die "member could not edit a system"

# created_by is filled with the submitter themselves.
[ "$(sql -At -c "SELECT created_by FROM app.application_catalog WHERE app_key='google-workspace'")" \
  = 10000000-0000-4000-8000-000000000014 ] || die "created_by was not stamped with the actor"

# Auditors do not change business data.
expect_fail_because 'system edit permission required' call_as "$AUD_T" \
  "SELECT app.create_system('nope','だめ','x','active');"
expect_fail_because 'system edit permission required' call_as "$AUD_T" \
  "SELECT app.update_system('$SYS_ID'::uuid,'書き換え','x','active');"

# --- Department usage records ---------------------------------------------------------
call_as "$CISO_T" "INSERT INTO app.departments(tenant_id,id,name) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000031','営業部'),(app.current_tenant(),'10000000-0000-4000-8000-000000000032','管理部');" >/dev/null
call_as "$MEM_T" "INSERT INTO app.department_systems(tenant_id,department_id,application_id,usage_note) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000031','$SYS_ID','顧客の連絡先と見積の共有');" >/dev/null
[ "$(sql -At -c "SELECT usage_note FROM app.department_systems")" = '顧客の連絡先と見積の共有' ] \
  || die "member could not record department usage"
expect_fail_because 'system edit permission required' call_as "$AUD_T" \
  "DELETE FROM app.department_systems WHERE department_id='10000000-0000-4000-8000-000000000031';"

# The submitter can't be spoofed (even if the caller specifies created_by, it is overwritten with the actual user).
call_as "$MEM_T" "INSERT INTO app.department_systems(tenant_id,department_id,application_id,usage_note,created_by,updated_by) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000032','$SYS_ID','偽装の試み','10000000-0000-4000-8000-000000000011','10000000-0000-4000-8000-000000000011');" >/dev/null
[ "$(sql -At -c "SELECT created_by FROM app.department_systems WHERE department_id='10000000-0000-4000-8000-000000000032'")" \
  = 10000000-0000-4000-8000-000000000014 ] || die "created_by was forgeable on insert"
# created_by can't be changed on update either.
call_as "$CISO_T" "UPDATE app.department_systems SET usage_note='上書き', created_by='10000000-0000-4000-8000-000000000011' WHERE department_id='10000000-0000-4000-8000-000000000032';" >/dev/null
[ "$(sql -At -c "SELECT created_by FROM app.department_systems WHERE department_id='10000000-0000-4000-8000-000000000032'")" \
  = 10000000-0000-4000-8000-000000000014 ] || die "created_by was forgeable on update"

# --- Asset location ---------------------------------------------------------
# Asset write permissions are not loosened. Members can't create assets (as in 0058).
expect_fail_because 'active work assignment required' call_as "$MEM_T" \
  "SELECT app.require_work_permission('asset', NULL::uuid, 'create');"

call_as "$CISO_T" "INSERT INTO app.assets(tenant_id,id,asset_key,name,asset_type,classification,owner_department_id,location_system_id,location_note) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000051','AST-001','顧客連絡先','customer_data','internal','10000000-0000-4000-8000-000000000031','$SYS_ID',''); SELECT app.set_management_frameworks_human('asset','10000000-0000-4000-8000-000000000051',ARRAY['RISK-MANAGEMENT']);" >/dev/null
call_as "$CISO_T" "INSERT INTO app.assets(tenant_id,id,asset_key,name,asset_type,classification,owner_department_id,location_note) VALUES(app.current_tenant(),'10000000-0000-4000-8000-000000000052','AST-002','契約書原本','legal_corporate','internal','10000000-0000-4000-8000-000000000031','本社 施錠書庫'); SELECT app.set_management_frameworks_human('asset','10000000-0000-4000-8000-000000000052',ARRAY['RISK-MANAGEMENT']);" >/dev/null

# A nonexistent system can't be the location (FK).
expect_fail_because 'violates foreign key constraint' call_as "$CISO_T" \
  "INSERT INTO app.assets(tenant_id,asset_key,name,asset_type,classification,location_system_id) VALUES(app.current_tenant(),'AST-999','幽霊','data','internal','10000000-0000-4000-8000-000000000199');"

# --- Retirement protection -------------------------------------------------------------
# A system referenced as a location is blocked from retirement by the app (the DB doesn't drop the column).
[ "$(sql -At -c "SELECT count(*) FROM app.assets WHERE location_system_id='$SYS_ID' AND status='active'")" = 1 ] \
  || die "asset location link missing"
# It can't be retired while used as a location (backstop on the RPC side).
expect_fail_because 'still used as an asset location' call_as "$CISO_T" \
  "SELECT app.update_system('$SYS_ID'::uuid,'Google Workspace (社内)','google','retired');"

# --- Department view aggregation -------------------------------------------------------
ROWS="$(sql -At -c "
  SELECT d.name || '|' || coalesce(s.name,'-') || '|' || a.location_note || '|' || count(*)
    FROM app.assets a
    JOIN app.departments d ON d.tenant_id=a.tenant_id AND d.id=a.owner_department_id
    LEFT JOIN app.application_catalog s ON s.tenant_id=a.tenant_id AND s.id=a.location_system_id
   WHERE a.status='active'
   GROUP BY d.name, s.name, a.location_note ORDER BY 1")"
printf '%s' "$ROWS" | grep -q '営業部|Google Workspace (社内)||1' || die "system location rollup missing: $ROWS"
printf '%s' "$ROWS" | grep -q '営業部|-|本社 施錠書庫|1' || die "non-system location rollup missing: $ROWS"

# --- Tenant isolation -----------------------------------------------------------
[ "$(call_as "$OTHER_T" "SELECT count(*) FROM app.application_catalog;" | tail -1)" = 0 ] \
  || die "application catalog leaked across tenants"
[ "$(call_as "$OTHER_T" "SELECT count(*) FROM app.department_systems;" | tail -1)" = 0 ] \
  || die "department systems leaked across tenants"

# --- Rollback --------------------------------------------------------------
# Derive the number of steps to roll back from the version count (don't hard-code it).
DOWN_N="$(sql -At -c "SELECT count(*) FROM public.schema_migrations WHERE version >= '0061'")"
"$ROOT/scripts/migrate.sh" down "$DOWN_N" >/dev/null
[ "$(sql -At -c "SELECT to_regclass('app.department_systems') IS NULL")" = t ] || die "0061 down left department_systems"
[ "$(sql -At -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='app' AND table_name='assets' AND column_name LIKE 'location%'")" = 0 ] \
  || die "0061 down left the location columns"
# The assets themselves remain (only the column is dropped; the register isn't broken).
[ "$(sql -At -c "SELECT count(*) FROM app.assets")" = 2 ] || die "0061 down destroyed assets"

printf '[systems] ok\n'
