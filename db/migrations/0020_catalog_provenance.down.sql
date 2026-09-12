-- Rollback of 0020
SET ROLE schema_owner;
DROP TABLE IF EXISTS catalog.seed_provenance;
RESET ROLE;
