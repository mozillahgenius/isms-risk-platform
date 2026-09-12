-- 0007 app: normalized posture graph (design doc 2.6 / 4.2)
--
-- The order differs from the design doc in one place: the doc lists grants → oauth_apps,
-- but grants has an FK to oauth_apps, so oauth_apps is created first.
-- It is not a mutual reference (oauth_apps does not reference grants), so no later ALTER is needed.
--
-- RLS and policies are not set up here. Design doc 4.2 lists a hand-written policy only for
-- effective_grants, but that would duplicate the generation rule used for the other tables.
-- app tables with tenant_id are generated in bulk in 0015, and CI checks coverage and content.

CREATE TABLE app.identities (
  id           uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL,
  subject_type text NOT NULL CHECK (subject_type IN
                 ('employee','contractor','service_account','ai_agent',
                  'external_guest','unclassified')),
  display_name text,
  primary_email citext,
  user_id      uuid,                               -- when linked to app.users
  hr_employee_id text,                             -- immutable ID on the HR side
  owner_identity_id uuid,                          -- accountable owner of a service_account / ai_agent
  status       text NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','suspended','left')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  -- Service accounts and AI agents require an accountable owner (design doc 1.3 / 4.3)
  CHECK (subject_type NOT IN ('service_account','ai_agent') OR owner_identity_id IS NOT NULL)
);
ALTER TABLE app.identities
  ADD CONSTRAINT identities_owner_fk
  FOREIGN KEY (tenant_id, owner_identity_id) REFERENCES app.identities(tenant_id, id);

CREATE TABLE app.identity_aliases (
  tenant_id   uuid NOT NULL,
  identity_id uuid NOT NULL,
  alias_email citext NOT NULL,
  PRIMARY KEY (tenant_id, alias_email),
  FOREIGN KEY (tenant_id, identity_id) REFERENCES app.identities(tenant_id, id)
);

CREATE TABLE app.accounts (
  id           uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL,
  connector    text NOT NULL,                      -- 'google_workspace'
  external_id  text NOT NULL,                      -- the immutable ID is the primary key (not the email)
  identity_id  uuid,                               -- identity resolution result (NULL if unresolved)
  email        citext,
  is_admin     boolean,
  mfa_enrolled boolean,
  suspended    boolean,
  last_login_at timestamptz,
  attributes   jsonb NOT NULL DEFAULT '{}',        -- SaaS-specific data is isolated here
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, connector, external_id),
  FOREIGN KEY (tenant_id, identity_id) REFERENCES app.identities(tenant_id, id)
);

CREATE TABLE app.groups (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL,
  connector   text NOT NULL,
  external_id text NOT NULL,
  name        text,
  parent_group_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, connector, external_id),
  FOREIGN KEY (tenant_id, parent_group_id) REFERENCES app.groups(tenant_id, id)
);

CREATE TABLE app.memberships_graph (          -- account → group (distinct from app.memberships)
  tenant_id uuid NOT NULL,
  account_id uuid NOT NULL,
  group_id   uuid NOT NULL,
  PRIMARY KEY (tenant_id, account_id, group_id),
  FOREIGN KEY (tenant_id, account_id) REFERENCES app.accounts(tenant_id, id),
  FOREIGN KEY (tenant_id, group_id)   REFERENCES app.groups(tenant_id, id)
);

CREATE TABLE app.oauth_apps (
  id           uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL,
  connector    text NOT NULL,
  external_id  text NOT NULL,
  name         text,
  publisher    text,
  scopes       text[] NOT NULL DEFAULT '{}',
  risk_scopes  text[] NOT NULL DEFAULT '{}',       -- extracted high-risk scopes
  grant_count  int NOT NULL DEFAULT 0,
  last_used_at timestamptz,
  vendor_id    uuid,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, connector, external_id)
);

CREATE TABLE app.resources (
  id           uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL,
  connector    text NOT NULL,
  external_id  text NOT NULL,
  kind         text NOT NULL,                      -- file/folder/repo/bucket/channel/drive
  name         text,
  parent_id    uuid,
  inherit_permissions boolean NOT NULL DEFAULT true,
  drive_id     text,                               -- shared drive identifier
  owner_account_id uuid,
  classification text REFERENCES catalog.asset_classes_default(key),
  classification_source text
                 CHECK (classification_source IN ('asset_register','path_rule','name_rule','dlp','manual')),
  collection_state text NOT NULL DEFAULT 'collected'
                 CHECK (collection_state IN ('collected','unreadable','gone','not_collected')),
  last_modified_at timestamptz,
  attributes   jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, connector, external_id),
  FOREIGN KEY (tenant_id, parent_id)        REFERENCES app.resources(tenant_id, id),
  FOREIGN KEY (tenant_id, owner_account_id) REFERENCES app.accounts(tenant_id, id)
);
CREATE INDEX resources_classification ON app.resources (tenant_id, classification)
  WHERE collection_state = 'collected';

CREATE TABLE app.grants (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  resource_id   uuid NOT NULL,
  subject_kind  text NOT NULL CHECK (subject_kind IN
                  ('account','group','oauth_app','external_domain','anyone','public')),
  subject_account_id uuid, subject_group_id uuid,
  subject_oauth_app_id uuid, subject_domain text,
  role          text,                              -- reader/writer/owner etc. (normalized)
  expires_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, resource_id)          REFERENCES app.resources(tenant_id, id),
  FOREIGN KEY (tenant_id, subject_account_id)   REFERENCES app.accounts(tenant_id, id),
  FOREIGN KEY (tenant_id, subject_group_id)     REFERENCES app.groups(tenant_id, id),
  FOREIGN KEY (tenant_id, subject_oauth_app_id) REFERENCES app.oauth_apps(tenant_id, id),
  CHECK (
    (subject_kind = 'account'          AND subject_account_id   IS NOT NULL) OR
    (subject_kind = 'group'            AND subject_group_id     IS NOT NULL) OR
    (subject_kind = 'oauth_app'        AND subject_oauth_app_id IS NOT NULL) OR
    (subject_kind = 'external_domain'  AND subject_domain       IS NOT NULL) OR
    (subject_kind IN ('anyone','public'))
  )
);
CREATE INDEX grants_public ON app.grants (tenant_id, subject_kind)
  WHERE subject_kind IN ('anyone','public');

CREATE TABLE app.app_grants (                 -- account → oauth_app
  tenant_id    uuid NOT NULL,
  account_id   uuid NOT NULL,
  oauth_app_id uuid NOT NULL,
  granted_at   timestamptz,
  PRIMARY KEY (tenant_id, account_id, oauth_app_id),
  FOREIGN KEY (tenant_id, account_id)   REFERENCES app.accounts(tenant_id, id),
  FOREIGN KEY (tenant_id, oauth_app_id) REFERENCES app.oauth_apps(tenant_id, id)
);

CREATE TABLE app.devices (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  source        text NOT NULL CHECK (source IN ('agent','jamf','intune')),
  external_id   text NOT NULL,                     -- serial number etc.
  hostname      text, model text, os_family text,
  assigned_identity_id uuid,
  is_offpremise boolean NOT NULL DEFAULT false,    -- loaned / taken off-premises (A.7.9)
  enrolled_at   timestamptz,
  last_seen_at  timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, source, external_id),
  FOREIGN KEY (tenant_id, assigned_identity_id) REFERENCES app.identities(tenant_id, id)
);

CREATE TABLE app.device_snapshots (           -- append-only
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL,
  device_id       uuid NOT NULL,
  collected_at    timestamptz NOT NULL,
  agent_version   text, definition_version text, definition_hash bytea,
  disk_encrypted  boolean,
  screen_lock_enabled boolean, screen_lock_delay_sec int,
  os_version      text, patch_current boolean, auto_update_enabled boolean,
  firewall_enabled boolean, edr_running boolean,
  admin_account_count int, password_manager_installed boolean,
  unapproved_apps text[],
  raw_hash        bytea NOT NULL,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES app.devices(tenant_id, id)
);
CREATE INDEX device_snapshots_recent
  ON app.device_snapshots (tenant_id, device_id, collected_at DESC);

-- Change events (time series for the whole graph; append-only)
CREATE TABLE app.graph_events (
  id          bigint GENERATED ALWAYS AS IDENTITY,
  tenant_id   uuid NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  node_kind   text NOT NULL,                       -- account/resource/grant/oauth_app/device
  node_id     uuid NOT NULL,
  change      text NOT NULL CHECK (change IN ('created','updated','removed')),
  before      jsonb, after jsonb,
  PRIMARY KEY (id)
);
CREATE INDEX graph_events_tenant_time ON app.graph_events (tenant_id, occurred_at DESC);

-- ------------------------------------------------------------------
-- Effective permissions (design doc 4.2).
-- A real table with RLS rather than a MATERIALIZED VIEW (the design doc v2.0 self-review found
-- that "with an MV, RLS does not apply, leaving a cross-tenant hole").
-- ------------------------------------------------------------------
CREATE TABLE app.effective_grants (
  tenant_id    uuid NOT NULL,
  resource_id  uuid NOT NULL,
  subject_kind text NOT NULL,
  subject_account_id uuid, subject_group_id uuid,
  subject_oauth_app_id uuid, subject_domain text,
  role         text,
  path         text NOT NULL,          -- the path by which it was reached
  computed_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX effective_grants_resource ON app.effective_grants (tenant_id, resource_id);
CREATE INDEX effective_grants_subject  ON app.effective_grants (tenant_id, subject_kind);

-- Replace only that tenant's rows each time a sync completes
CREATE OR REPLACE FUNCTION app.rebuild_effective_grants(p_tenant uuid) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  DELETE FROM app.effective_grants WHERE tenant_id = p_tenant;
  INSERT INTO app.effective_grants
    (tenant_id, resource_id, subject_kind, subject_account_id, subject_group_id,
     subject_oauth_app_id, subject_domain, role, path)
WITH RECURSIVE
  member AS (   -- expand nested groups
    SELECT account_id, group_id, 1 AS depth
      FROM app.memberships_graph WHERE tenant_id = p_tenant
    UNION         -- UNION (not ALL). Duplicate rows collapse, so it terminates even with cycles
    SELECT m.account_id, g.parent_group_id, m.depth + 1
      FROM member m
      JOIN app.groups g ON g.tenant_id = p_tenant AND g.id = m.group_id
     WHERE g.parent_group_id IS NOT NULL AND m.depth < 16
  ),
  inherited AS ( -- inheritance from parent resources
    SELECT id AS resource_id, id AS via, 1 AS depth
      FROM app.resources WHERE tenant_id = p_tenant
    UNION
    SELECT i.resource_id, r.parent_id AS via, i.depth + 1
      FROM inherited i
      JOIN app.resources r ON r.tenant_id = p_tenant AND r.id = i.via
     WHERE r.parent_id IS NOT NULL AND r.inherit_permissions AND i.depth < 32
  )
-- direct permissions + inheritance from parents
SELECT p_tenant, i.resource_id, g.subject_kind,
       g.subject_account_id, g.subject_group_id, g.subject_oauth_app_id, g.subject_domain,
       g.role,
       CASE WHEN i.via = i.resource_id THEN 'direct'
            ELSE 'inherited:' || i.via::text END
  FROM inherited i
  JOIN app.grants g ON g.tenant_id = p_tenant AND g.resource_id = i.via
UNION ALL
-- expand group permissions to individual accounts
SELECT p_tenant, i.resource_id, 'account', m.account_id, NULL, NULL, NULL, g.role,
       'via_group:' || g.subject_group_id::text
  FROM inherited i
  JOIN app.grants g ON g.tenant_id = p_tenant AND g.resource_id = i.via
                   AND g.subject_kind = 'group'
  JOIN member m ON m.group_id = g.subject_group_id;
END $$;
ALTER FUNCTION app.rebuild_effective_grants(uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.rebuild_effective_grants(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rebuild_effective_grants(uuid) TO app_rw;
