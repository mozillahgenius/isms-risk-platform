-- 0022 の巻き戻し。
-- provision_tenant は 0021 の定義へは戻さない（戻すと public.gen_random_uuid() を
-- 名指しする古い形に逆行する）。関数の実体は 0021 の down が落とす。
SET ROLE schema_owner;

DROP TRIGGER IF EXISTS trg_check_runs_digest ON app.check_runs;
DROP FUNCTION IF EXISTS app.enforce_check_digest();
DROP FUNCTION IF EXISTS catalog.check_digest(text);

RESET ROLE;
