-- @run-as: admin

-- **データがあるときは巻き戻さない。** 情報セキュリティ目的とその達成評価は
-- 6.2 の記録であり、down で黙って消えてよいものではない。
--
-- guard は **SET ROLE の前**に置く。schema_owner に切り替えたあとだと
-- RLS の management_definer_access が app.current_tenant() を要求し、
-- テナント文脈の無い migration では件数を数える前に落ちる（実測）。
-- 接続ユーザーは superuser かつ BYPASSRLS なので、全テナントを数えられる
-- （本番で実測: postgres / super=true / bypassrls=true）。
--
-- **数える前にロックを取る。** ロックが無いと count と DROP の間に
-- 別セッションが INSERT でき、0 件と判定した直後の行ごと消える。
-- migrate.sh の run_file が up/down とも BEGIN 〜 COMMIT で包むので、
-- ここで取ったロックは DROP TABLE まで保持される（実測で確認）。
--
-- **SHARE で足りる。** 止めたいのは INSERT/UPDATE/DELETE（ROW EXCLUSIVE）で、
-- SHARE はそれと競合しつつ SELECT は通す。ACCESS EXCLUSIVE にすると
-- 読み取り中のセッションがあるだけで、拒否を返す前に待たされる。
--
-- ロック待ちで配備が固まらないよう時間を切る。取れなければ落として、
-- 「巻き戻せるか分からない」を「巻き戻さない」に倒す。
SET LOCAL lock_timeout = '10s';
DO $$
DECLARE n integer;
BEGIN
  LOCK TABLE app.security_objectives IN SHARE MODE;
  SELECT count(*) INTO n FROM app.security_objectives;
  IF n > 0 THEN
    RAISE EXCEPTION '0055 rollback refused: security objectives would be lost (% rows)', n;
  END IF;
END $$;

SET ROLE schema_owner;

DROP TABLE IF EXISTS app.security_objectives;

RESET ROLE;
