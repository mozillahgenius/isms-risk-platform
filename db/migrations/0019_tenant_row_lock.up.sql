-- 0019 テナント単位の直列化を advisory lock から行ロックへ変える。
--
-- 0018 は pg_advisory_xact_lock(hashtext(...)) で直列化したが、2 つ問題がある。
--   1. advisory lock は待ち終わってもスナップショットを更新しない。
--      READ COMMITTED では文の開始時のスナップショットで読み続けるので、
--      待っている間に相手がコミットした行が見えない ＝ 直列化になっていない。
--   2. hashtext() は 32bit。別テナント同士が衝突して無関係に待たされ得る。
--
-- app.tenants の該当行を FOR UPDATE で掴む方式に変える。
-- FOR UPDATE は待ち終わったあと最新版を読み直す（EvalPlanQual）ので、
-- 相手のコミット結果が確実に見える。ロック対象はテナント行そのものなので
-- 衝突も起きない。ロック順もテナント ID 単位で自然に揃う。

-- ロックの範囲と順序について（デッドロックの扱い）:
--   このトリガは FOR EACH ROW なので、**1 文でも複数テナントの行を掴み得る**。
--   複数行 INSERT / UPDATE を 1 文で流すと、行ごとにこの関数が走り、
--   それぞれのテナント行を順に掴む。掴む順序は文の行順になる。
--   ただしアプリロールからは起きない。app.deviations は RLS で
--   current_tenant() に限定されるため、app_rw が 1 トランザクションで
--   複数テナントの逸脱を触る経路は無い。
--   複数テナントを掴み得るのは RLS の外にいる schema_owner（seed・保守作業・
--   一括投入）で、これは今も現実に成立する経路である。
--   **schema_owner で複数テナントの逸脱をまとめて流すときは、DML の前に
--     対象テナント行をまとめて掴んでおくこと。**
--
--       SELECT 1 FROM app.tenants WHERE id = ANY($1) ORDER BY id FOR UPDATE;
--       -- そのあとで INSERT / UPDATE を流す
--
--   「行を tenant_id 昇順に並べてから流す」では防げない。
--   INSERT / UPDATE の行処理順は SQL では保証されず、
--   ORDER BY を付けてもトリガの実行順は決まらないため。
--   確実なのは上のように順序が決まった SELECT ... FOR UPDATE で先に掴むか、
--   1 文（1 トランザクション）で 1 テナントだけを扱うかのどちらか。
--
--   **この事前ロックが効くのは、複数テナントを触る経路が「全て」同じ作法を
--     守っている場合だけ。** 1 つでも事前ロックせずに流す経路が混ざると、
--   その経路とはロック順が揃わずデッドロックし得る。
--   複数テナントを 1 トランザクションで触る処理を足すときは、
--   既存の経路も同じ作法になっているかを必ず確認すること。
--   ロックはトランザクション終了まで残るので、逸脱の登録・更新を含む
--   トランザクションは短く保つ（長く持つと DOM 版切替を待たせる）。
CREATE OR REPLACE FUNCTION app.validate_deviation_override() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE v_dom uuid;
BEGIN
  IF NEW.kind = 'risk_band' THEN
    -- テナント行を掴む。DOM 版切替（guard_tenant_dom_version）と同じ行を
    -- 取り合うので、片方が終わるまでもう片方は進めない。
    -- 待ち終わったあとは最新の dom_version_id が見える。
    SELECT t.dom_version_id INTO v_dom
      FROM app.tenants t WHERE t.id = NEW.tenant_id FOR UPDATE;
    -- 存在判定は FOUND で行う。v_dom IS NULL で判定すると
    -- 「列が NULL」と「行が無い」を取り違える（列定義に依存しない書き方にする）。
    IF NOT FOUND THEN
      RAISE EXCEPTION 'テナントが存在しない: %', NEW.tenant_id;
    END IF;
    PERFORM app.check_risk_band_override(NEW.tenant_id, NEW.override);
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION app.guard_tenant_dom_version() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.dom_version_id IS DISTINCT FROM OLD.dom_version_id THEN
    -- UPDATE 中なのでこの行は既に排他ロック済み。逸脱側は上で同じ行を
    -- FOR UPDATE しようとして待つ。待ち終われば切替後の状態が見える。
    IF EXISTS (SELECT 1 FROM app.deviations d
                WHERE d.tenant_id = NEW.id AND d.kind = 'risk_band'
                  AND d.status = 'active') THEN
      RAISE EXCEPTION
        '有効な risk_band 逸脱があるテナントの DOM 版は切り替えられない。'
        ' 先に逸脱を取り下げるか失効させること';
    END IF;
  END IF;
  RETURN NEW;
END $$;
