-- @run-as: admin
-- Preserve both the fixed service principal and the initiating user for fixed internal actions.
ALTER TABLE app.internal_management_audit_events
  ADD COLUMN requester_actor_id uuid;

-- Existing receipts predate separate requester capture; retain their known actor as provenance.
UPDATE app.internal_management_audit_events
  SET requester_actor_id = actor_id
  WHERE requester_actor_id IS NULL;

ALTER TABLE app.internal_management_audit_events
  ADD CONSTRAINT internal_management_audit_events_requester_actor_fk
  FOREIGN KEY (tenant_id, requester_actor_id) REFERENCES app.users(tenant_id,id);

ALTER TABLE app.internal_management_audit_events
  ALTER COLUMN requester_actor_id SET NOT NULL;
