-- 0024 Add connector normalization targets that were **missing** from the design doc.
--
-- How they were found:
--   When the rule "every resource's map_to must have a landing target" was added to manifest
--   validation (scripts/validate_manifests.py), the google_workspace manifest v3 in design doc 3.2
--   turned out to have two mappings with no landing target.
--
--   1. groups `email: email` ... app.groups in design doc 2.6 has no email column.
--      Drive permissions refer to groups by `emailAddress`, so
--      **without email, permissions granted to a group cannot be resolved to the group row**.
--      "Detect exposure reachable only via a group" (Phase 2 acceptance #3) cannot hold.
--
--   2. admin_reports_login `map_to: raw_events` ... no table named `raw_events` is
--      defined anywhere in the design doc. Login audit had no landing target.
--
--   Both were in the state "written in the manifest, but nowhere to put it".
--   This kind of hole goes unnoticed until validation is added, so create the targets and maintain them via validation.
--
-- This **only prepares tables and columns**; the writer implementation (sync engine) is Phase 2B.
-- The UI honestly shows emptiness as "not loaded".

SET ROLE schema_owner;

-- 1. Group email addresses --------------------------------------------------
-- The primary key stays external_id (emails can change). email is a hint for resolution.
ALTER TABLE app.groups ADD COLUMN email citext;

-- One group per email within the same tenant and connector.
-- NULLs may be duplicated (multiple groups may not have been fetched yet).
CREATE UNIQUE INDEX groups_email_unique
  ON app.groups (tenant_id, connector, email) WHERE email IS NOT NULL;

COMMENT ON COLUMN app.groups.email IS
  'グループのメール。Drive の permission が emailAddress でグループを指すため解決に要る。一次キーは external_id。';

-- 2. Raw events (login audit, etc.) ----------------------------------------
-- Time-series records that do not fall into nodes/edges of the normalized graph. **Append-only**.
CREATE TABLE app.raw_events (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  connector     text NOT NULL,
  resource_name text NOT NULL,              -- resources[].name in the manifest
  external_id   text NOT NULL,              -- provider's event ID (idempotency key)
  occurred_at   timestamptz NOT NULL,
  event_type    text NOT NULL,
  actor_email   citext,                     -- before identity matching. Resolving to account is the normalizer's job
  -- isolate provider-specific content here (do not add columns and branch per SaaS)
  attributes    jsonb NOT NULL DEFAULT '{}',
  collection_state text NOT NULL DEFAULT 'collected'
                  CHECK (collection_state IN ('collected','unreadable','gone','not_collected')),
  collected_at  timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  -- running the same run twice does not add rows (idempotency, design doc 3.5)
  UNIQUE (tenant_id, connector, external_id)
);
CREATE INDEX raw_events_recent
  ON app.raw_events (tenant_id, connector, occurred_at DESC);

-- RLS and privileges. Apply the same generation rules as 0015 to this table in the same way.
-- **Append-only**, so UPDATE / DELETE are not granted (same treatment as device_snapshots / graph_events).
ALTER TABLE app.raw_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.raw_events FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON app.raw_events;
DROP POLICY IF EXISTS tenant_read      ON app.raw_events;
CREATE POLICY tenant_isolation ON app.raw_events FOR ALL TO app_rw
  USING (tenant_id = app.current_tenant())
  WITH CHECK (tenant_id = app.current_tenant());
CREATE POLICY tenant_read ON app.raw_events FOR SELECT TO app_ro
  USING (tenant_id = app.current_tenant());
REVOKE ALL ON app.raw_events FROM PUBLIC;
GRANT SELECT, INSERT ON app.raw_events TO app_rw;
GRANT SELECT ON app.raw_events TO app_ro;

COMMENT ON TABLE app.raw_events IS
  'ノード・エッジに落ちない時系列の記録（ログイン監査等）。追記のみ。書き込みは Phase 2B の同期エンジン。';

-- 3. Add "connector manifest" as a provenance subject -----------------------------
-- Manifests also have Git as the source of truth, with the DB as a projection. As with controls and risk templates,
-- record, by measurement, which commit of which repository and which file they came from.
ALTER TABLE catalog.seed_provenance DROP CONSTRAINT seed_provenance_target_check;
ALTER TABLE catalog.seed_provenance
  ADD CONSTRAINT seed_provenance_target_check
  CHECK (target IN ('dom', 'controls', 'risk_scenario_templates', 'connector_manifests'));

RESET ROLE;
