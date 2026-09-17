-- T-09: ⑦（独立検証）への入口は receipt を返す追記だけに固定する。
-- app_rw / app_ro は元レコードを読んだり書き換えたり消したりできず、
-- app.accept_verification_receipt() と check_runs への実行記録だけを使う。

SET ROLE schema_owner;

CREATE TABLE app.verification_receipts (
  id           uuid        NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES app.tenants(id),
  check_keys   text[]      NOT NULL CHECK (cardinality(check_keys) > 0),
  requester    text        NOT NULL CHECK (length(btrim(requester)) > 0),
  accepted_at  timestamptz NOT NULL DEFAULT pg_catalog.now(),
  PRIMARY KEY (tenant_id, id)
);

ALTER TABLE app.verification_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.verification_receipts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.verification_receipts FROM PUBLIC, app_rw, app_ro;

-- SECURITY DEFINER の受付関数だけが追記する。過去の受付は定義者からも更新・削除しない。
CREATE POLICY verification_receipt_definer_insert ON app.verification_receipts
  FOR INSERT TO schema_owner WITH CHECK (tenant_id = app.current_tenant());
CREATE POLICY verification_receipt_definer_read ON app.verification_receipts
  FOR SELECT TO schema_owner USING (true);

CREATE OR REPLACE FUNCTION app.accept_verification_receipt(
  p_check_keys text[], p_requester text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE
  v_tenant uuid := app.current_tenant();
  v_id uuid := pg_catalog.gen_random_uuid();
  v_keys text[];
BEGIN
  IF v_tenant IS NULL OR coalesce(pg_catalog.btrim(p_requester), '') = '' THEN
    RAISE EXCEPTION 'verification receipt request is incomplete' USING ERRCODE = 'check_violation';
  END IF;
  SELECT array_agg(DISTINCT requested.key ORDER BY requested.key) INTO v_keys
    FROM unnest(coalesce(p_check_keys, ARRAY[]::text[])) AS requested(key);
  IF coalesce(cardinality(v_keys), 0) = 0 OR EXISTS (
    SELECT 1 FROM unnest(v_keys) AS requested(key)
     WHERE NOT EXISTS (SELECT 1 FROM catalog.checks c WHERE c.key = requested.key)
  ) THEN
    RAISE EXCEPTION 'verification receipt checks are invalid' USING ERRCODE = 'check_violation';
  END IF;
  INSERT INTO app.verification_receipts (id, tenant_id, check_keys, requester)
  VALUES (v_id, v_tenant, v_keys, p_requester);
  RETURN v_id;
END $$;
ALTER FUNCTION app.accept_verification_receipt(text[],text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.accept_verification_receipt(text[],text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.accept_verification_receipt(text[],text) TO app_rw;

ALTER TABLE app.check_runs ADD COLUMN verification_receipt_id uuid;

CREATE OR REPLACE FUNCTION app.enforce_verification_receipt() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.verification_receipt_id IS NULL THEN
    RAISE EXCEPTION 'verification receipt id is required before execution' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM app.verification_receipts r
     WHERE r.tenant_id = NEW.tenant_id
       AND r.id = NEW.verification_receipt_id
       AND NEW.check_key = ANY(r.check_keys)
  ) THEN
    RAISE EXCEPTION 'verification receipt does not authorize this check' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
ALTER FUNCTION app.enforce_verification_receipt() OWNER TO schema_owner;

CREATE TRIGGER trg_check_runs_verification_receipt
  BEFORE INSERT ON app.check_runs
  FOR EACH ROW EXECUTE FUNCTION app.enforce_verification_receipt();

RESET ROLE;
