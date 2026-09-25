-- 0084 端末の招待の取り消し（2026-09-25）
--
-- 招待を複数送ってしまったときなどに、管理者が過去の招待を失効させる。
-- 既存の「期限切れ」に乗せる: 期限を今にし、状態を expired、理由（failure_code）を revoked_by_admin にする。
-- 導入ページ（lookup_agent_installation）・導入の各段階（mark_agent_installation）・登録コードの消費は、
-- どれも「期限切れなら断る」作りなので、それぞれの関数は変えない。
-- 有効（active）になった端末は招待ではなく登録済みの端末なので、ここでは取り消さない。
-- 組織は呼び出しの文脈（app.current_tenant()）で決め、引数では受けない（他の組織の招待は取り消せない）。

CREATE OR REPLACE FUNCTION app.revoke_agent_installation(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  r app.agent_installations;
  v_tenant uuid := app.current_tenant();
BEGIN
  IF v_tenant IS NULL OR p_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid');
  END IF;
  SELECT * INTO r FROM app.agent_installations
   WHERE id = p_id AND tenant_id = v_tenant
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF r.status = 'active' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_active');
  END IF;
  IF r.status = 'expired' AND r.failure_code = 'revoked_by_admin' THEN
    RETURN jsonb_build_object('ok', true, 'id', r.id, 'already', true);
  END IF;
  UPDATE app.agent_installations
     SET status = 'expired',
         expires_at = GREATEST(r.created_at + interval '1 second', pg_catalog.now()),
         failure_code = 'revoked_by_admin'
   WHERE id = r.id;
  RETURN jsonb_build_object('ok', true, 'id', r.id);
END $$;
ALTER FUNCTION app.revoke_agent_installation(uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.revoke_agent_installation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.revoke_agent_installation(uuid) TO management_web;
