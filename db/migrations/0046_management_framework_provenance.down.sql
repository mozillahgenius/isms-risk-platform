-- @run-as: admin
-- Remove only the generation still owned by this migration. Human re-tags and legacy rows survive.
--
-- The provenance row and its migration origin are a pair.  Do not guess which
-- side is authoritative when they disagree: a partial rollback could otherwise
-- remove a relation whose ownership was changed outside this migration.  Released
-- rows are deliberately excluded because their migration origin has been
-- replaced by a human/service origin.
DO $$
DECLARE
  provenance_count bigint;
  origin_count bigint;
  provenance_hash text;
  origin_hash text;
BEGIN
  SELECT count(*), coalesce(encode(digest(string_agg(
    format('%s|%s|%s|%s|%s', tenant_id, entity_type, entity_id, framework_key, generation_id),
    E'\n' ORDER BY tenant_id, entity_type, entity_id, framework_key, generation_id), 'sha256'), 'hex'),
    encode(digest('', 'sha256'), 'hex'))
  INTO provenance_count, provenance_hash
  FROM app.framework_backfill_provenance
  WHERE migration_key='0046_management_framework_provenance'
    AND relation_created_by_migration
    AND ownership_released_at IS NULL;

  SELECT count(*), coalesce(encode(digest(string_agg(
    format('%s|%s|%s|%s|%s', p.tenant_id, p.entity_type, p.entity_id, p.framework_key, p.generation_id),
    E'\n' ORDER BY p.tenant_id, p.entity_type, p.entity_id, p.framework_key, p.generation_id), 'sha256'), 'hex'),
    encode(digest('', 'sha256'), 'hex'))
  INTO origin_count, origin_hash
  FROM app.framework_backfill_provenance p
  JOIN app.framework_relation_origins o
    ON o.tenant_id=p.tenant_id AND o.entity_type=p.entity_type AND o.entity_id=p.entity_id
   AND o.framework_key=p.framework_key AND o.generation_id=p.generation_id
  WHERE p.migration_key='0046_management_framework_provenance'
    AND p.relation_created_by_migration
    AND p.ownership_released_at IS NULL
    AND o.origin_kind='migration'
    AND o.origin_id='0046_management_framework_provenance';

  IF provenance_count <> origin_count OR provenance_hash <> origin_hash THEN
    RAISE EXCEPTION '0046 provenance preflight count/hash mismatch';
  END IF;
END $$;

WITH owned AS (
  SELECT p.* FROM app.framework_backfill_provenance p JOIN app.framework_relation_origins o
    ON o.tenant_id=p.tenant_id AND o.entity_type=p.entity_type AND o.entity_id=p.entity_id AND o.framework_key=p.framework_key AND o.generation_id=p.generation_id
  WHERE p.migration_key='0046_management_framework_provenance' AND p.relation_created_by_migration
    AND p.ownership_released_at IS NULL AND o.origin_kind='migration' AND o.origin_id='0046_management_framework_provenance'
), deleted_assets AS (
 DELETE FROM app.asset_frameworks af USING owned o WHERE o.entity_type='asset' AND af.tenant_id=o.tenant_id AND af.asset_id=o.entity_id AND af.framework_key=o.framework_key RETURNING af.tenant_id,af.asset_id
), deleted_risks AS (
 DELETE FROM app.risk_scenario_frameworks rf USING owned o WHERE o.entity_type='risk_scenario' AND rf.tenant_id=o.tenant_id AND rf.risk_scenario_id=o.entity_id AND rf.framework_key=o.framework_key RETURNING rf.tenant_id,rf.risk_scenario_id
)
DELETE FROM app.framework_relation_origins o USING owned x WHERE o.tenant_id=x.tenant_id AND o.entity_type=x.entity_type AND o.entity_id=x.entity_id AND o.framework_key=x.framework_key AND o.generation_id=x.generation_id;
DROP FUNCTION app.accept_risk(uuid,integer,smallint,smallint,text);
DROP FUNCTION app.request_iso_framework_removal(text,uuid,uuid,bytea,bytea,text,text,timestamptz);
DROP FUNCTION app.set_management_frameworks(text,uuid,text[]);
DROP FUNCTION app.approve_iso_framework_removal(uuid);
DROP FUNCTION app.execute_iso_framework_removal(uuid);
DROP TABLE app.iso_framework_removal_requests;
DROP TABLE app.risk_acceptances;
DROP TABLE app.framework_backfill_provenance;
DROP TABLE app.framework_relation_events;
DROP TABLE app.framework_relation_origins;
