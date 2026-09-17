-- 0012 app: 連携（設計書 2.11）
CREATE TABLE app.integrations (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL,
  connector   text NOT NULL, manifest_version int NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('reader','elevated_reader','writer')),
  status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','paused','error','revoked')),
  secret_ref  text NOT NULL,                    -- 暗号化された資格情報の参照（値は持たない）
  approved_by uuid, approved_at timestamptz,    -- elevated_reader / writer では必須
  cursors     jsonb NOT NULL DEFAULT '{}',      -- スコープ別の差分カーソル
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, connector),
  FOREIGN KEY (connector, manifest_version)
    REFERENCES catalog.connector_manifests(connector, version),
  CHECK (kind = 'reader' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);

CREATE TABLE app.integration_runs (
  id uuid NOT NULL DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
  integration_id uuid NOT NULL, resource_name text NOT NULL,
  mode text NOT NULL CHECK (mode IN ('full','incremental')),
  started_at timestamptz NOT NULL, finished_at timestamptz,
  fetched int, collected int, unreadable int, gone int, not_collected int,
  coverage_ratio numeric(4,3),
  status text NOT NULL CHECK (status IN ('success','partial','failed')),
  error_detail text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, integration_id) REFERENCES app.integrations(tenant_id, id)
);
CREATE INDEX integration_runs_recent
  ON app.integration_runs (tenant_id, integration_id, started_at DESC);
