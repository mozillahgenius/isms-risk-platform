-- 0007 の巻き戻し（依存の逆順）
DROP FUNCTION IF EXISTS app.rebuild_effective_grants(uuid);
DROP TABLE IF EXISTS app.effective_grants;
DROP TABLE IF EXISTS app.graph_events;
DROP TABLE IF EXISTS app.device_snapshots;
DROP TABLE IF EXISTS app.devices;
DROP TABLE IF EXISTS app.app_grants;
DROP TABLE IF EXISTS app.grants;
DROP TABLE IF EXISTS app.resources;
DROP TABLE IF EXISTS app.oauth_apps;
DROP TABLE IF EXISTS app.memberships_graph;
DROP TABLE IF EXISTS app.groups;
DROP TABLE IF EXISTS app.accounts;
DROP TABLE IF EXISTS app.identity_aliases;
DROP TABLE IF EXISTS app.identities;
