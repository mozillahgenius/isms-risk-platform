#!/usr/bin/env bash
set -euo pipefail

DB="${ISMS_DB:-isms_dev}"
TOKEN="${ISMS_WEB_TENANT_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f web/.env.local ]; then
  TOKEN="$(sed -n 's/^ISMS_WEB_TENANT_TOKEN=//p' web/.env.local)"
fi
[ -n "$TOKEN" ] || { echo "risk_register_test: token がありません" >&2; exit 1; }

privileges="$(PGHOST="${PGHOST:-127.0.0.1}" PGUSER="${PGUSER:-$(id -un)}" psql -At -d "$DB" -c "SELECT has_table_privilege('app_rw','app.risk_evaluation_snapshots','UPDATE')::text || '|' || has_table_privilege('app_rw','app.risk_evaluation_snapshots','DELETE')::text || '|' || has_table_privilege('app_rw','app.assets','INSERT')::text")"
[ "$privileges" = "false|false|true" ] || { echo "risk_register_test: 履歴の更新削除禁止または資産登録権限が不正: $privileges" >&2; exit 1; }

PGHOST="${PGHOST:-127.0.0.1}" PGUSER="${PGUSER:-app_rw}" psql -q -v ON_ERROR_STOP=1 -v tenant_token="$TOKEN" -d "$DB" -f - <<'SQL'
BEGIN;
SELECT app.set_tenant_context(:'tenant_token');
WITH created AS (
  INSERT INTO app.assets (tenant_id,asset_key,name,asset_type,classification)
  VALUES (app.current_tenant(),'M1-create-tag-' || txid_current()::text,
          'M1 create and tag','system','internal')
  RETURNING id
)
SELECT app.set_management_frameworks_human('asset',id,ARRAY['RISK-MANAGEMENT']) FROM created;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
SQL

set +e
PGHOST="${PGHOST:-127.0.0.1}" PGUSER="${PGUSER:-app_rw}" psql -q -v ON_ERROR_STOP=1 -v tenant_token="$TOKEN" -d "$DB" -f - <<'SQL'
BEGIN;
SELECT app.set_tenant_context(:'tenant_token');
INSERT INTO app.risk_scenarios
  (tenant_id,id,risk_key,domain,area,phase,theme,measure,frame,summary,status)
VALUES
  (app.current_tenant(),'aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa',
   'M1-RISK-SNAPSHOT','M1','M1',1,'M1','M1','管理可能性','M1 snapshot check','active');
SELECT app.set_management_frameworks_human(
  'risk_scenario','aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa',
  ARRAY['RISK-MANAGEMENT']);
INSERT INTO app.risk_evaluation_snapshots (tenant_id, risk_scenario_id, stage, assessed_on, probability, impact, rationale)
VALUES (app.current_tenant(),'aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa',
        'after_measure',CURRENT_DATE,1,1,'reverse test');
SQL
status=$?
set -e
[ "$status" -ne 0 ] || { echo "risk_register_test: 施策後評価の施策なし登録が通った" >&2; exit 1; }

echo "risk_register_test: OK（作成+必須tag原子経路・施策後の施策必須・履歴の更新削除禁止）"
