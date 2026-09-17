-- 0061: 利用システムの台帳化 / 部門ごとの利用実態 / 情報資産の所在場所
--
-- 背景（実測）:
--   - 情報資産に「所在場所」に相当する列は無かった。db/migrations 全体を
--     location / 所在 / 保管 で走査してもヒットしない（0020 のコメントと
--     0040 の外部ファイル参照は別物）。
--   - 一方 app.assets.owner_department_id は 0027 で列も FK も既にあるのに、
--     画面からもクエリからも一度も使われていない（grep で 0 件）。
--   - app.application_catalog（0045）は SELECT されるだけで、INSERT/UPDATE の
--     経路が無い。ID・ライセンス連携の親として置かれたまま空だった。
--
-- 方針: **「システムらしきもの」を 4 つ目にしない。**
--   既に app.application_catalog（ID連携の親）、app.vendors（委託先＝取引相手）、
--   app.assets.asset_type（自由記述）の 3 つがある。ここに新しいシステム表を
--   建てると、同じ SaaS が 4 箇所に別名で載り、どれが正本か誰も言えなくなる。
--   application_catalog を「利用システム」の正本に昇格させ、書き込み経路を付ける。
--   vendors とは名寄せしない（利用システムと取引相手は別の軸）。
--
--   したがって新設するのは app.department_systems 1 本だけ。
--   「情報資産としてはまだ登録していないが、部門が使っているシステム」と
--   「どう使っているか」の記述先が、資産経由では表せないため。

SET ROLE schema_owner;

-- ------------------------------------------------------------------
-- (1) 利用システムは各メンバーが書ける
--
--   資産台帳（app.assets）の書き込み権限は 0058 の require_work_permission の
--   ままにする。**緩めるのは利用システムの一覧だけ。** 現場でないと分からない
--   のは「どのシステムを何に使っているか」であって、情報資産の分類や
--   ISO 枠組みの割当ではない。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.require_system_edit_permission() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE v_role text := app.current_management_role();
BEGIN
  -- 監査人は業務データを変更しない（0005 の兼任禁止と同じ立て付け）。
  -- 所属の無い利用者（none）も書けない。
  IF v_role IN ('none','auditor') THEN
    RAISE EXCEPTION 'system edit permission required' USING ERRCODE='insufficient_privilege';
  END IF;
END
$$;
ALTER FUNCTION app.require_system_edit_permission() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.require_system_edit_permission() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.require_system_edit_permission() TO app_rw;

-- **0045 は app_rw から application_catalog の INSERT/UPDATE/DELETE を明示的に
-- 剥奪している**（「provider由来の状態を通常DMLで偽装させない。…専用RPCと
-- provider worker role を追加してからだけ書き込む」）。その統制は外さない。
-- 0045 が予告したとおり **専用 RPC を足して**、そこだけが書けるようにする。
-- プロビジョニング（identity_principals / entitlement_assignments /
-- provisioning_requests）は引き続き読み取り専用のまま触らない。
--
-- 0045 の CHECK 制約（app_key / provider の正規表現、provisioning_mode の enum）も
-- 変えない。適用済みのテーブルへ侵襲せず、呼び出し側が制約を満たす値を作る
-- （名称から app_key を採番し、provider は unknown を既定にする）。

-- SECURITY DEFINER は schema_owner として走る。application_catalog は
-- FORCE RLS なので所有者にもポリシーが要る。文脈が無いときに例外を投げない
-- 版で比べる（0059 と同じ理由。張る前と同じ挙動に留める）。
CREATE POLICY tenant_security_definer ON app.application_catalog FOR ALL TO schema_owner
  USING (tenant_id = app.current_tenant_or_null())
  WITH CHECK (tenant_id = app.current_tenant_or_null());

CREATE OR REPLACE FUNCTION app.create_system(
  p_app_key text, p_name text, p_provider text, p_status text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM app.require_system_edit_permission();
  INSERT INTO app.application_catalog
    (tenant_id, app_key, name, provider, status, created_by, updated_by)
  VALUES (app.current_tenant(), p_app_key, p_name, p_provider, p_status,
          app.current_session_user(), app.current_session_user())
  RETURNING id INTO v_id;
  RETURN v_id;
END
$$;
ALTER FUNCTION app.create_system(text,text,text,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.create_system(text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.create_system(text,text,text,text) TO app_rw;

-- app.assets は FORCE RLS で app_rw / app_ro 向けのポリシーしか持たない（0015）。
-- 所有者向けが無いと、SECURITY DEFINER（schema_owner）で走る下の関数からは
-- 資産が 1 行も見えず、「所在として使われているか」の検査が常に false になる
-- （0057 の assignment_target_exists で踏んだのと同じ罠。受入テストで再現した）。
-- 必要なのは読むことだけなので SELECT に限る。文脈が無いときに例外を投げない
-- 版で比べ、ポリシーを張る前と同じ挙動（0 行）に留める。
CREATE POLICY tenant_security_definer_read ON app.assets FOR SELECT TO schema_owner
  USING (tenant_id = app.current_tenant_or_null());

CREATE OR REPLACE FUNCTION app.update_system(
  p_id uuid, p_name text, p_provider text, p_status text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  PERFORM app.require_system_edit_permission();
  -- 所在場所として使われているシステムを廃止にしない。
  -- 参照を残したまま廃止すると「もう無い場所に情報がある」台帳になる。
  IF p_status = 'retired' AND EXISTS (
    SELECT 1 FROM app.assets
     WHERE tenant_id = app.current_tenant() AND status = 'active'
       AND location_system_id = p_id
  ) THEN
    RAISE EXCEPTION 'system is still used as an asset location';
  END IF;
  UPDATE app.application_catalog
     SET name = p_name, provider = p_provider, status = p_status,
         updated_at = now(), updated_by = app.current_session_user()
   WHERE tenant_id = app.current_tenant() AND id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'system % not found', p_id;
  END IF;
END
$$;
ALTER FUNCTION app.update_system(uuid,text,text,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.update_system(uuid,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.update_system(uuid,text,text,text) TO app_rw;

CREATE OR REPLACE FUNCTION app.guard_application_catalog() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  -- 文脈が無い経路（移行スクリプト・コネクタ・tests）は素通しする。
  -- has_actor_context() はテナント文脈があるのに本人が居ない状態を弾く（0059）。
  IF NOT app.has_actor_context() THEN RETURN coalesce(NEW, OLD); END IF;
  PERFORM app.require_system_edit_permission();
  IF TG_OP <> 'DELETE' THEN
    NEW.updated_at := now();
    NEW.updated_by := app.current_session_user();
    -- 申告者は呼び出し側に決めさせない。coalesce にすると、渡された値が
    -- そのまま残り、同じテナントの別人の ID を書いて監査情報を偽装できる。
    IF TG_OP = 'INSERT' THEN
      NEW.created_at := now();
      NEW.created_by := app.current_session_user();
    ELSE
      NEW.created_at := OLD.created_at;
      NEW.created_by := OLD.created_by;
    END IF;
  END IF;
  RETURN coalesce(NEW, OLD);
END
$$;
ALTER FUNCTION app.guard_application_catalog() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_application_catalog() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_application_catalog() TO app_rw;
CREATE TRIGGER trg_guard_application_catalog
  BEFORE INSERT OR UPDATE OR DELETE ON app.application_catalog
  FOR EACH ROW EXECUTE FUNCTION app.guard_application_catalog();

COMMENT ON TABLE app.application_catalog IS
  '利用システムの正本。ID・ライセンス連携の親であると同時に、各メンバーが登録する「うちが使っているシステム」の一覧。委託先の台帳（app.vendors）とは別の軸で、名寄せしない';

-- ------------------------------------------------------------------
-- (2) 部門がどのシステムをどう使っているか
--
--   「どんな情報を扱っているか」は部門側に別の台帳を持たせない。
--   情報資産（app.assets）に owner_department_id と所在場所が入れば、
--   部門×システム×情報は集計で出る。ここに自由記述の情報台帳を作ると、
--   資産台帳と二重管理になって必ず食い違う。
--   ここが持つのは「どう使っているか」だけ。
-- ------------------------------------------------------------------
CREATE TABLE app.department_systems (
  tenant_id      uuid NOT NULL,
  department_id  uuid NOT NULL,
  application_id uuid NOT NULL,
  usage_note     text NOT NULL DEFAULT '',
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid,
  PRIMARY KEY (tenant_id, department_id, application_id),
  FOREIGN KEY (tenant_id, department_id)  REFERENCES app.departments(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, application_id) REFERENCES app.application_catalog(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, created_by)     REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, updated_by)     REFERENCES app.users(tenant_id, id)
);

CREATE INDEX department_systems_application_idx
  ON app.department_systems (tenant_id, application_id);

COMMENT ON TABLE app.department_systems IS
  '部門がどのシステムをどう使っているか。扱っている情報そのものは書かない（情報資産台帳が正本）';

CREATE OR REPLACE FUNCTION app.guard_department_systems() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF NOT app.has_actor_context() THEN RETURN coalesce(NEW, OLD); END IF;
  PERFORM app.require_system_edit_permission();
  IF TG_OP <> 'DELETE' THEN
    NEW.updated_at := now();
    NEW.updated_by := app.current_session_user();
    -- 申告者は呼び出し側に決めさせない。coalesce にすると、渡された値が
    -- そのまま残り、同じテナントの別人の ID を書いて監査情報を偽装できる。
    IF TG_OP = 'INSERT' THEN
      NEW.created_at := now();
      NEW.created_by := app.current_session_user();
    ELSE
      NEW.created_at := OLD.created_at;
      NEW.created_by := OLD.created_by;
    END IF;
  END IF;
  RETURN coalesce(NEW, OLD);
END
$$;
ALTER FUNCTION app.guard_department_systems() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_department_systems() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_department_systems() TO app_rw;
CREATE TRIGGER trg_guard_department_systems
  BEFORE INSERT OR UPDATE OR DELETE ON app.department_systems
  FOR EACH ROW EXECUTE FUNCTION app.guard_department_systems();

ALTER TABLE app.department_systems ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.department_systems FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.department_systems FOR ALL TO app_rw
  USING (tenant_id = app.current_tenant())
  WITH CHECK (tenant_id = app.current_tenant());
CREATE POLICY tenant_read ON app.department_systems FOR SELECT TO app_ro
  USING (tenant_id = app.current_tenant());
CREATE POLICY tenant_security_definer ON app.department_systems FOR ALL TO schema_owner
  USING (tenant_id = app.current_tenant_or_null())
  WITH CHECK (tenant_id = app.current_tenant_or_null());
REVOKE ALL ON app.department_systems FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.department_systems TO app_rw;
GRANT SELECT ON app.department_systems TO app_ro;

-- ------------------------------------------------------------------
-- (3) 情報資産の所在場所
--
--   システムを FK で選ばせる。自由記述だけにすると、同じシステムが表記ゆれで
--   何通りにも書かれ、「このシステムにどの情報があるか」を引けなくなる。
--   ただし所在は常にシステムとは限らない（紙・金庫・端末・郵送物）ので、
--   FK で表せない所在のために location_note を併せて持つ。
-- ------------------------------------------------------------------
ALTER TABLE app.assets
  ADD COLUMN location_system_id uuid,
  ADD COLUMN location_note text NOT NULL DEFAULT '';

ALTER TABLE app.assets
  ADD CONSTRAINT assets_location_system_fk
    FOREIGN KEY (tenant_id, location_system_id)
    REFERENCES app.application_catalog(tenant_id, id);

CREATE INDEX assets_location_system_idx
  ON app.assets (tenant_id, location_system_id)
  WHERE location_system_id IS NOT NULL;

COMMENT ON COLUMN app.assets.location_system_id IS
  '所在場所のうち、利用システム（app.application_catalog）で表せるもの';
COMMENT ON COLUMN app.assets.location_note IS
  '所在場所のうち、システムでは表せないもの（紙・保管庫・端末・郵送物など）';

RESET ROLE;
