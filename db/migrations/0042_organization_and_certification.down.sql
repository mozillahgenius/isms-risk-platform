-- 0042 down: 組織初期設定・審査機関情報を取り除く
DROP TABLE IF EXISTS app.certification_bodies;
ALTER TABLE app.tenants DROP COLUMN IF EXISTS iso_scope_statement;
