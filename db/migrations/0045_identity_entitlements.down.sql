-- 0045 down: ID・ライセンス管理の運用台帳を取り除く。
DROP TABLE IF EXISTS app.provisioning_requests;
DROP TABLE IF EXISTS app.entitlement_assignments;
DROP TABLE IF EXISTS app.license_catalog;
DROP TABLE IF EXISTS app.application_catalog;
DROP TABLE IF EXISTS app.identity_principals;
