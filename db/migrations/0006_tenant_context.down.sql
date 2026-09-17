-- 0006 の巻き戻し。関数を先に落としてから鍵テーブルを落とす。
-- current_tenant() は 0001 の仮定義（GUC を読むだけ）へ戻す。
DROP FUNCTION IF EXISTS app.revoke_session(text);
DROP FUNCTION IF EXISTS app.create_session(uuid, uuid, text, interval);
DROP FUNCTION IF EXISTS app.set_tenant_context(text);

CREATE OR REPLACE FUNCTION app.current_tenant() RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE v text := current_setting('app.tenant_id', true);
BEGIN
  IF v IS NULL OR v = '' THEN
    RAISE EXCEPTION 'tenant context is not set' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v::uuid;
END $$;

DROP FUNCTION IF EXISTS app.tenant_context_signature(uuid);
DROP TABLE IF EXISTS app.tenant_context_keys;
