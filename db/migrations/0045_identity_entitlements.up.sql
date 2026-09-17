-- 0045 app: Google WorkspaceをIdPとするID・ライセンス管理の運用台帳
--
-- 外部APIの実行資格情報はこのDBへ保存しない。ここでは、誰に何を付与するか、
-- どの固定操作を要求したか、その結果を追跡するためのテナント分離台帳だけを持つ。

CREATE TABLE app.identity_principals (
  id               uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL,
  user_id          uuid,
  provider         text NOT NULL CHECK (provider IN ('google_workspace')),
  external_id      text,
  primary_email    text NOT NULL,
  display_name     text NOT NULL DEFAULT '',
  lifecycle_state  text NOT NULL DEFAULT 'planned'
                   CHECK (lifecycle_state IN ('planned','invited','active','suspended','deprovisioned')),
  last_synced_at   timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, user_id)
    REFERENCES app.users(tenant_id, id),
  UNIQUE (tenant_id, user_id),
  UNIQUE (tenant_id, provider, primary_email),
  CHECK (primary_email = lower(primary_email)),
  CHECK (length(primary_email) BETWEEN 3 AND 254),
  CHECK (external_id IS NULL OR length(external_id) BETWEEN 1 AND 200)
);

CREATE UNIQUE INDEX identity_principals_external_id_idx
  ON app.identity_principals (tenant_id, provider, external_id)
  WHERE external_id IS NOT NULL;

CREATE TABLE app.application_catalog (
  id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  app_key            text NOT NULL,
  name               text NOT NULL,
  provider           text NOT NULL,
  provisioning_mode  text NOT NULL DEFAULT 'manual'
                     CHECK (provisioning_mode IN ('manual','api','scim','google_workspace')),
  status             text NOT NULL DEFAULT 'planned'
                     CHECK (status IN ('planned','active','paused','retired')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, app_key),
  CHECK (app_key ~ '^[a-z0-9][a-z0-9_.-]{0,99}$'),
  CHECK (provider ~ '^[a-z0-9][a-z0-9_.-]{0,99}$')
);

CREATE TABLE app.license_catalog (
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL,
  application_id  uuid NOT NULL,
  sku_key         text NOT NULL,
  name            text NOT NULL,
  seat_limit      integer CHECK (seat_limit IS NULL OR seat_limit >= 0),
  status          text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','paused','retired')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, application_id, sku_key),
  UNIQUE (tenant_id, id, application_id),
  FOREIGN KEY (tenant_id, application_id)
    REFERENCES app.application_catalog(tenant_id, id),
  CHECK (sku_key ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}$')
);

CREATE TABLE app.entitlement_assignments (
  id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  principal_id       uuid NOT NULL,
  license_id         uuid NOT NULL,
  provider_object_id text,
  state              text NOT NULL DEFAULT 'planned'
                     CHECK (state IN ('planned','requested','assigned','revoked','failed')),
  assigned_at        timestamptz,
  revoked_at         timestamptz,
  last_synced_at     timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, principal_id, license_id),
  FOREIGN KEY (tenant_id, principal_id)
    REFERENCES app.identity_principals(tenant_id, id),
  FOREIGN KEY (tenant_id, license_id)
    REFERENCES app.license_catalog(tenant_id, id),
  CHECK (provider_object_id IS NULL OR length(provider_object_id) BETWEEN 1 AND 300),
  CHECK (state <> 'assigned' OR assigned_at IS NOT NULL),
  CHECK (state <> 'revoked' OR revoked_at IS NOT NULL)
);

CREATE TABLE app.provisioning_requests (
  id                  uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL,
  request_id          uuid NOT NULL,
  idempotency_key     text NOT NULL,
  action              text NOT NULL
                      CHECK (action IN (
                        'identity.create','identity.suspend','identity.restore',
                        'license.assign','license.revoke',
                        'group.add','group.remove','session.revoke'
                      )),
  provider            text NOT NULL CHECK (provider IN ('google_workspace')),
  principal_id        uuid NOT NULL,
  application_id      uuid,
  license_id          uuid,
  target_group_id     text,
  reason              text NOT NULL,
  requested_by_email  text NOT NULL,
  status              text NOT NULL DEFAULT 'draft'
                      CHECK (status IN ('draft','approved','dispatched','succeeded','failed','cancelled')),
  provider_request_id text,
  result_hash         text,
  error_code          text,
  requested_at        timestamptz NOT NULL DEFAULT now(),
  approved_at         timestamptz,
  dispatched_at       timestamptz,
  finished_at         timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, request_id),
  UNIQUE (tenant_id, idempotency_key),
  FOREIGN KEY (tenant_id, principal_id)
    REFERENCES app.identity_principals(tenant_id, id),
  FOREIGN KEY (tenant_id, application_id)
    REFERENCES app.application_catalog(tenant_id, id),
  FOREIGN KEY (tenant_id, license_id, application_id)
    REFERENCES app.license_catalog(tenant_id, id, application_id),
  CHECK (length(idempotency_key) BETWEEN 16 AND 200),
  CHECK (length(reason) BETWEEN 1 AND 500),
  CHECK (requested_by_email = lower(requested_by_email)),
  CHECK (length(requested_by_email) BETWEEN 3 AND 254),
  CHECK (target_group_id IS NULL OR length(target_group_id) BETWEEN 1 AND 300),
  CHECK (provider_request_id IS NULL OR length(provider_request_id) BETWEEN 1 AND 300),
  CHECK (result_hash IS NULL OR result_hash ~ '^[0-9a-f]{64}$'),
  CHECK (error_code IS NULL OR error_code ~ '^[A-Z0-9_.-]{1,100}$'),
  CHECK ((action IN ('license.assign','license.revoke')) = (license_id IS NOT NULL)),
  CHECK (license_id IS NULL OR application_id IS NOT NULL),
  CHECK ((action IN ('group.add','group.remove')) = (target_group_id IS NOT NULL)),
  CHECK (status = 'draft' OR approved_at IS NOT NULL),
  CHECK (status NOT IN ('dispatched','succeeded','failed') OR dispatched_at IS NOT NULL),
  CHECK (status NOT IN ('succeeded','failed','cancelled') OR finished_at IS NOT NULL),
  CHECK (status <> 'draft' OR (approved_at IS NULL AND dispatched_at IS NULL AND finished_at IS NULL)),
  CHECK (status <> 'approved' OR (dispatched_at IS NULL AND finished_at IS NULL)),
  CHECK (status <> 'dispatched' OR finished_at IS NULL),
  CHECK (approved_at IS NULL OR approved_at >= requested_at),
  CHECK (dispatched_at IS NULL OR (approved_at IS NOT NULL AND dispatched_at >= approved_at)),
  CHECK (finished_at IS NULL OR finished_at >= coalesce(dispatched_at, approved_at, requested_at))
);

CREATE INDEX identity_principals_state_idx
  ON app.identity_principals (tenant_id, lifecycle_state, primary_email);
CREATE INDEX entitlement_assignments_state_idx
  ON app.entitlement_assignments (tenant_id, state, principal_id);
CREATE INDEX provisioning_requests_status_idx
  ON app.provisioning_requests (tenant_id, status, requested_at DESC);

COMMENT ON TABLE app.provisioning_requests IS
  '外部IdP・SaaS操作の追記型台帳。秘密値と任意URL/任意コマンドは保存せず、実行は別の型付きprovider workerが担当する';

DO $$
DECLARE
  t text;
  tables constant text[] := ARRAY[
    'identity_principals','application_catalog','license_catalog',
    'entitlement_assignments','provisioning_requests'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw
                    USING (tenant_id = app.current_tenant())
                    WITH CHECK (tenant_id = app.current_tenant())', t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro
                    USING (tenant_id = app.current_tenant())', t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON app.%I TO app_rw', t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro', t);
  END LOOP;
END $$;

-- provider由来の状態を通常DMLで偽装させない。受付・承認・catalog管理・実行結果は、
-- actorをセッションから導出する専用RPCとprovider worker roleを追加してからだけ書き込む。
-- それまでは管理画面からは全5表を読み取り専用にする。
REVOKE INSERT, UPDATE, DELETE ON
  app.identity_principals,
  app.application_catalog,
  app.license_catalog,
  app.entitlement_assignments,
  app.provisioning_requests
FROM app_rw;
