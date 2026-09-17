-- @run-as: admin
-- 0066: 法令・規制・契約上の要求事項（A.5.31）の受け皿（設計書 2026-09-11 §4 の 2 本目）。
--
-- A.5.31 は、情報セキュリティに関係する法令・規制・契約上の要求事項を特定し、文書化し、最新に保つことを求める統制。
-- 附属書 A の統制なので、適用するかどうかは適用宣言書で決まる。段階の画面では件数を出すだけで必須にしない
-- （2026-09-12 goto-twin 決定）。
--
-- 他の表との関係は、設計書が名指しした「対応する統制・証跡」だけ（どちらも任意）:
--   measure_id  → app.measures（その要求に応える統制）
--   evidence_id → app.evidences（満たしていることの証跡）
-- 適合の評価（適合・一部適合・不適合）は「評価日・評価者・結果」が揃うか、未評価かのどちらか（0055 と同じ考え方）。
-- 承認は付けない（規格の本文が求めていない）。消さずに取り下げる。中身のデータは入れない。
-- 書式・RLS・down の方針は 0065 と同じ。

SET ROLE schema_owner;

CREATE TABLE app.legal_requirements (
  id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  kind               text NOT NULL CHECK (kind IN ('law','regulation','contract','standard','other')),
  title              text NOT NULL,
  -- 何を求めているか（必須）。名前だけの一覧では、満たしているかを誰も判断できない。
  requirement        text NOT NULL,
  -- 条項・契約の条番号など、原文のどこか。
  source_ref         text NOT NULL DEFAULT '',
  owner_user_id      uuid,
  measure_id         uuid,
  evidence_id        uuid,
  compliance_status  text NOT NULL DEFAULT 'not_assessed'
                     CHECK (compliance_status IN ('not_assessed','compliant','partially_compliant','non_compliant')),
  assessed_on        date,
  assessed_by        uuid,
  next_review_on     date,
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, kind, title),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, assessed_by)   REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, measure_id)    REFERENCES app.measures(tenant_id, id),
  FOREIGN KEY (tenant_id, evidence_id)   REFERENCES app.evidences(tenant_id, id),
  CHECK (title ~ '[^[:space:]]'),
  CHECK (requirement ~ '[^[:space:]]'),
  -- 評価したと言うなら、いつ誰が評価したかが要る。未評価なら両方とも空。
  CONSTRAINT legal_requirements_assessment_complete CHECK (
    (compliance_status = 'not_assessed' AND assessed_on IS NULL AND assessed_by IS NULL)
    OR (compliance_status <> 'not_assessed' AND assessed_on IS NOT NULL AND assessed_by IS NOT NULL)
  ),
  -- 次の見直しは評価より後。
  CONSTRAINT legal_requirements_review_after_assessment CHECK (
    next_review_on IS NULL OR assessed_on IS NULL OR next_review_on > assessed_on
  )
);
CREATE INDEX legal_requirements_measure ON app.legal_requirements (tenant_id, measure_id) WHERE measure_id IS NOT NULL;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['legal_requirements'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO app_rw',t);
  END LOOP;
END $$;

COMMENT ON TABLE app.legal_requirements IS
  '法令・規制・契約上の要求事項（A.5.31）。requirement は必須。適合の評価は assessed_on / assessed_by が揃ったときだけ。統制（measure_id）・証跡（evidence_id）へ任意で結ぶ。';

-- 書いてよい役割に legal を足す: owner / admin / manager（是正処置・証跡と同じ段。業務の運用の記録）。
-- 監査人には書かせない。0065 の版に種類を 1 つ足しただけ（down で 0065 の版へ戻す）。
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
    WHEN 'legal'             THEN ARRAY['owner','admin','manager']
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
