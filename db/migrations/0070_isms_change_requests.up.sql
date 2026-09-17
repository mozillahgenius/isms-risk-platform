-- @run-as: admin
-- 0070: 変更の申請と承認（A.8.32）の受け皿（設計書 2026-09-11 §4 の 5 本目・最後）。
--
-- A.8.32 は、情報処理設備と情報システムの変更を、変更管理の手順に従わせることを求める統制。
-- 変更に許可が要ることそのものが統制の中身なので、§4 の表の中でこれだけに承認を付ける（2026-09-12 goto-twin 決定）。
-- 附属書 A の統制なので、段階の画面では件数を出すだけで必須にしない。
--
-- 流れ: 申請（requested）→ 承認（approved）または却下（rejected）→ 実施（implemented）。
--       申請中・承認後は取りやめ（cancelled）できる。取りやめ・却下・実施は終わり（戻さない）。
-- 承認・却下は app.decide_change_request() だけが書く。経営層（ciso）に限り、申請者は自分の申請を判断しない。
-- 承認した時点の中身のハッシュを app.approvals へ結ぶ（0063 のマネジメントレビューの承認と同じ形）。
--
-- 表を直接書く app_rw（0067 の役割ポリシーで申請の役割に絞る）からは、判断の欄を書けないよう、
-- トリガで状態の遷移と判断の欄を守る。書き込みの役割ポリシーだけでは、メンバーが自分で
-- 「承認済み・承認者＝経営層」と書けてしまう。承認した後に中身を直すと「何を承認したか」がずれるので、
-- 中身を直せるのは申請中だけ。消さずに取りやめる（app_rw に DELETE を渡さない）。中身のデータは入れない。

SET ROLE schema_owner;

CREATE TABLE app.change_requests (
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL,
  title           text NOT NULL,
  -- 何をどう変えるか（必須）。
  description     text NOT NULL,
  -- 影響とリスク（必須）。影響を書けない変更は判断できない。
  impact          text NOT NULL,
  risk_level      text NOT NULL CHECK (risk_level IN ('low','medium','high')),
  -- 失敗したときの戻し方。
  rollback_plan   text NOT NULL DEFAULT '',
  asset_id        uuid,
  -- 実施の予定日（予定なので中身ではなく、承認後も直せる）。
  planned_on      date,
  requested_by    uuid NOT NULL,
  requested_at    timestamptz NOT NULL DEFAULT now(),
  status          text NOT NULL DEFAULT 'requested'
                  CHECK (status IN ('requested','approved','rejected','implemented','cancelled')),
  decided_by      uuid,
  decided_at      timestamptz,
  decision_note   text NOT NULL DEFAULT '',
  implemented_by  uuid,
  implemented_at  timestamptz,
  result_note     text NOT NULL DEFAULT '',
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, asset_id)       REFERENCES app.assets(tenant_id, id),
  FOREIGN KEY (tenant_id, requested_by)   REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, decided_by)     REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, implemented_by) REFERENCES app.users(tenant_id, id),
  CHECK (title ~ '[^[:space:]]'),
  CHECK (description ~ '[^[:space:]]'),
  CHECK (impact ~ '[^[:space:]]'),
  -- 承認・却下・実施と言うなら、誰がいつ判断したかが要る。申請中は判断が無い。判断の人と日時はそろう。
  CONSTRAINT change_requests_decision_complete CHECK (
    (decided_by IS NULL) = (decided_at IS NULL)
    AND (status NOT IN ('approved','rejected','implemented') OR decided_by IS NOT NULL)
    AND (status <> 'requested' OR decided_by IS NULL)
  ),
  -- 職務分離: 申請者は自分の申請を判断しない。
  CONSTRAINT change_requests_decider_not_requester CHECK (decided_by IS NULL OR decided_by <> requested_by),
  -- 実施と言うなら、誰がいつ実施したかが要る。実施の人と日時はそろう。
  CONSTRAINT change_requests_implementation_complete CHECK (
    (implemented_by IS NULL) = (implemented_at IS NULL)
    AND ((status = 'implemented') = (implemented_by IS NOT NULL))
  ),
  -- 実施は判断（承認）の後。
  CONSTRAINT change_requests_implemented_after_decided CHECK (implemented_at IS NULL OR implemented_at >= decided_at)
);
CREATE INDEX change_requests_status ON app.change_requests (tenant_id, status, requested_at DESC);

-- 状態の遷移と判断の欄を守る。判断（承認・却下）の欄は schema_owner（= decide_change_request）だけが書ける。
-- app_rw から来た書き込みでは current_user は app_rw（またはその所属ロール）なので、ここで区別できる。
CREATE FUNCTION app.change_requests_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  v_definer boolean := (current_user = 'schema_owner');
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'requested' OR NEW.decided_by IS NOT NULL OR NEW.decided_at IS NOT NULL
       OR NEW.decision_note <> '' OR NEW.implemented_by IS NOT NULL OR NEW.implemented_at IS NOT NULL THEN
      RAISE EXCEPTION 'change request must start as requested' USING ERRCODE = 'check_violation';
    END IF;
    -- 申請者は申請した本人（他人の名義で申請して、自分で承認する迂回を防ぐ。Codex レビュー 2026-09-12）。申請日時は今。
    IF NOT v_definer AND NEW.requested_by IS DISTINCT FROM app.current_session_user() THEN
      RAISE EXCEPTION 'requester must be the session user' USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.requested_at := now();
    RETURN NEW;
  END IF;
  -- 申請の ID・テナントは変えない（変えると承認の記録 app.approvals.target_id との結び付きが切れる）。
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
    RAISE EXCEPTION 'change request id cannot be changed' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT v_definer AND (NEW.decided_by IS DISTINCT FROM OLD.decided_by
                        OR NEW.decided_at IS DISTINCT FROM OLD.decided_at
                        OR NEW.decision_note IS DISTINCT FROM OLD.decision_note) THEN
    RAISE EXCEPTION 'change request decision can only be recorded by the approval function'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NEW.requested_by IS DISTINCT FROM OLD.requested_by OR NEW.requested_at IS DISTINCT FROM OLD.requested_at THEN
    RAISE EXCEPTION 'change request requester cannot be changed' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'requested' AND NEW.status IN ('approved','rejected') AND v_definer)
    OR (OLD.status = 'requested' AND NEW.status = 'cancelled')
    OR (OLD.status = 'approved'  AND NEW.status IN ('implemented','cancelled'))
  ) THEN
    RAISE EXCEPTION 'illegal change request transition: % -> %', OLD.status, NEW.status USING ERRCODE = 'check_violation';
  END IF;
  -- 中身を直せるのは申請中だけ（承認・却下した中身とずれないように）。予定日は中身に含めない。
  IF OLD.status <> 'requested'
     AND (NEW.title, NEW.description, NEW.impact, NEW.risk_level, NEW.rollback_plan, NEW.asset_id)
         IS DISTINCT FROM (OLD.title, OLD.description, OLD.impact, OLD.risk_level, OLD.rollback_plan, OLD.asset_id) THEN
    RAISE EXCEPTION 'change request content can only be edited while requested' USING ERRCODE = 'check_violation';
  END IF;
  -- 実施の記録は、実施へ進むときにだけ書ける（後から実施者・日時を書き換えない）。
  IF OLD.status <> 'approved' AND (NEW.implemented_by IS DISTINCT FROM OLD.implemented_by
                                   OR NEW.implemented_at IS DISTINCT FROM OLD.implemented_at) THEN
    RAISE EXCEPTION 'change request implementation can only be recorded once, after approval' USING ERRCODE = 'check_violation';
  END IF;
  -- 実施者は記録した本人、実施日時は今（他人の名義・過去の日時で実施を記録させない）。
  IF NEW.status = 'implemented' AND OLD.status = 'approved' THEN
    IF NOT v_definer AND NEW.implemented_by IS DISTINCT FROM app.current_session_user() THEN
      RAISE EXCEPTION 'implementer must be the session user' USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.implemented_at := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER change_requests_guard BEFORE INSERT OR UPDATE ON app.change_requests
  FOR EACH ROW EXECUTE FUNCTION app.change_requests_guard();

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['change_requests'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    -- 消さずに取りやめる。app_rw に DELETE を渡さない（承認の記録と対になる申請を消させない）。
    EXECUTE format('GRANT SELECT,INSERT,UPDATE ON app.%I TO app_rw',t);
    -- 0067 と同じ役割ポリシー（名前・形・対象表は check_rls.sql が固定する。DELETE は権限が無いが形をそろえる）。
    EXECUTE format('CREATE POLICY records_role_insert ON app.%I AS RESTRICTIVE FOR INSERT TO app_rw '
                   'WITH CHECK ((SELECT app.records_role_allows(%L)))', t, 'change');
    EXECUTE format('CREATE POLICY records_role_update ON app.%I AS RESTRICTIVE FOR UPDATE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L))) WITH CHECK ((SELECT app.records_role_allows(%L)))',
                   t, 'change', 'change');
    EXECUTE format('CREATE POLICY records_role_delete ON app.%I AS RESTRICTIVE FOR DELETE TO app_rw '
                   'USING ((SELECT app.records_role_allows(%L)))', t, 'change');
  END LOOP;
END $$;

-- 判断の関数が schema_owner として申請を読み書きするための口（0062 と同じ書き方。文脈が無いと何も見えない）。
-- 名前と形・張る表は check_rls.sql が固定する。
CREATE POLICY tenant_security_definer ON app.change_requests FOR ALL TO schema_owner
  USING (tenant_id = (SELECT app.current_tenant_or_null()))
  WITH CHECK (tenant_id = (SELECT app.current_tenant_or_null()));

COMMENT ON TABLE app.change_requests IS
  '変更の申請と承認（A.8.32）。承認・却下は app.decide_change_request() だけ（ciso・申請者以外）。中身を直せるのは申請中だけ。消さずに取りやめる。';

-- 承認・却下。経営層（ciso）だけ。申請者は自分の申請を判断しない。却下には理由が要る。
-- 承認した時点の中身（件名・内容・影響・リスク・戻し方・資産）のハッシュを app.approvals へ結ぶ。
CREATE FUNCTION app.decide_change_request(p_id uuid, p_approve boolean, p_note text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant uuid := app.current_tenant();
  v_user   uuid := app.current_session_user();
  r        app.change_requests%ROWTYPE;
  v_hash   bytea;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM app.memberships m
      JOIN app.users u ON u.tenant_id = m.tenant_id AND u.id = m.user_id
     WHERE m.tenant_id = v_tenant AND m.user_id = v_user AND m.role_key = 'ciso'
       AND m.revoked_at IS NULL AND u.status = 'active'
  ) THEN
    RAISE EXCEPTION 'executive role required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT * INTO r FROM app.change_requests WHERE tenant_id = v_tenant AND id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'change request not found';
  END IF;
  IF r.status <> 'requested' THEN
    RAISE EXCEPTION 'change request is not awaiting a decision';
  END IF;
  IF r.requested_by = v_user THEN
    RAISE EXCEPTION 'requester cannot decide their own change request' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_approve IS NULL THEN
    RAISE EXCEPTION 'decision required';
  END IF;
  IF NOT p_approve AND (p_note IS NULL OR p_note !~ '[^[:space:]]') THEN
    RAISE EXCEPTION 'rejection reason required';
  END IF;
  IF p_approve THEN
    -- JSON 配列にしてからハッシュにする（区切り文字だけで繋ぐと、改行を含む本文で別の中身が同じバイト列になる）。
    v_hash := public.digest(pg_catalog.convert_to(jsonb_build_array(r.title, r.description, r.impact, r.risk_level,
                                                                    r.rollback_plan, coalesce(r.asset_id::text, ''))::text,
                                                  'UTF8'), 'sha256');
    INSERT INTO app.approvals
      (tenant_id, target_type, target_id, target_version_hash, approver_user_id, comment, created_by)
    VALUES (v_tenant, 'change_request', p_id, v_hash, v_user, p_note, v_user);
  END IF;
  UPDATE app.change_requests
     SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
         decided_by = v_user, decided_at = now(), decision_note = coalesce(p_note, ''),
         updated_at = now(), updated_by = v_user
   WHERE tenant_id = v_tenant AND id = p_id;
END $$;
ALTER FUNCTION app.decide_change_request(uuid, boolean, text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.decide_change_request(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.decide_change_request(uuid, boolean, text) TO app_rw;

COMMENT ON FUNCTION app.decide_change_request(uuid, boolean, text) IS
  '変更の申請（A.8.32）の承認・却下。ciso のみ・申請者以外・申請中だけ。承認は中身のハッシュを app.approvals へ結ぶ。却下は理由必須。';

-- 許可の表に change を足す: owner / admin / manager / member（申請は誰でも出せる。判断は上の関数で ciso だけ）。
-- 監査人には書かせない。0069 の版に種類を 1 つ足しただけ（down で 0069 の版へ戻す）。
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
