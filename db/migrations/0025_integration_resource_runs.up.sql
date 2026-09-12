-- 0025: keep per-resource sync results as first-class evidence.
-- The aggregates in integration_runs alone cannot reproduce which resource was
-- unreadable / gone, so keep one row per resource using the same vocabulary.

SET ROLE schema_owner;

CREATE TABLE app.integration_resource_runs (
  id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  integration_run_id uuid NOT NULL,
  resource_name      text NOT NULL,
  external_id        text,
  collection_state   text NOT NULL
                     CHECK (collection_state IN ('collected','unreadable','gone','not_collected')),
  http_status        int,
  record_count       int NOT NULL DEFAULT 0 CHECK (record_count >= 0),
  error_detail       text,
  observed_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, integration_run_id)
    REFERENCES app.integration_runs(tenant_id, id)
);

CREATE INDEX integration_resource_runs_recent
  ON app.integration_resource_runs (tenant_id, integration_run_id, resource_name);

ALTER TABLE app.integration_resource_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.integration_resource_runs FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.integration_resource_runs FOR ALL TO app_rw
  USING (tenant_id = app.current_tenant())
  WITH CHECK (tenant_id = app.current_tenant());
CREATE POLICY tenant_read ON app.integration_resource_runs FOR SELECT TO app_ro
  USING (tenant_id = app.current_tenant());

REVOKE ALL ON app.integration_resource_runs FROM PUBLIC;
GRANT SELECT, INSERT ON app.integration_resource_runs TO app_rw;
GRANT SELECT ON app.integration_resource_runs TO app_ro;

COMMENT ON TABLE app.integration_resource_runs IS
  '同期一回の resource ごとの collected / unreadable / gone / not_collected の証跡';

RESET ROLE;
