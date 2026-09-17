-- @run-as: admin
-- 0069: 技術的脆弱性の管理（A.8.8）の受け皿（設計書 2026-09-11 §4 の 4 本目）。
--
-- A.8.8 は、技術的脆弱性の情報を得て、さらされ具合を評価し、適切な処置をとることを求める統制。
-- 附属書 A の統制なので、適用するかは適用宣言書で決まる。段階の画面では件数を出すだけで必須にしない
-- （2026-09-12 goto-twin 決定）。
--
-- 状態は 検知（open）→ 対応中（in_progress）→ 対処済み（mitigated）、または 誤検知（false_positive）。
-- 「直さずに受け入れる」状態は置かない。新しい承認の流れを作らない決定（2026-09-12 goto-twin）で、
-- 既存の例外（指摘に付く）にも乗らないため。受け入れるなら、リスクとしてリスク台帳で扱う。
-- 閉じた（対処済み・誤検知）と言うなら閉じた日が要り、誤検知なら理由が要る。
-- 同じ識別子（CVE 等）・同じ資産の、開いている記録は 1 つだけ（閉じた後の再発は新しい記録として入る）。
-- 資産への結び付けは任意（設計書が名指しした関係）。承認は付けない。中身のデータは入れない。
-- 書式・RLS・down の方針は 0065〜0068 と同じ。記録の画面だけが書く表なので、0067 の役割ポリシーも張る。

SET ROLE schema_owner;

CREATE TABLE app.vulnerabilities (
  id               uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL,
  title            text NOT NULL,
  -- CVE 番号・ベンダーの勧告番号など。無ければ空。
  identifier       text NOT NULL DEFAULT '',
  source           text NOT NULL CHECK (source IN ('scan','advisory','report','pentest','other')),
  asset_id         uuid,
  severity         text NOT NULL CHECK (severity IN ('critical','high','medium','low')),
  detected_on      date NOT NULL,
  due_date         date,
  status           text NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open','in_progress','mitigated','false_positive')),
  resolved_on      date,
  resolution_note  text NOT NULL DEFAULT '',
  owner_user_id    uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, asset_id)      REFERENCES app.assets(tenant_id, id),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id),
  CHECK (title ~ '[^[:space:]]'),
  CONSTRAINT vulnerabilities_due_after_detected CHECK (due_date IS NULL OR due_date >= detected_on),
  -- 閉じた（対処済み・誤検知）ときだけ閉じた日が入る。開いているのに閉じた日がある、閉じたのに無い、を拒否する。
  CONSTRAINT vulnerabilities_resolved_iff_closed CHECK (
    (status IN ('mitigated','false_positive')) = (resolved_on IS NOT NULL)
  ),
  CONSTRAINT vulnerabilities_resolved_after_detected CHECK (resolved_on IS NULL OR resolved_on >= detected_on),
  -- 誤検知と言うなら、なぜ脆弱性でないかを書く。
  CONSTRAINT vulnerabilities_false_positive_reason CHECK (
    status <> 'false_positive' OR resolution_note ~ '[^[:space:]]'
  )
);
-- 開いている（検知・対応中）記録は、同じ識別子・同じ資産で 1 つだけ。
-- 資産あり・資産なしで索引を分ける。資産なしを固定の UUID に置き換えると、その UUID の資産と取り違える
-- （Codex レビュー 2026-09-12）。NULLS NOT DISTINCT は PostgreSQL 15 以降なので使わない。
CREATE UNIQUE INDEX vulnerabilities_open_identifier ON app.vulnerabilities (tenant_id, identifier)
  WHERE identifier <> '' AND asset_id IS NULL AND status IN ('open','in_progress');
CREATE UNIQUE INDEX vulnerabilities_open_identifier_asset ON app.vulnerabilities (tenant_id, identifier, asset_id)
  WHERE identifier <> '' AND asset_id IS NOT NULL AND status IN ('open','in_progress');
CREATE INDEX vulnerabilities_open ON app.vulnerabilities (tenant_id, status, due_date);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['vulnerabilities'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO app_rw',t);
    -- 0067 と同じ役割ポリシー（名前・形・対象表は check_rls.sql が固定する）。
    EXECUTE format('CREATE POLICY records_role_insert ON app.%I AS RESTRICTIVE FOR INSERT TO app_rw '
                   'WITH CHECK ((SELECT app.records_role_allows(%L)))', t, 'vulnerability');
    EXECUTE format('CREATE POLICY records_role_update ON app.%I AS RESTRICTIVE FOR UPDATE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L))) WITH CHECK ((SELECT app.records_role_allows(%L)))',
                   t, 'vulnerability', 'vulnerability');
    EXECUTE format('CREATE POLICY records_role_delete ON app.%I AS RESTRICTIVE FOR DELETE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L)))', t, 'vulnerability');
  END LOOP;
END $$;

COMMENT ON TABLE app.vulnerabilities IS
  '技術的脆弱性（A.8.8）。閉じた（mitigated / false_positive）ときだけ resolved_on が入る。誤検知は理由必須。開いている記録は同じ識別子・資産で 1 つだけ。';

-- 許可の表に vulnerability を足す: owner / admin / manager（業務の運用の記録）。監査人には書かせない。
-- 0068 の版に種類を 1 つ足しただけ（down で 0068 の版へ戻す）。
CREATE OR REPLACE FUNCTION app.records_role_allows(p_kind text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text;
  v_allowed text[];
BEGIN
  v_allowed := CASE p_kind
    WHEN 'audit'             THEN ARRAY['owner','admin','auditor']
    WHEN 'corrective'        THEN ARRAY['owner','admin','manager']
    WHEN 'effectiveness'     THEN ARRAY['owner','admin']
    WHEN 'management_review' THEN ARRAY['owner','admin']
    WHEN 'objective'         THEN ARRAY['owner','admin']
    WHEN 'evidence'          THEN ARRAY['owner','admin','manager']
    WHEN 'exception'         THEN ARRAY['owner']
    WHEN 'context'           THEN ARRAY['owner','admin']
    WHEN 'legal'             THEN ARRAY['owner','admin','manager']
    WHEN 'continuity'        THEN ARRAY['owner','admin','manager']
    WHEN 'vulnerability'     THEN ARRAY['owner','admin','manager']
  END;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'unknown record kind: %', p_kind;
  END IF;
  IF app.current_session_user() IS NULL THEN
    RETURN false;
  END IF;
  v_role := app.current_management_role();
  RETURN v_role IS NOT NULL AND v_role = ANY (v_allowed);
END $$;

RESET ROLE;
