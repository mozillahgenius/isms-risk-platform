-- @run-as: admin
-- Durable, tenant-scoped idempotency receipts for fixed Codzilla management actions.
CREATE TABLE app.internal_management_operations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
  operation_id text NOT NULL CHECK (operation_id ~ '^[a-f0-9]{12,64}$'),
  action text NOT NULL CHECK (action IN ('tag_iso','accept_risk')),
  request_sha256 text NOT NULL CHECK (request_sha256 ~ '^[a-f0-9]{64}$'),
  receipt jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, operation_id)
);
CREATE TABLE app.internal_management_audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
  operation_id text NOT NULL, action text NOT NULL CHECK (action IN ('tag_iso','accept_risk')),
  actor_id uuid NOT NULL, risk_scenario_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, operation_id),
  FOREIGN KEY (tenant_id, actor_id) REFERENCES app.users(tenant_id,id),
  FOREIGN KEY (tenant_id, risk_scenario_id) REFERENCES app.risk_scenarios(tenant_id,id)
);
ALTER TABLE app.internal_management_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.internal_management_operations FORCE ROW LEVEL SECURITY;
ALTER TABLE app.internal_management_audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.internal_management_audit_events FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.internal_management_operations FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant());
CREATE POLICY tenant_read ON app.internal_management_operations FOR SELECT TO app_ro USING (tenant_id=app.current_tenant());
CREATE POLICY tenant_isolation ON app.internal_management_audit_events FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant());
CREATE POLICY tenant_read ON app.internal_management_audit_events FOR SELECT TO app_ro USING (tenant_id=app.current_tenant());
REVOKE ALL ON app.internal_management_operations, app.internal_management_audit_events FROM PUBLIC;
GRANT SELECT,INSERT,UPDATE,DELETE ON app.internal_management_operations, app.internal_management_audit_events TO app_rw;
GRANT SELECT ON app.internal_management_operations, app.internal_management_audit_events TO app_ro;
