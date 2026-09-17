-- 0005 の巻き戻し
DROP TABLE IF EXISTS app.sessions;
DROP TRIGGER IF EXISTS trg_auditor_exclusivity ON app.memberships;
DROP TABLE IF EXISTS app.memberships;
DROP FUNCTION IF EXISTS app.check_auditor_exclusivity();
DROP TABLE IF EXISTS app.departments;
DROP TABLE IF EXISTS app.users;
DROP TABLE IF EXISTS app.tenants;
