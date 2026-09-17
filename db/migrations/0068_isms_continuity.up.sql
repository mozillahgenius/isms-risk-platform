-- @run-as: admin
-- 0068: 事業継続の計画と試験（A.5.29 / A.5.30）の受け皿（設計書 2026-09-11 §4 の 3 本目）。
--
-- A.5.29 は中断・障害のときの情報セキュリティの維持を、A.5.30 は ICT の継続の備えと、その計画・試験を求める統制。
-- 附属書 A の統制なので、適用するかは適用宣言書で決まる。段階の画面では件数を出すだけで必須にしない
-- （2026-09-12 goto-twin 決定）。
--
-- 計画（continuity_plans）と試験（continuity_tests）を分ける。計画を作ったことと、試して動いたことは別。
-- 試験は監査と同じく、実施日が今日までのものだけを「実施済み」として数える（§4.4「計画を実施と数えない」）。
-- 計画の本文そのものは置かない。どこにあるか（所在）を必須にする（証跡と同じ考え方）。
-- 承認は付けない（規格の本文が求めていない）。版の表も作らない。消さずに取り下げる。中身のデータは入れない。
-- 書式・RLS・down の方針は 0065〜0067 と同じ。記録の画面だけが書く表なので、0067 の役割ポリシーも張る。

SET ROLE schema_owner;

CREATE TABLE app.continuity_plans (
  id                  uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL,
  title               text NOT NULL,
  -- 何を守る計画か（業務・システム）。空の計画を作らせない。
  scope               text NOT NULL,
  -- 目標復旧時間（時間）・目標復旧時点（時間）。決めていなければ空。
  rto_hours           integer CHECK (rto_hours > 0),
  rpo_hours           integer CHECK (rpo_hours >= 0),
  -- 計画の本文がどこにあるか（保管場所・URL）。必須。
  procedure_location  text NOT NULL,
  owner_user_id       uuid,
  -- 次に試験する期限。
  next_test_due       date,
  status              text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, title),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id),
  CHECK (title ~ '[^[:space:]]'),
  CHECK (scope ~ '[^[:space:]]'),
  CHECK (procedure_location ~ '[^[:space:]]')
);

-- 試験の記録。いつ・どう試し・結果どうだったか・誰がやったかは必須。
CREATE TABLE app.continuity_tests (
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL,
  plan_id         uuid NOT NULL,
  tested_on       date NOT NULL,
  method          text NOT NULL CHECK (method IN ('tabletop','walkthrough','simulation','full_interruption')),
  result          text NOT NULL CHECK (result IN ('passed','partially_passed','failed')),
  -- 目標復旧時間を守れたか。測っていなければ空。
  rto_met         boolean,
  findings_note   text NOT NULL DEFAULT '',
  performed_by    uuid NOT NULL,
  evidence_id     uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, plan_id)      REFERENCES app.continuity_plans(tenant_id, id),
  FOREIGN KEY (tenant_id, performed_by) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, evidence_id)  REFERENCES app.evidences(tenant_id, id)
);
CREATE INDEX continuity_tests_plan ON app.continuity_tests (tenant_id, plan_id, tested_on DESC);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['continuity_plans','continuity_tests'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO app_rw',t);
    -- 0067 と同じ役割ポリシー（名前・形・対象表は check_rls.sql が固定する）。
    EXECUTE format('CREATE POLICY records_role_insert ON app.%I AS RESTRICTIVE FOR INSERT TO app_rw '
                   'WITH CHECK ((SELECT app.records_role_allows(%L)))', t, 'continuity');
    EXECUTE format('CREATE POLICY records_role_update ON app.%I AS RESTRICTIVE FOR UPDATE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L))) WITH CHECK ((SELECT app.records_role_allows(%L)))',
                   t, 'continuity', 'continuity');
    EXECUTE format('CREATE POLICY records_role_delete ON app.%I AS RESTRICTIVE FOR DELETE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L)))', t, 'continuity');
  END LOOP;
END $$;

COMMENT ON TABLE app.continuity_plans IS
  '事業継続の計画（A.5.29 / A.5.30）。scope（何を守るか）と procedure_location（計画の所在）は必須。';
COMMENT ON TABLE app.continuity_tests IS
  '事業継続の試験。tested_on が今日までのものだけを実施済みとして数える。実施者（performed_by）と結果は必須。';

-- 許可の表に continuity を足す: owner / admin / manager（業務の運用の記録）。監査人には書かせない。
-- 0067 の版に種類を 1 つ足しただけ（down で 0067 の版へ戻す）。
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
