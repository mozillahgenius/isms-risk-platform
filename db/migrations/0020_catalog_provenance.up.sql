-- 0020 Catalog provenance.
--
-- Why it is needed:
--   When the UI shows "where this rule came from", embedding a fixed string would be a lie.
--   In fact catalog.controls / catalog.risk_scenario_templates had no provenance columns, and
--   the DB could not even prove that the loaded controls and risk templates belong to DOM 2026.1.
--   The loader (seed) records at load time "which file of which commit of which repository,
--   with which hash, and how many rows it read". The UI looks only here.
--
-- Where the sources of truth live (measured as of 2026-08-13):
--   - DOM 2026.1 definition        ... this repository, db/seeds/0001_dom_2026_1.sql
--   - controls / risk templates    ... CSVs in LEGAL_SCRIPTS_DIR (default: the bundled fictional samples in db/seeds/snapshots)
--   Git is the source of truth for both; the DB is a projection. Which file was loaded is recorded in this table.

SET ROLE schema_owner;

CREATE TABLE catalog.seed_provenance (
  -- Logical name of the load target. Only the latest row per target is kept (history is not kept here, nor in audit).
  target          text PRIMARY KEY
                  CHECK (target IN ('dom', 'controls', 'risk_scenario_templates')),
  -- Location of the source of truth. source_repo is owner/name, not a URL (for consistent display).
  source_repo     text NOT NULL CHECK (source_repo <> ''),
  -- Commit of the source. NULL if it could not be obtained (never an empty string pretending to "exist").
  source_commit   text CHECK (source_commit IS NULL OR source_commit ~ '^[0-9a-f]{7,40}$'),
  -- Path relative to the repository root. Never an absolute path (it differs per machine).
  source_path     text NOT NULL CHECK (source_path <> '' AND source_path !~ '^/'),
  -- SHA-256 of the loaded file.
  source_sha256   text NOT NULL CHECK (source_sha256 ~ '^[0-9a-f]{64}$'),
  -- Which DOM version it was loaded as.
  dom_version_id  uuid NOT NULL REFERENCES catalog.dom_versions(id),
  -- Rows read at load time. Compared with the counts on screen; a mismatch shows the load is stale.
  row_count       integer NOT NULL CHECK (row_count >= 0),
  -- What loaded it (file name). In a form a human can trace.
  loader          text NOT NULL CHECK (loader <> ''),
  loaded_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE catalog.seed_provenance IS
  'カタログ各対象の正本（Git）の所在と投入時の実測。画面の出所表示はここだけを読む。';

-- catalog is read-only (design doc 2.1). Same policy as 0015: SELECT only to app_rw / app_ro.
GRANT SELECT ON catalog.seed_provenance TO app_rw, app_ro;

RESET ROLE;
