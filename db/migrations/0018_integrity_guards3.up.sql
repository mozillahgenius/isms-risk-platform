-- 0018 0017 の検査の穴を塞ぐ。
--   1. 既存行の事前検査が FORCE RLS で 0 行しか見ておらず、実質空振りだった
--   2. 標準基準の不変化が一部の列しか見ていなかった
--   3. 逸脱の status を active へ戻すときに検査が走らなかった
--   4. DOM 版切替と逸脱登録が同時に走ると、互いを見ずに両方通り得た

-- ------------------------------------------------------------------
-- 1. 定義者（schema_owner）が app.deviations を横断で読めるようにする。
--
--    0017 の事前検査は schema_owner で実行されるが、app.deviations は
--    FORCE RLS で schema_owner 向けポリシーが無いため **0 行に見えていた**。
--    「既存の不正な行があれば止める」という検査が、何も見ずに成功していた。
--    sessions / memberships / users / tenants と同じ扱いにする。
-- ------------------------------------------------------------------
CREATE POLICY ctx_deviation_lookup ON app.deviations FOR SELECT TO schema_owner
  USING (true);

-- 改めて既存行を検査する（今度は実際に見える）
DO $$
DECLARE r record; v_bad text := '';
BEGIN
  FOR r IN SELECT id, tenant_id, override FROM app.deviations
            WHERE kind = 'risk_band'
              AND status IN ('requested','active','expired','withdrawn') LOOP
    -- expired / withdrawn も対象にする。status を active へ戻す経路があるため、
    -- 「今は無効だから不正なままでよい」とはしない。
    BEGIN
      PERFORM app.check_risk_band_override(r.tenant_id, r.override);
    EXCEPTION WHEN others THEN
      v_bad := v_bad || format('%s(%s) ', r.id, SQLERRM);
    END;
  END LOOP;
  IF v_bad <> '' THEN
    RAISE EXCEPTION '新しい検査を通らない既存の逸脱がある: %', v_bad;
  END IF;
END $$;

-- ------------------------------------------------------------------
-- 2. 標準基準の不変化を全列へ広げる。
--    0017 は算定式と 4 区分しか見ておらず、期限（due_days_*）と
--    主キーの dom_version_id を動かせた。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION catalog.risk_criteria_default_immutable() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, catalog AS $$
BEGIN
  -- 主キーの付け替えは常に禁止（どの DOM 版の基準なのかが変わってしまう）
  IF NEW.dom_version_id IS DISTINCT FROM OLD.dom_version_id THEN
    RAISE EXCEPTION '標準リスク基準の dom_version_id は変更できない';
  END IF;
  IF NEW.impact_sec_formula     IS DISTINCT FROM OLD.impact_sec_formula
     OR NEW.band_top_priority   IS DISTINCT FROM OLD.band_top_priority
     OR NEW.band_action         IS DISTINCT FROM OLD.band_action
     OR NEW.band_consider       IS DISTINCT FROM OLD.band_consider
     OR NEW.band_accept         IS DISTINCT FROM OLD.band_accept
     OR NEW.due_days_top_priority IS DISTINCT FROM OLD.due_days_top_priority
     OR NEW.due_days_action     IS DISTINCT FROM OLD.due_days_action THEN
    IF EXISTS (SELECT 1 FROM app.tenants t WHERE t.dom_version_id = OLD.dom_version_id) THEN
      RAISE EXCEPTION
        '配布済みの DOM 版の標準リスク基準は変更できない。新しい DOM 版を作ること';
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ------------------------------------------------------------------
-- 3. status が active になるときも検査する。
--    0017 は override / kind / tenant_id が動いたときだけ発火するので、
--    「不正なまま expired になっている行を active へ戻す」経路が空いていた。
--    あわせて、テナント単位の advisory lock で DOM 版切替と直列化する（4）。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.validate_deviation_override() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.kind = 'risk_band' THEN
    -- テナント単位で直列化する。これを取らないと、DOM 版の切替と
    -- 逸脱の登録が同時に走ったとき互いの未コミット行が見えず、
    -- 「新しい標準 × 旧標準で検証した override」という組合せが残る。
    PERFORM pg_advisory_xact_lock(hashtext('isms.tenant.' || NEW.tenant_id::text));
    PERFORM app.check_risk_band_override(NEW.tenant_id, NEW.override);
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_validate_deviation_override_upd ON app.deviations;
CREATE TRIGGER trg_validate_deviation_override_upd
  BEFORE UPDATE ON app.deviations
  FOR EACH ROW
  WHEN (NEW.override  IS DISTINCT FROM OLD.override
     OR NEW.kind      IS DISTINCT FROM OLD.kind
     OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
     OR (NEW.status = 'active' AND OLD.status IS DISTINCT FROM 'active'))
  EXECUTE FUNCTION app.validate_deviation_override();

-- ------------------------------------------------------------------
-- 4. DOM 版切替側も同じロックを取る。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.guard_tenant_dom_version() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.dom_version_id IS DISTINCT FROM OLD.dom_version_id THEN
    PERFORM pg_advisory_xact_lock(hashtext('isms.tenant.' || NEW.id::text));
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
