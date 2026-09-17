-- @run-as: admin
-- 0056: ISMS 適用範囲（4.3）の承認を記録する関数。
--
-- 適用範囲だけ承認の経路が無く、app.approvals へ直接 INSERT するしかなかった。
-- 直接 INSERT だと「誰が承認してよいか」を DB が見ないので、規程の承認
-- （0034 の app.approve_policy_version）と同じ形にそろえる。
--
-- そろえるのは 3 点:
--   1. 経営責任者（ciso）でなければ承認できない
--   2. 承認した時点の本文のハッシュを承認記録へ結ぶ
--      （後から本文を直しても「何を承認したか」が残る）
--   3. 同じ本文を二重に承認できない
--      （本文が変わっていれば、改めて承認できる）

SET ROLE schema_owner;

CREATE FUNCTION app.approve_iso_scope(p_comment text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant uuid := app.current_tenant();
  v_user   uuid := app.current_session_user();
  v_scope  text;
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

  -- **FOR UPDATE を付けない。** 行ロックは UPDATE ポリシーも要求するが、
  -- schema_owner は app.tenants に SELECT（ctx_tenant_lookup）と INSERT の
  -- ポリシーしか持たない。付けると 1 行も見えず「本文が空」と誤判定する（実測）。
  -- ロックが無くても記録は矛盾しない。ハッシュは**いま読んだ本文**から取るので、
  -- 承認記録は常に「承認した時点の本文」を指す。
  SELECT iso_scope_statement INTO v_scope
    FROM app.tenants WHERE id = v_tenant;
  IF v_scope IS NULL OR length(btrim(v_scope)) = 0 THEN
    RAISE EXCEPTION 'iso scope statement is empty';
  END IF;

  v_hash := public.digest(pg_catalog.convert_to(v_scope, 'UTF8'), 'sha256');

  -- **同じ本文を二重に承認しない。** 本文が変わっていれば通す
  -- （改訂のたびに承認し直すのが 4.3 の運用）。
  IF EXISTS (
    SELECT 1 FROM app.approvals
     WHERE tenant_id = v_tenant AND target_type = 'iso_scope'
       AND target_id = v_tenant AND target_version_hash = v_hash
  ) THEN
    RAISE EXCEPTION 'this iso scope statement is already approved';
  END IF;

  INSERT INTO app.approvals
    (tenant_id, target_type, target_id, target_version_hash,
     approver_user_id, comment, created_by)
  VALUES (v_tenant, 'iso_scope', v_tenant, v_hash, v_user, p_comment, v_user);
END $$;
ALTER FUNCTION app.approve_iso_scope(text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.approve_iso_scope(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.approve_iso_scope(text) TO app_rw;

COMMENT ON FUNCTION app.approve_iso_scope(text) IS
  'ISMS 適用範囲（4.3）の承認。ciso のみ実行でき、承認時の本文のハッシュを app.approvals へ結ぶ。同じ本文の二重承認は拒否する。';

RESET ROLE;
