-- @run-as: admin
-- 0071: 初期データの取り込み（設計書 2026-09-11 §8）の記録。資産とリスクの CSV 取り込みから始める（2026-09-12 goto-twin 決定）。
--
-- 取り込みそのものは Web のサーバーアクションが、既存の保存と同じ経路（app_rw・require_work_permission・
-- set_management_frameworks_for_work）で 1 トランザクションに書く（全件か、何もしないか）。この migration はその記録の受け皿:
--   import_batches      取り込み 1 回分（種類・ファイルのハッシュ・行数・作った件数・誰がいつ）
--   import_batch_items  その取り込みで作った行（行番号 → 作った資産・リスク）
--   import_undos        取り込みの取り消し（1 回の取り込みに 1 回だけ。退役した件数・対象外にした件数）
-- ファイルそのものは保存しない（ハッシュ・件数・行の結果だけ。テナント境界の外へ出さず、実行もしない）。
-- どれも追記だけで、app_rw に UPDATE / DELETE を渡さない。誰がいつ、はトリガが本人と今で埋める（なりすまさせない）。
-- 取り消しは行を消さず、退役（status = 'retired'）で補償する。取り込み後に直された行・他の記録が参照している行は戻さない。
-- 書けるのは owner / admin（台帳を一括で作るので、組織の状況の決定と同じ段）。0067 の役割ポリシーも張る。

SET ROLE schema_owner;

CREATE TABLE app.import_batches (
  id             uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('assets','risks')),
  file_sha256    bytea NOT NULL CHECK (octet_length(file_sha256) = 32),
  row_count      integer NOT NULL CHECK (row_count >= 0),
  created_count  integer NOT NULL CHECK (created_count >= 0 AND created_count <= row_count),
  imported_by    uuid NOT NULL,
  imported_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, imported_by) REFERENCES app.users(tenant_id, id)
);
CREATE INDEX import_batches_recent ON app.import_batches (tenant_id, imported_at DESC);

CREATE TABLE app.import_batch_items (
  tenant_id    uuid NOT NULL,
  batch_id     uuid NOT NULL,
  row_no       integer NOT NULL CHECK (row_no >= 1),
  target_type  text NOT NULL CHECK (target_type IN ('asset','risk')),
  target_id    uuid NOT NULL,
  PRIMARY KEY (tenant_id, batch_id, row_no),
  -- 1 つの行は 1 回の取り込みでしか作られない（取り消しの対象を一意にする）。
  UNIQUE (tenant_id, target_type, target_id),
  FOREIGN KEY (tenant_id, batch_id) REFERENCES app.import_batches(tenant_id, id)
);

CREATE TABLE app.import_undos (
  tenant_id      uuid NOT NULL,
  batch_id       uuid NOT NULL,
  undone_by      uuid NOT NULL,
  undone_at      timestamptz NOT NULL DEFAULT now(),
  retired_count  integer NOT NULL CHECK (retired_count >= 0),
  skipped_count  integer NOT NULL CHECK (skipped_count >= 0),
  PRIMARY KEY (tenant_id, batch_id),
  FOREIGN KEY (tenant_id, batch_id)  REFERENCES app.import_batches(tenant_id, id),
  FOREIGN KEY (tenant_id, undone_by) REFERENCES app.users(tenant_id, id)
);

-- 誰がいつ、は本人と今で埋める（画面や直接の書き込みで他人の名義・過去の日時にさせない）。
CREATE FUNCTION app.import_log_stamp() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF TG_TABLE_NAME = 'import_batches' THEN
    NEW.imported_by := app.current_session_user();
    NEW.imported_at := now();
  ELSIF TG_TABLE_NAME = 'import_undos' THEN
    NEW.undone_by := app.current_session_user();
    NEW.undone_at := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER import_batches_stamp BEFORE INSERT ON app.import_batches
  FOR EACH ROW EXECUTE FUNCTION app.import_log_stamp();
CREATE TRIGGER import_undos_stamp BEFORE INSERT ON app.import_undos
  FOR EACH ROW EXECUTE FUNCTION app.import_log_stamp();

-- 明細は、同じトランザクションで本人が作った取り込みと、同じトランザクションで作った行にだけ付けられる。
-- 古い取り込みに他の行を足してから取り消し、その行を退役させる迂回を防ぐ（now() はトランザクションの中で同じ値）。
CREATE FUNCTION app.import_items_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  v_ok boolean;
BEGIN
  SELECT (b.imported_at = now() AND b.imported_by = app.current_session_user()) INTO v_ok
    FROM app.import_batches b WHERE b.tenant_id = NEW.tenant_id AND b.id = NEW.batch_id;
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'import items can only be added to a batch created in this transaction'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NEW.target_type = 'asset' THEN
    SELECT (a.created_at = now()) INTO v_ok FROM app.assets a WHERE a.tenant_id = NEW.tenant_id AND a.id = NEW.target_id;
  ELSE
    SELECT (r.created_at = now()) INTO v_ok FROM app.risk_scenarios r WHERE r.tenant_id = NEW.tenant_id AND r.id = NEW.target_id;
  END IF;
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'import items must point to rows created in this transaction'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER import_batch_items_guard BEFORE INSERT ON app.import_batch_items
  FOR EACH ROW EXECUTE FUNCTION app.import_items_guard();

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['import_batches','import_batch_items','import_undos'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    -- 追記だけ。直したり消したりさせない（取り込みの記録は監査の記録）。
    EXECUTE format('GRANT SELECT,INSERT ON app.%I TO app_rw',t);
    -- 0067 と同じ役割ポリシー（名前・形・対象表は check_rls.sql が固定する。UPDATE / DELETE は権限が無いが形をそろえる）。
    EXECUTE format('CREATE POLICY records_role_insert ON app.%I AS RESTRICTIVE FOR INSERT TO app_rw '
                   'WITH CHECK ((SELECT app.records_role_allows(%L)))', t, 'import');
    EXECUTE format('CREATE POLICY records_role_update ON app.%I AS RESTRICTIVE FOR UPDATE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L))) WITH CHECK ((SELECT app.records_role_allows(%L)))',
                   t, 'import', 'import');
    EXECUTE format('CREATE POLICY records_role_delete ON app.%I AS RESTRICTIVE FOR DELETE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L)))', t, 'import');
  END LOOP;
END $$;

COMMENT ON TABLE app.import_batches IS
  '初期データの取り込み 1 回分（§8）。ファイル本体は保存せず、ハッシュと件数だけ。追記だけ。imported_by / imported_at はトリガが本人と今で埋める。';
COMMENT ON TABLE app.import_batch_items IS
  '取り込みで作った行。同じトランザクションで作った取り込み・行にだけ付けられる（取り消しの対象を偽らせない）。';
COMMENT ON TABLE app.import_undos IS
  '取り込みの取り消し（退役による補償）。1 回の取り込みに 1 回だけ。取り込み後に直された行・参照されている行は対象外として数える。';

-- 許可の表に import を足す: owner / admin（台帳の一括作成）。0070 の版に種類を 1 つ足しただけ（down で 0070 の版へ戻す）。
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
    WHEN 'change'            THEN ARRAY['owner','admin','manager','member']
    WHEN 'import'            THEN ARRAY['owner','admin']
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
