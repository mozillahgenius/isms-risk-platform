-- Rollback of 0023
SET ROLE schema_owner;
ALTER TABLE catalog.controls DROP CONSTRAINT IF EXISTS controls_theme_canonical;
DROP FUNCTION IF EXISTS catalog.canonical_theme(text);
DROP FUNCTION IF EXISTS catalog.theme_space_chars();
RESET ROLE;
