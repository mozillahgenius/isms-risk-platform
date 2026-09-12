-- 0042 down: remove organization initial settings and certification body information
DROP TABLE IF EXISTS app.certification_bodies;
ALTER TABLE app.tenants DROP COLUMN IF EXISTS iso_scope_statement;
