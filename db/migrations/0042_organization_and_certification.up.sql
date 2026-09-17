-- 0042 app: 組織の初期設定・審査機関情報(画面⑨ステップ1・2の実体)
--
-- 実スキーマ確認(既存コード再利用の原則): app.tenants に name は既にあるが、
-- ISMS適用範囲(スコープ声明)に相当する列が無い。審査機関情報も既存テーブルに
-- 無い。組織名はapp.tenants.nameを流用し、新規に必要なのは適用範囲の1列と、
-- 審査機関情報のテーブルのみ。
--
-- app.tenants は他のappテーブルと違い tenant_id 列を持たない(id自身がそれ)ため、
-- 0015のRLS一括適用の対象外だが、0005で既にRLSが個別に張られている
-- (列追加だけなのでRLSの再設定は不要)。

ALTER TABLE app.tenants
  ADD COLUMN iso_scope_statement text NOT NULL DEFAULT '';
COMMENT ON COLUMN app.tenants.iso_scope_statement IS 'ISMS適用範囲の声明。画面⑨ウィザードのステップ1「初期設定」に対応';

CREATE TABLE app.certification_bodies (
  id                   uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES app.tenants(id),
  body_name            text NOT NULL,
  certification_standard text NOT NULL DEFAULT 'ISO/IEC 27001:2022',
  certificate_number   text NOT NULL DEFAULT '',
  initial_certified_on date,
  last_audit_on        date,
  next_audit_on        date,
  contact_info         text NOT NULL DEFAULT '',
  source_note          text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  -- 日付の前後関係。片方以上が未入力なら比較しようがないので許容する
  -- (organization/actions.tsのServer Action側の検証と同じ規則をDB側にも
  -- 置き、直接SQL経路でも逆順を防ぐ。Codexレビュー2026-09-03 8回目指摘)。
  CHECK (initial_certified_on IS NULL OR last_audit_on IS NULL
         OR initial_certified_on <= last_audit_on),
  CHECK (last_audit_on IS NULL OR next_audit_on IS NULL
         OR last_audit_on <= next_audit_on),
  CHECK (initial_certified_on IS NULL OR next_audit_on IS NULL
         OR initial_certified_on <= next_audit_on)
);

COMMENT ON TABLE app.certification_bodies IS '審査機関情報。画面⑨ウィザードのステップ2「適用範囲・審査機関」に対応';

DO $$
BEGIN
  ALTER TABLE app.certification_bodies ENABLE ROW LEVEL SECURITY;
  ALTER TABLE app.certification_bodies FORCE ROW LEVEL SECURITY;
  CREATE POLICY tenant_isolation ON app.certification_bodies FOR ALL TO app_rw
    USING (tenant_id = app.current_tenant())
    WITH CHECK (tenant_id = app.current_tenant());
  CREATE POLICY tenant_read ON app.certification_bodies FOR SELECT TO app_ro
    USING (tenant_id = app.current_tenant());
  REVOKE ALL ON app.certification_bodies FROM PUBLIC;
  GRANT SELECT, INSERT, UPDATE, DELETE ON app.certification_bodies TO app_rw;
  GRANT SELECT ON app.certification_bodies TO app_ro;
END $$;
