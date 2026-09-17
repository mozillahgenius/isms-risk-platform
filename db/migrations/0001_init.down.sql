-- @run-as: admin
-- 0001 の巻き戻し。
-- 拡張は落とさない（同じ DB の他スキーマが使っている可能性があり、過剰な DROP になる）。
-- スキーマは CASCADE を使わない。0002〜0015 の down が走り切っていれば空のはずで、
-- 残っていれば DROP は失敗する。それは巻き戻し漏れの検知として歓迎する事象なので握り潰さない。

DROP FUNCTION IF EXISTS app.set_tenant_context(text);
DROP FUNCTION IF EXISTS app.current_tenant();

-- ALTER DEFAULT PRIVILEGES の取り消し（ロールを消す前に必要）
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'catalog') THEN
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE schema_owner IN SCHEMA catalog
               REVOKE SELECT ON TABLES FROM app_rw, app_ro';
  END IF;
END $$;

DROP SCHEMA IF EXISTS audit;
DROP SCHEMA IF EXISTS app;
DROP SCHEMA IF EXISTS catalog;

-- public スキーマの CREATE 権限は **戻さない**。
-- up の REVOKE は「元々付いていたか」を記録していないので、無条件に GRANT し直すと、
-- この migration を当てる前から施されていた hardening を巻き戻しで解除してしまう。
-- 巻き戻しで安全側から危険側へ動かすくらいなら、戻さない方がよい。
-- 元の状態へ戻したい場合は手で `GRANT CREATE ON SCHEMA public TO PUBLIC` を実行する。

-- ロールはデータベース単位ではなく **クラスタ全体** の存在なので、
-- 同じクラスタの別 DB（開発用と CI 用を並べている等）がまだ参照していると落とせない。
-- 無条件に DROP すると、その別 DB を壊すか、ここで必ず失敗する。
-- 他 DB からの依存が残っている間は残し、依存が無くなったときだけ落とす。
DO $$
DECLARE
  r text;
  n int;
  roles constant text[] := ARRAY['audit_verifier','auditlogd','auth_svc',
                                 'app_ro','app_rw','schema_owner'];
BEGIN
  FOREACH r IN ARRAY roles LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN CONTINUE; END IF;

    -- up が作ったロールにだけ印が付く。印が無い＝もともと在ったロールなので
    -- 触らない（DROP OWNED BY はそのロールの所有物を巻き添えで消す）。
    IF NOT EXISTS (
      SELECT 1 FROM pg_shdescription sd
        JOIN pg_roles ro ON ro.oid = sd.objoid
       WHERE ro.rolname = r
         AND sd.classoid = 'pg_authid'::regclass
         AND sd.description = 'created-by:isms-platform-migration'
    ) THEN
      RAISE NOTICE 'ロール % は この migration が作ったものではないので残します', r;
      CONTINUE;
    END IF;

    SELECT count(*) INTO n
      FROM pg_shdepend d
      JOIN pg_roles ro ON ro.oid = d.refobjid
     WHERE ro.rolname = r AND d.dbid <> 0
       AND d.dbid <> (SELECT oid FROM pg_database WHERE datname = current_database());
    IF n > 0 THEN
      RAISE NOTICE 'ロール % は他のデータベースが参照中（% 件）のため残します', r, n;
    ELSE
      EXECUTE format('DROP OWNED BY %I', r);
      EXECUTE format('DROP ROLE %I', r);
    END IF;
  END LOOP;
END $$;
