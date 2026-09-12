-- @run-as: admin
ALTER TABLE app.internal_management_audit_events
  DROP CONSTRAINT IF EXISTS internal_management_audit_events_requester_actor_fk;
ALTER TABLE app.internal_management_audit_events
  DROP COLUMN IF EXISTS requester_actor_id;
