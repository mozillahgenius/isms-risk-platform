-- @run-as: admin
-- 0059: 組織・メンバー管理 / 作業のレコード紐付け / メール送信キュー
--
-- 背景（実測）:
--   (1) navigation.ts は RISK / ISMS の両モードで /organization を出しているのに
--       web/src/app/organization/ が空で 404 だった（27c56ef で削除）。画面を戻すに
--       あたり、これまで画面が持っていなかった「メンバーを増やす・止める」を扱える
--       ようにする。app.set_tenant_context_for_proxy(0050) は「status='active' かつ
--       有効な所属が 1 件だけある人」しか通さないので、メンバー表＝実質のアクセス権
--       一覧である。誰が触ってよいかを DB 側にも置く。
--   (2) 0058 の app.work_items は作業単位だけを持ち、どのレコードについての作業かを
--       持たない。0057 の app.work_assignments はレコード単位だが人が 1 人しか持てず、
--       台帳が 2 本になる。ここでは work_items 側に対象レコードを持たせ、台帳を
--       work_items 一本に寄せる（work_assignments は 0057 のまま触らない）。
--   (3) 外部質問票の「送付」も、依頼の通知も、出口はメール 1 本。宛先ごとに別表を
--       作らず、単一の送信キュー app.mail_outbox に集約する。
--
-- 方針: DML はアプリ側（management_web = app_rw）で行い、この migration は
--   「誰がやってよいか」と「壊れた状態を作らせないか」だけを DB 側へ置く。
--   app.users / app.memberships は FORCE RLS 下で schema_owner に SELECT の
--   ポリシーしか無い（0005 の ctx_*_lookup）ため、SECURITY DEFINER 関数から
--   書き込むことはできない。0057 / 0058 と同じ形（判定は関数・書き込みはアプリ）
--   にそろえる。

SET ROLE schema_owner;

-- ------------------------------------------------------------------
-- (1) 権限判定に member_manage / department_manage / notify を足す
--     0057 の本体をそのまま持ち込み、分岐だけを追加する。判定を 2 系統に
--     しないため、新画面もここだけを見る。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.require_management_permission(
  p_resource_type text,
  p_resource_id uuid,
  p_action text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_role text := app.current_management_role();
  v_tenant uuid := app.current_tenant();
  v_user uuid := app.current_session_user();
BEGIN
  IF v_user IS NULL OR v_role IN ('none','auditor') THEN
    RAISE EXCEPTION 'management permission required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF p_action = 'role_manage' AND v_role <> 'owner' THEN
    RAISE EXCEPTION 'owner role required' USING ERRCODE='insufficient_privilege';
  END IF;
  -- メンバーの新規登録・停止・再開と部門の改廃は、オーナーと管理者まで。
  -- マネージャーは自部門の依頼はできるが、入退場は決めない。
  -- 人の出入り（member_manage）と、組織の形・適用範囲・審査機関（org_manage）は
  -- オーナーと管理者まで。マネージャーは自部門の依頼はできるが、入退場も
  -- 組織の形も決めない。管理ロールそのものの付け替えは role_manage（オーナー）。
  IF p_action IN ('member_manage','org_manage') AND v_role NOT IN ('owner','admin') THEN
    RAISE EXCEPTION 'admin role required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF p_action = 'questionnaire_send' AND v_role NOT IN ('owner','admin') THEN
    RAISE EXCEPTION 'admin role required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF p_action IN ('assign','create','questionnaire_manage','notify')
     AND v_role NOT IN ('owner','admin','manager') THEN
    RAISE EXCEPTION 'manager role required' USING ERRCODE='insufficient_privilege';
  END IF;
  IF p_action = 'write' THEN
    IF v_role IN ('owner','admin','manager') THEN RETURN; END IF;
    IF EXISTS (
      SELECT 1 FROM app.work_assignments a
       WHERE a.tenant_id=v_tenant AND a.resource_type=p_resource_type
         AND a.resource_id=p_resource_id AND a.assignee_user_id=v_user
         AND a.assignment_role IN ('owner','editor')
         AND a.status NOT IN ('declined','cancelled','completed')
    ) THEN RETURN; END IF;
    RAISE EXCEPTION 'active assignment required' USING ERRCODE='insufficient_privilege';
  END IF;
END
$$;
ALTER FUNCTION app.require_management_permission(text,uuid,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.require_management_permission(text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.require_management_permission(text,uuid,text) TO app_rw;

-- ------------------------------------------------------------------
-- (2) メンバー管理の不変条件
--
--   文脈が無い経路（app.provision_tenant は 0021 で SECURITY DEFINER のまま
--   app.tenant_id を立てずに app.users へ INSERT する。移行スクリプトと
--   tests/*.sh も同じ）は素通しする。ここで縛るのは画面から入ってくる
--   書き込みだけ。文脈が無いのに縛るとテナント作成そのものが落ちる。
-- ------------------------------------------------------------------
-- テナント文脈があるのに本人が立っていない状態は「素通し」にしない。
--
-- 素通しにすると、app_rw が set_tenant_context で文脈を作ったあと
-- set_config('app.session_user_id','') で本人だけ消し、以後この関数が false を
-- 返すことでガードを丸ごと迂回できる（Codex 指摘）。
-- 逃がしてよいのは「テナント文脈がそもそも無い」場合だけ
-- ＝ app.provision_tenant(0021)・移行スクリプト・tests/*.sh の直書き。
-- 正規の経路（app.set_tenant_context / set_tenant_context_for_proxy）は
-- 必ず tenant と session_user を同時に立てるので、片方だけの状態は作られない。
CREATE OR REPLACE FUNCTION app.has_actor_context() RETURNS boolean
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, app AS $$
BEGIN
  IF coalesce(pg_catalog.current_setting('app.tenant_id', true), '') = '' THEN
    RETURN false;
  END IF;
  IF coalesce(pg_catalog.current_setting('app.session_user_id', true), '') = '' THEN
    RAISE EXCEPTION 'session user context is required' USING ERRCODE='insufficient_privilege';
  END IF;
  RETURN true;
END
$$;
ALTER FUNCTION app.has_actor_context() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.has_actor_context() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.has_actor_context() TO app_rw, app_ro;

CREATE OR REPLACE FUNCTION app.guard_org_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF NOT app.has_actor_context() THEN RETURN NEW; END IF;
  PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'member_manage');
  RETURN NEW;
END
$$;
ALTER FUNCTION app.guard_org_user() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_org_user() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_org_user() TO app_rw;
CREATE TRIGGER trg_guard_org_user
  BEFORE INSERT OR UPDATE ON app.users
  FOR EACH ROW EXECUTE FUNCTION app.guard_org_user();

-- オーナー（ciso）が 0 人になる操作を拒む。0 人になると
-- require_management_permission の role_manage が誰にも通らなくなり、
-- 画面からは二度と権限を戻せない（実測で確かめる）。
-- オーナー数の検査はテナント単位で直列化する。
-- 2 つのトランザクションが別々のオーナーを降ろすと、互いに「相手が残っている」と
-- 見えて両方通り、結果としてオーナーが 0 人になる。助言ロックで順番を付ければ、
-- 後から来た側は先の結果を見てから数え直す（READ COMMITTED では新しい文が
-- 新しいスナップショットを取るため、コミット済みの変更が見える）。
CREATE OR REPLACE FUNCTION app.lock_owner_guard(p_tenant uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
  SELECT pg_catalog.pg_advisory_xact_lock(
           pg_catalog.hashtext('app.owner_guard'), pg_catalog.hashtext(p_tenant::text))
$$;
ALTER FUNCTION app.lock_owner_guard(uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.lock_owner_guard(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.lock_owner_guard(uuid) TO app_rw;

CREATE OR REPLACE FUNCTION app.assert_owner_remains() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE v_tenant uuid := coalesce(OLD.tenant_id, NEW.tenant_id);
BEGIN
  PERFORM app.lock_owner_guard(v_tenant);
  -- 所属が 1 件も残っていないテナントは、解体中か作成前。守る対象の組織が
  -- 無いので何も言わない（tests/rls_test.sh の後始末や app.provision_tenant の
  -- 途中経過がここに来る）。画面が通る経路は revoked_at を立てる更新であり、
  -- そちらでは他の所属が残っているのでこの逃げ道は使えない。
  IF NOT EXISTS (
    SELECT 1 FROM app.memberships m
     WHERE m.tenant_id=v_tenant AND m.revoked_at IS NULL
  ) THEN
    RETURN NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM app.memberships m JOIN app.users u
      ON u.tenant_id=m.tenant_id AND u.id=m.user_id
     WHERE m.tenant_id=v_tenant AND m.role_key='ciso'
       AND m.revoked_at IS NULL AND u.status='active'
  ) THEN
    RAISE EXCEPTION 'tenant must keep at least one active owner';
  END IF;
  RETURN NULL;
END
$$;
ALTER FUNCTION app.assert_owner_remains() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.assert_owner_remains() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.assert_owner_remains() TO app_rw;

CREATE CONSTRAINT TRIGGER trg_membership_keeps_owner
  AFTER UPDATE OR DELETE ON app.memberships
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW WHEN (OLD.role_key='ciso' AND OLD.revoked_at IS NULL)
  EXECUTE FUNCTION app.assert_owner_remains();

CREATE CONSTRAINT TRIGGER trg_user_status_keeps_owner
  AFTER UPDATE ON app.users
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW WHEN (OLD.status='active' AND NEW.status <> 'active')
  EXECUTE FUNCTION app.assert_owner_remains();

-- 所属（＝権限そのもの）の付け替えを DB 側でも縛る。
-- app_rw は 0015 で app.memberships の全 DML を持っているので、Server Action を
-- 通らない経路（別の画面のコード・SQL の取り違え）から member が自分に ciso を
-- 足せてしまう。オーナーの付け外しだけは role_manage（オーナー）、それ以外の
-- 所属の整理は member_manage（オーナー・管理者）を要求する。
CREATE OR REPLACE FUNCTION app.guard_org_membership() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF NOT app.has_actor_context() THEN RETURN coalesce(NEW, OLD); END IF;
  -- **新旧の両方を見る。** NEW だけ見ると、ciso の行を employee へ書き換える
  -- 更新が member_manage で通り、管理者がオーナーを降ろせてしまう
  -- （オーナーの付与だけでなく剥奪も role_manage の領分）。
  IF NEW.role_key = 'ciso' OR OLD.role_key = 'ciso' THEN
    PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'role_manage');
  ELSE
    PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'member_manage');
  END IF;
  RETURN coalesce(NEW, OLD);
END
$$;
ALTER FUNCTION app.guard_org_membership() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_org_membership() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_org_membership() TO app_rw;
CREATE TRIGGER trg_guard_org_membership
  BEFORE INSERT OR UPDATE OR DELETE ON app.memberships
  FOR EACH ROW EXECUTE FUNCTION app.guard_org_membership();

CREATE OR REPLACE FUNCTION app.guard_org_department() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF NOT app.has_actor_context() THEN RETURN coalesce(NEW, OLD); END IF;
  PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'org_manage');
  RETURN coalesce(NEW, OLD);
END
$$;
ALTER FUNCTION app.guard_org_department() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_org_department() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_org_department() TO app_rw;
CREATE TRIGGER trg_guard_org_department
  BEFORE INSERT OR UPDATE OR DELETE ON app.departments
  FOR EACH ROW EXECUTE FUNCTION app.guard_org_department();

-- 組織の適用範囲と審査機関情報も同じ境界に置く。画面から誰でも書けていた。
CREATE OR REPLACE FUNCTION app.guard_org_settings() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF NOT app.has_actor_context() THEN RETURN coalesce(NEW, OLD); END IF;
  PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'org_manage');
  RETURN coalesce(NEW, OLD);
END
$$;
ALTER FUNCTION app.guard_org_settings() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_org_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_org_settings() TO app_rw;
CREATE TRIGGER trg_guard_certification_body
  BEFORE INSERT OR UPDATE OR DELETE ON app.certification_bodies
  FOR EACH ROW EXECUTE FUNCTION app.guard_org_settings();

-- ------------------------------------------------------------------
-- (3) 作業を「どのレコードについてか」まで結ぶ
--     台帳は work_items 一本のまま。両方 NULL（レコードに紐づかない作業）も
--     許す（例: 全社の資産棚卸し）。
-- ------------------------------------------------------------------
ALTER TABLE app.work_items
  ADD COLUMN resource_type text,
  ADD COLUMN resource_id uuid;

ALTER TABLE app.work_items
  ADD CONSTRAINT work_items_resource_pair
    CHECK ((resource_type IS NULL) = (resource_id IS NULL));

CREATE INDEX work_items_resource_idx
  ON app.work_items (tenant_id, resource_type, resource_id)
  WHERE resource_type IS NOT NULL;

COMMENT ON COLUMN app.work_items.resource_type IS
  '対象レコードの種別（asset/risk/measure/incident/training/vendor/vendor_assessment）。作業全体への依頼なら NULL';

-- **SECURITY DEFINER にしない。** 0057 の app.assignment_target_exists は
-- SECURITY DEFINER で schema_owner として走るが、app.assets 等は FORCE ROW
-- LEVEL SECURITY で app_rw / app_ro 向けのポリシーしか持たない（0015）。
-- 所有者向けのポリシーが無いので、あの関数は常に false を返す（実測）。
-- ここは呼び出し元（app_rw）の権限のまま実在確認をする。
CREATE OR REPLACE FUNCTION app.guard_work_item_resource() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE v_exists boolean;
BEGIN
  IF NEW.resource_type IS NULL THEN RETURN NEW; END IF;
  -- 種別と作業種別が食い違う組み合わせを作らせない。食い違うと
  -- require_work_permission が別の作業種別を見て許可・拒否を誤る。
  IF app.work_type_for_resource(NEW.resource_type) IS DISTINCT FROM NEW.work_type THEN
    RAISE EXCEPTION 'resource type does not match work type';
  END IF;
  CASE NEW.resource_type
    WHEN 'asset' THEN
      SELECT EXISTS (SELECT 1 FROM app.assets
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id AND status='active') INTO v_exists;
    WHEN 'risk' THEN
      SELECT EXISTS (SELECT 1 FROM app.risk_scenarios
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id AND status='active') INTO v_exists;
    WHEN 'measure' THEN
      SELECT EXISTS (SELECT 1 FROM app.measures
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id AND status <> 'retired') INTO v_exists;
    WHEN 'incident' THEN
      SELECT EXISTS (SELECT 1 FROM app.incidents
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id) INTO v_exists;
    WHEN 'training' THEN
      SELECT EXISTS (SELECT 1 FROM app.trainings
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id) INTO v_exists;
    WHEN 'vendor' THEN
      SELECT EXISTS (SELECT 1 FROM app.vendors
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id) INTO v_exists;
    WHEN 'vendor_assessment' THEN
      SELECT EXISTS (SELECT 1 FROM app.vendor_assessments
                      WHERE tenant_id=NEW.tenant_id AND id=NEW.resource_id) INTO v_exists;
    ELSE
      v_exists := false;
  END CASE;
  IF NOT v_exists THEN
    RAISE EXCEPTION 'assignment target not found';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION app.guard_work_item_resource() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_work_item_resource() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_work_item_resource() TO app_rw;
CREATE TRIGGER trg_guard_work_item_resource
  BEFORE INSERT OR UPDATE ON app.work_items
  FOR EACH ROW EXECUTE FUNCTION app.guard_work_item_resource();

-- ------------------------------------------------------------------
-- (4) メール送信キュー
--
--   Web プロセスは SMTP 資格情報を持たない。画面は「送る」を積むだけで、
--   実際の送信は scripts/send_mail_outbox.py が別プロセスで行う。
--   ISMS の対象システム自身が社外への送信口を直接持たない形にしておく。
-- ------------------------------------------------------------------
CREATE TABLE app.mail_outbox (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  purpose       text NOT NULL CHECK (purpose IN ('external_questionnaire','work_assignment')),
  to_email      citext NOT NULL,
  to_name       text NOT NULL DEFAULT '',
  subject       text NOT NULL CHECK (length(btrim(subject)) > 0),
  body_text     text NOT NULL CHECK (length(btrim(body_text)) > 0),
  related_type  text,
  related_id    uuid,
  status        text NOT NULL DEFAULT 'queued'
                CHECK (status IN ('queued','sending','sent','failed','cancelled')),
  attempts      integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error    text NOT NULL DEFAULT '',
  queued_at     timestamptz NOT NULL DEFAULT now(),
  sent_at       timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    uuid,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES app.users(tenant_id, id),
  CHECK (to_email = lower(to_email::text)),
  CHECK (length(to_email::text) BETWEEN 3 AND 254),
  CHECK (status <> 'sent' OR sent_at IS NOT NULL),
  -- 送信ワーカーは psql の出力を読んで処理する。宛先名・件名に制御文字が
  -- 混ざると、区切りとして解釈されて行が黙って捨てられる（=送信待ちのまま
  -- 消える）。ヘッダに入る値でもあるので、そもそも持たせない。
  CHECK (to_email::text ~ '^[^[:cntrl:][:space:]]+$'),
  CHECK (to_name ~ '^[^[:cntrl:]]*$'),
  CHECK (subject ~ '^[^[:cntrl:]]*$'),
  -- 本文は改行とタブだけ許す。
  CHECK (body_text ~ '^([^[:cntrl:]]|[\n\t])*$')
);

CREATE INDEX mail_outbox_pending_idx
  ON app.mail_outbox (tenant_id, status, queued_at)
  WHERE status IN ('queued','sending');
CREATE INDEX mail_outbox_related_idx
  ON app.mail_outbox (tenant_id, related_type, related_id);

COMMENT ON TABLE app.mail_outbox IS
  '外部質問票の送付と依頼通知の送信キュー。Web は積むだけで、送信は別プロセス';

-- 積む側だけ権限を見る。送信ワーカー（app_rw ＋ テナント文脈のみ、本人性なし）は
-- status を進めるので、UPDATE ではこの判定を通さない。
CREATE OR REPLACE FUNCTION app.guard_mail_outbox() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  -- **積む側は配送の状態を指定できない。** ここで固定しないと、UPDATE を
  -- 塞いでも INSERT で status='sent', sent_at=now() と書くだけで
  -- 「送った記録」を作れてしまう（送信記録が証跡にならない）。
  -- 積まれた行は必ず queued・0 回・エラー無し・未送信から始まる。
  NEW.status := 'queued';
  NEW.attempts := 0;
  NEW.last_error := '';
  NEW.sent_at := NULL;
  NEW.queued_at := now();
  NEW.created_at := now();
  NEW.updated_at := now();
  -- 送信キューには bootstrap 経路が無い（テナント作成も移行もメールを積まない）。
  -- 誰が積んだか分からない行を作らせず、権限確認も必ず通す。
  IF NOT app.has_actor_context() THEN
    RAISE EXCEPTION 'queued mail requires an actor context' USING ERRCODE='insufficient_privilege';
  END IF;
  NEW.created_by := app.current_session_user();
  NEW.updated_by := app.current_session_user();
  IF NEW.purpose = 'external_questionnaire' THEN
    PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'questionnaire_send');
  ELSE
    PERFORM app.require_management_permission(NULL::text, NULL::uuid, 'notify');
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION app.guard_mail_outbox() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_mail_outbox() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_mail_outbox() TO app_rw;
CREATE TRIGGER trg_guard_mail_outbox
  BEFORE INSERT ON app.mail_outbox
  FOR EACH ROW EXECUTE FUNCTION app.guard_mail_outbox();

-- 積んだ後に中身を書き換えられないようにする。宛先・件名・本文・用途・
-- 関連先は不変。送信ワーカーが進めてよいのは状態と試行の記録だけ。
-- これが無いと、送っていないものを「送信済み」にでき、監査の証跡にならない。
CREATE OR REPLACE FUNCTION app.guard_mail_outbox_update() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.purpose IS DISTINCT FROM OLD.purpose
     OR NEW.to_email IS DISTINCT FROM OLD.to_email
     OR NEW.to_name IS DISTINCT FROM OLD.to_name
     OR NEW.subject IS DISTINCT FROM OLD.subject
     OR NEW.body_text IS DISTINCT FROM OLD.body_text
     OR NEW.related_type IS DISTINCT FROM OLD.related_type
     OR NEW.related_id IS DISTINCT FROM OLD.related_id
     OR NEW.queued_at IS DISTINCT FROM OLD.queued_at
     OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
    RAISE EXCEPTION 'queued mail is immutable except for its delivery state';
  END IF;
  -- 状態は決められた順にしか動かせない。とくに sent へは sending からしか
  -- 入れない。ここを開けておくと、1 通も送らずに status='sent' と
  -- sent_at=now() を書くだけで「送信済み」の記録を作れてしまい、
  -- 送信キューが証跡として成立しない。sending にできるのは、
  -- FOR UPDATE SKIP LOCKED で行を掴んだ送信ワーカーだけ。
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (
         (OLD.status = 'queued'  AND NEW.status IN ('sending','cancelled'))
      OR (OLD.status = 'sending' AND NEW.status IN ('sent','failed'))
      OR (OLD.status = 'failed'  AND NEW.status IN ('sending','cancelled'))
    ) THEN
      RAISE EXCEPTION 'illegal mail state transition: % -> %', OLD.status, NEW.status;
    END IF;
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'delivery attempts cannot decrease';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION app.guard_mail_outbox_update() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.guard_mail_outbox_update() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.guard_mail_outbox_update() TO app_rw;
CREATE TRIGGER trg_guard_mail_outbox_update
  BEFORE UPDATE ON app.mail_outbox
  FOR EACH ROW EXECUTE FUNCTION app.guard_mail_outbox_update();

ALTER TABLE app.mail_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.mail_outbox FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.mail_outbox FOR ALL TO app_rw
  USING (tenant_id = app.current_tenant())
  WITH CHECK (tenant_id = app.current_tenant());
CREATE POLICY tenant_read ON app.mail_outbox FOR SELECT TO app_ro
  USING (tenant_id = app.current_tenant());
CREATE POLICY tenant_security_definer ON app.mail_outbox FOR ALL TO schema_owner
  USING (tenant_id = app.current_tenant())
  WITH CHECK (tenant_id = app.current_tenant());
REVOKE ALL ON app.mail_outbox FROM PUBLIC;
-- **app_rw に UPDATE を渡さない。** Web がやるのは「積む」ことだけ。
-- 状態を進めてよいのは送信ワーカーだけで、それは下の SECURITY DEFINER 関数
-- （mail_worker からしか呼べない）を通す。app_rw に UPDATE を残すと、
-- 1 通も送らずに queued→sending→sent と書いて「送信済み」の記録を作れる。
-- DELETE も渡さない（消せる監査ログは証跡にならない）。
GRANT SELECT, INSERT ON app.mail_outbox TO app_rw;
GRANT SELECT ON app.mail_outbox TO app_ro;

-- ------------------------------------------------------------------
-- (5) 送信ワーカーの境界
--
--   0050 の management_web と同じ形。専用ロールを作り、そのロールでしか
--   呼べない SECURITY DEFINER 関数だけが送信キューの状態を進められる。
--   ロールを分けないと「送る権限」と「業務データを書く権限」が同じになり、
--   Web 側の 1 つの欠陥がそのまま送信記録の偽装になる。
-- ------------------------------------------------------------------
-- ロールの作成は schema_owner ではできない（CREATEROLE を持たない）。
-- 0050 が management_web を作るのと同じく、ここだけ実行者（管理者）に戻す。
RESET ROLE;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='mail_worker') THEN
    CREATE ROLE mail_worker;
    COMMENT ON ROLE mail_worker IS 'created-by:isms-platform-migration';
  END IF;
  ALTER ROLE mail_worker LOGIN INHERIT NOSUPERUSER NOBYPASSRLS
    NOCREATEDB NOCREATEROLE NOREPLICATION;
END $$;
-- 既に同名のロールが居た場合、業務用ロールを継承していると境界が意味を失う
-- （app_rw を継承していれば送信キューを直接 UPDATE できる）。ALTER ROLE は
-- 属性しか変えないので、所属は明示的に外し、残っていれば止める。
REVOKE app_rw, app_ro, auth_svc, management_web, schema_owner FROM mail_worker;
DO $$
DECLARE v_roles text;
BEGIN
  SELECT string_agg(r.rolname, ', ') INTO v_roles
    FROM pg_auth_members m
    JOIN pg_roles r ON r.oid = m.roleid
    JOIN pg_roles w ON w.oid = m.member
   WHERE w.rolname = 'mail_worker';
  IF v_roles IS NOT NULL THEN
    RAISE EXCEPTION 'mail_worker must not inherit other roles (still a member of: %)', v_roles;
  END IF;
END $$;
SET ROLE schema_owner;

GRANT USAGE ON SCHEMA app TO mail_worker;
GRANT EXECUTE ON FUNCTION app.set_tenant_context(text) TO mail_worker;
GRANT EXECUTE ON FUNCTION app.current_tenant() TO mail_worker;
GRANT SELECT ON app.mail_outbox TO mail_worker;
CREATE POLICY tenant_worker_read ON app.mail_outbox FOR SELECT TO mail_worker
  USING (tenant_id = app.current_tenant());

-- 質問票を「送信済み」に進めるのは SECURITY DEFINER（schema_owner）から。
-- 0057 は所有者向けのポリシーを張っていないので、ここで足す。
--
-- **文脈が無いときに例外を投げない形で書く。** app.current_tenant() は未設定だと
-- RAISE するので、所有者にポリシーを張ると以後の ALTER TABLE ... ADD FOREIGN KEY
-- の検証スキャン（所有者として走る）がそこで落ちる（0060 の template_id 追加で
-- 実際に踏んだ）。NULL を返す版で比べれば、文脈が無いときは 1 行も見えないだけで
-- 済む＝ポリシーを張る前と同じ挙動になる。
--
-- SELECT も要る。WHERE 付きの UPDATE は行の走査に SELECT ポリシーも使うため、
-- UPDATE ポリシーだけだと 0 行になる（実測）。
CREATE OR REPLACE FUNCTION app.current_tenant_or_null() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  RETURN app.current_tenant();
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END
$$;
ALTER FUNCTION app.current_tenant_or_null() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.current_tenant_or_null() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.current_tenant_or_null() TO app_rw, app_ro, mail_worker;

CREATE POLICY tenant_security_definer ON app.external_questionnaires FOR ALL TO schema_owner
  USING (tenant_id = app.current_tenant_or_null())
  WITH CHECK (tenant_id = app.current_tenant_or_null());

CREATE OR REPLACE FUNCTION app.require_mail_worker() RETURNS void
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, app AS $$
BEGIN
  -- session_user は関数ではなくキーワードなので schema 修飾できない。
  IF session_user <> 'mail_worker' THEN
    RAISE EXCEPTION 'mail worker role required' USING ERRCODE='insufficient_privilege';
  END IF;
END
$$;
ALTER FUNCTION app.require_mail_worker() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.require_mail_worker() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.require_mail_worker() TO mail_worker;

-- 送る対象を取り出し、同時に sending へ進める。取り合いは
-- FOR UPDATE SKIP LOCKED で解決する（同じ行を 2 プロセスが送らない）。
CREATE OR REPLACE FUNCTION app.claim_mail_batch(
  p_limit integer, p_retry_failed boolean, p_retry_unconfirmed boolean
) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE v_result json;
BEGIN
  PERFORM app.require_mail_worker();
  WITH picked AS (
    SELECT id FROM app.mail_outbox
     WHERE tenant_id=app.current_tenant()
       AND (status='queued'
            OR (p_retry_failed AND status='failed'
                AND (p_retry_unconfirmed
                     OR coalesce(last_error,'') NOT LIKE '[unconfirmed]%')))
     ORDER BY queued_at
     LIMIT greatest(1, least(coalesce(p_limit, 50), 50))
     FOR UPDATE SKIP LOCKED
  ), claimed AS (
    UPDATE app.mail_outbox m
       SET status='sending', attempts=m.attempts+1, updated_at=now()
      FROM picked
     WHERE m.tenant_id=app.current_tenant() AND m.id=picked.id
    RETURNING m.id, m.purpose, m.to_email, m.to_name, m.subject,
              m.body_text, m.related_type, m.related_id
  )
  SELECT coalesce(json_agg(json_build_object(
           'id', id::text, 'purpose', purpose, 'to_email', to_email::text,
           'to_name', to_name, 'subject', subject, 'body_text', body_text,
           'related_type', coalesce(related_type,''),
           'related_id', coalesce(related_id::text,''))), '[]'::json)
    INTO v_result FROM claimed;
  RETURN v_result;
END
$$;
ALTER FUNCTION app.claim_mail_batch(integer,boolean,boolean) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.claim_mail_batch(integer,boolean,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.claim_mail_batch(integer,boolean,boolean) TO mail_worker;

-- 実際に出たものだけを送信済みにする。質問票も同時に進める。
CREATE OR REPLACE FUNCTION app.mark_mail_sent(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE v_purpose text; v_related_type text; v_related_id uuid;
BEGIN
  PERFORM app.require_mail_worker();
  UPDATE app.mail_outbox
     SET status='sent', sent_at=now(), last_error='', updated_at=now()
   WHERE tenant_id=app.current_tenant() AND id=p_id AND status='sending'
  RETURNING purpose, related_type, related_id
      INTO v_purpose, v_related_type, v_related_id;
  IF v_purpose IS NULL THEN
    RAISE EXCEPTION 'mail % is not in sending state', p_id;
  END IF;
  IF v_purpose='external_questionnaire' AND v_related_type='external_questionnaire' THEN
    UPDATE app.external_questionnaires
       SET status='sent', sent_at=now(), updated_at=now()
     WHERE tenant_id=app.current_tenant() AND id=v_related_id AND status='queued';
  END IF;
END
$$;
ALTER FUNCTION app.mark_mail_sent(uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.mark_mail_sent(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.mark_mail_sent(uuid) TO mail_worker;

CREATE OR REPLACE FUNCTION app.mark_mail_failed(p_id uuid, p_error text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  PERFORM app.require_mail_worker();
  UPDATE app.mail_outbox
     SET status='failed',
         last_error=left(regexp_replace(coalesce(p_error,''), '[[:cntrl:]]', ' ', 'g'), 500),
         updated_at=now()
   WHERE tenant_id=app.current_tenant() AND id=p_id AND status='sending';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'mail % is not in sending state', p_id;
  END IF;
END
$$;
ALTER FUNCTION app.mark_mail_failed(uuid,text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.mark_mail_failed(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.mark_mail_failed(uuid,text) TO mail_worker;

-- 取り出した直後に落ちて sending のまま残った行の回収。**再送はしない。**
-- 印を付けるのはこの関数だけで、last_error は関数の外からは書けないので、
-- [unconfirmed] を消して再送対象へ戻すことはワーカーロールでもできない。
CREATE OR REPLACE FUNCTION app.reclaim_stale_mail(p_minutes integer) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE v_result json;
BEGIN
  PERFORM app.require_mail_worker();
  IF p_minutes IS NULL OR p_minutes < 60 THEN
    RAISE EXCEPTION 'reclaim threshold must be at least 60 minutes';
  END IF;
  WITH stale AS (
    UPDATE app.mail_outbox
       SET status='failed',
           last_error='[unconfirmed] 送信中のまま停止。実際に送られたか確認してから再送してください',
           updated_at=now()
     WHERE tenant_id=app.current_tenant() AND status='sending'
       AND updated_at < now() - make_interval(mins => p_minutes)
    RETURNING id
  )
  SELECT coalesce(json_agg(json_build_object('id', id::text)), '[]'::json)
    INTO v_result FROM stale;
  RETURN v_result;
END
$$;
ALTER FUNCTION app.reclaim_stale_mail(integer) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.reclaim_stale_mail(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.reclaim_stale_mail(integer) TO mail_worker;

RESET ROLE;

