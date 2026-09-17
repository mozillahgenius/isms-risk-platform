-- @run-as: admin
-- 0065: 組織の課題（4.1）と利害関係者（4.2）の受け皿（設計書 2026-09-11 §4 の 1 本目）。
--
-- 4.1 は ISMS の意図した成果に影響する外部・内部の課題を「決定する」こと、
-- 4.2 は利害関係者とその要求、そのうち ISMS で扱うものを「決定する」ことを求める。
-- どちらも文書化情報を無条件には求めないので、段階の画面では件数を出すだけで必須にしない
-- （2026-09-12 goto-twin 決定。必須は 9.1 のように文書化情報を求める箇条だけ）。
--
-- 書式は 0055 に揃える（テナント FK・(tenant_id, id) の主キー・必須欄は空白だけを CHECK で拒否・
-- created_by に FK を付けない・down はデータがあれば拒否）。RLS は 0063 と同じ 2 枚だけ
-- （書き込みは Web のサーバーアクションが app_rw で行うので、定義者向けのポリシーは要らない）。
-- 承認は付けない（規格の本文が求めていない）。版の表も作らない。中身のデータは入れない。

SET ROLE schema_owner;

-- 組織の課題（4.1）。ISMS にどう効くか（isms_impact）が書けない課題は、4.1 の課題ではないので空を許さない。
CREATE TABLE app.context_issues (
  id             uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('internal','external')),
  title          text NOT NULL,
  description    text NOT NULL DEFAULT '',
  isms_impact    text NOT NULL,
  owner_user_id  uuid,
  -- 最後に見直した日。見直していなければ空。
  reviewed_on    date,
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, kind, title),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id),
  CHECK (title ~ '[^[:space:]]'),
  CHECK (isms_impact ~ '[^[:space:]]')
);

-- 利害関係者（4.2）。requirements は情報セキュリティに関する要求（4.2 b）で必須。
-- addressed_in_isms はそのうち ISMS で扱うもの（4.2 c）。空は「まだ決めていない」。
CREATE TABLE app.interested_parties (
  id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  name               text NOT NULL,
  category           text NOT NULL
                     CHECK (category IN ('customer','regulator','employee','shareholder','supplier','partner','other')),
  requirements       text NOT NULL,
  addressed_in_isms  text NOT NULL DEFAULT '',
  owner_user_id      uuid,
  reviewed_on        date,
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, name),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id),
  CHECK (name ~ '[^[:space:]]'),
  CHECK (requirements ~ '[^[:space:]]')
);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['context_issues','interested_parties'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO app_rw',t);
  END LOOP;
END $$;

COMMENT ON TABLE app.context_issues IS
  '組織の課題（4.1）。kind は internal / external。isms_impact（ISMS にどう効くか）は必須。有効なもの（status=active）を数える。';
COMMENT ON TABLE app.interested_parties IS
  '利害関係者（4.2）。requirements（情報セキュリティに関する要求）は必須。addressed_in_isms はそのうち ISMS で扱うもの。';

-- 書いてよい役割に context（組織の課題・利害関係者）を足す: owner / admin（情報セキュリティ目的と同じ段）。
-- 監査人には書かせない。0064 の版に種類を 1 つ足しただけ（down で 0064 の版へ戻す）。
CREATE OR REPLACE FUNCTION app.require_records_role(p_kind text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text := app.current_management_role();
  v_allowed text[];
BEGIN
  IF app.current_session_user() IS NULL THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  v_allowed := CASE p_kind
    WHEN 'audit'             THEN ARRAY['owner','admin','auditor']
    WHEN 'corrective'        THEN ARRAY['owner','admin','manager']
    WHEN 'effectiveness'     THEN ARRAY['owner','admin']
    WHEN 'management_review' THEN ARRAY['owner','admin']
    WHEN 'objective'         THEN ARRAY['owner','admin']
    WHEN 'evidence'          THEN ARRAY['owner','admin','manager']
    WHEN 'exception'         THEN ARRAY['owner']
    WHEN 'context'           THEN ARRAY['owner','admin']
  END;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'unknown record kind: %', p_kind;
  END IF;
  IF v_role IS NULL OR NOT (v_role = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'records role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_role;
END $$;

RESET ROLE;
