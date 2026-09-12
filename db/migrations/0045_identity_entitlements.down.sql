-- 0045 down: remove the operational register for ID and license management.
DROP TABLE IF EXISTS app.provisioning_requests;
DROP TABLE IF EXISTS app.entitlement_assignments;
DROP TABLE IF EXISTS app.license_catalog;
DROP TABLE IF EXISTS app.application_catalog;
DROP TABLE IF EXISTS app.identity_principals;
