-- 0005 app: テナント・人・ロール（設計書 2.3）
-- tenants → users → departments → memberships → sessions
-- 掲載順は設計書と異なる。departments を memberships より先に作る（依存順）。

CREATE TABLE app.tenants (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  domain        text NOT NULL,                    -- プライマリドメイン
  fiscal_start_month smallint NOT NULL DEFAULT 4
                  CHECK (fiscal_start_month BETWEEN 1 AND 12),
  industry_preset text NOT NULL DEFAULT 'general',
  dom_version_id  uuid NOT NULL REFERENCES catalog.dom_versions(id),
  status        text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','suspended','closed')),
  created_at    timestamptz NOT NULL DEFAULT now()
);
-- app.tenants は自分自身が tenant_id を持たない（id がそれ）。0015 の RLS 一括適用は
-- tenant_id 列を持つ表だけを対象にするため、ここで明示的に張る。
ALTER TABLE app.tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.tenants FOR ALL TO app_rw
  USING (id = app.current_tenant()) WITH CHECK (id = app.current_tenant());
CREATE POLICY tenant_read ON app.tenants FOR SELECT TO app_ro
  USING (id = app.current_tenant());

CREATE TABLE app.users (
  id           uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES app.tenants(id),
  email        citext NOT NULL,
  display_name text NOT NULL,
  status       text NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','suspended','left')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, email)
);

CREATE TABLE app.departments (
  id        uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  name      text NOT NULL,
  parent_id uuid,
  owner_user_id uuid,                              -- リスクオーナー
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, parent_id)     REFERENCES app.departments(tenant_id, id),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id)
);

CREATE TABLE app.memberships (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL,
  user_id     uuid NOT NULL,
  role_key    text NOT NULL REFERENCES catalog.roles_default(key),
  department_id uuid,
  granted_by  uuid, granted_at timestamptz NOT NULL DEFAULT now(),
  revoked_at  timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, user_id)       REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, department_id) REFERENCES app.departments(tenant_id, id),
  UNIQUE (tenant_id, user_id, role_key)
);

-- 監査人の兼任禁止（設計書 1.3 / 受入 #14）
CREATE OR REPLACE FUNCTION app.check_auditor_exclusivity() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM app.memberships m
    WHERE m.tenant_id = NEW.tenant_id AND m.user_id = NEW.user_id
      AND m.revoked_at IS NULL AND m.id <> NEW.id
      AND (m.role_key = 'auditor') <> (NEW.role_key = 'auditor')
  ) THEN
    RAISE EXCEPTION 'auditor role cannot be combined with other roles';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_auditor_exclusivity BEFORE INSERT OR UPDATE ON app.memberships
  FOR EACH ROW WHEN (NEW.revoked_at IS NULL)
  EXECUTE FUNCTION app.check_auditor_exclusivity();

-- ------------------------------------------------------------------
-- app.sessions
--
-- 設計書は id(uuid) のみだが、それでは「他人のセッション UUID を知っていれば
-- 他テナントへ切り替えられる」。set_tenant_context の引数を呼出者が保持する
-- 秘密に紐付けるため、ベアラトークンのハッシュを持つ（設計書からの逸脱。
-- 理由は docs/DECISIONS.md D-02）。生トークンは DB に保存しない。
--
-- この表は「定義者専用」。app_rw / app_ro には一切のテーブル権限を与えない
-- （0015 の一括 GRANT から除外する）。読み書きは 0006 の SECURITY DEFINER
-- 関数経由のみ。所有者 schema_owner も FORCE RLS の対象なので、定義者が
-- 読めるように専用ポリシーを張る（張らないと set_tenant_context が
-- 自分の引数を検証できず鶏と卵になる）。
-- ------------------------------------------------------------------
CREATE TABLE app.sessions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL,
  user_id    uuid NOT NULL,
  token_hash bytea NOT NULL UNIQUE
               CHECK (octet_length(token_hash) = 32),   -- sha256
  issued_at  timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  FOREIGN KEY (tenant_id, user_id) REFERENCES app.users(tenant_id, id),
  CHECK (expires_at > issued_at)
);
CREATE INDEX sessions_active ON app.sessions (tenant_id, user_id)
  WHERE revoked_at IS NULL;

ALTER TABLE app.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.sessions FORCE ROW LEVEL SECURITY;
-- 定義者（schema_owner）だけが全テナントのセッションを引ける。
-- app_rw / app_ro 向けのポリシーは作らない（テーブル権限自体を与えないため）。
CREATE POLICY ctx_session_lookup ON app.sessions FOR ALL TO schema_owner
  USING (true) WITH CHECK (true);

-- memberships / users / tenants も同じ理由で、文脈確立前に定義者が引けるようにする。
-- 0006 の set_tenant_context と create_session は、セッションの持ち主と
-- テナントが有効かを確かめるためにこの 3 表を読む。FORCE RLS は所有者にも
-- 効くので、ポリシーを張らないと定義者が「何も見えない」状態になり、
-- 正しいトークンでも「有効な所属が無い」と判定されてしまう（実測で踏んだ）。
CREATE POLICY ctx_membership_lookup ON app.memberships FOR SELECT TO schema_owner
  USING (true);
CREATE POLICY ctx_user_lookup ON app.users FOR SELECT TO schema_owner
  USING (true);
CREATE POLICY ctx_tenant_lookup ON app.tenants FOR SELECT TO schema_owner
  USING (true);
