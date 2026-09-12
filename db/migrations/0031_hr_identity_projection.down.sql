SET ROLE schema_owner;

DROP FUNCTION IF EXISTS app.project_hr_identity(uuid,text,text,text,uuid);
DROP POLICY IF EXISTS hr_projection_device_update ON app.devices;
DROP POLICY IF EXISTS hr_projection_account_update ON app.accounts;
DROP POLICY IF EXISTS hr_projection_account_read ON app.accounts;
DROP POLICY IF EXISTS hr_projection_identity_update ON app.identities;
DROP POLICY IF EXISTS hr_projection_identity_insert ON app.identities;
DROP POLICY IF EXISTS hr_projection_identity_read ON app.identities;
DROP FUNCTION IF EXISTS app.hr_projection_target();

RESET ROLE;
