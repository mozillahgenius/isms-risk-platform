-- 0017 0016 で入れた検査の穴を塞ぐ。
--   1. 既存の不正な逸脱を見逃したまま適用できていた
--   2. 検査が全 UPDATE で走り、期限切れ処理まで巻き添えで落ち得た
--   3. 標準基準・DOM 版が後から変わると、部分 override との組合せが崩れる
--   4. 凍結した基準版を「閉じてから開き直す」ことができた
--   5. 基準版を DELETE できた

-- ------------------------------------------------------------------
-- 0. 検査の本体を、トリガから切り離して単独で呼べる関数にする。
--    こうしないと「既存行がこの検査を通るか」を適用前に確かめられない。
--    0016 のトリガ関数はこの関数を呼ぶだけにする。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.check_risk_band_override(p_tenant uuid, p_override jsonb)
RETURNS void
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, app AS $$
DECLARE
  v_expected constant int[] := ARRAY[1,2,3,4,5,6,8,9,10,12,15,16,20,25];
  v_bands constant text[] := ARRAY['band_top_priority','band_action','band_consider','band_accept'];
  b text;
  v_all int[] := ARRAY[]::int[];
  v_arr int[];
  v_touched boolean := false;
BEGIN
  IF jsonb_typeof(p_override) <> 'object' THEN
    RAISE EXCEPTION 'risk_band の override はオブジェクトでなければならない';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(p_override) k WHERE k <> ALL(v_bands)) THEN
    RAISE EXCEPTION 'risk_band の override に想定外のキーがある: %',
      (SELECT string_agg(k, ', ') FROM jsonb_object_keys(p_override) k WHERE k <> ALL(v_bands));
  END IF;

  FOREACH b IN ARRAY v_bands LOOP
    IF p_override ? b THEN
      v_touched := true;
      IF jsonb_typeof(p_override -> b) <> 'array' THEN
        RAISE EXCEPTION '% は配列でなければならない', b;
      END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_override -> b) e
                  WHERE jsonb_typeof(e) <> 'number') THEN
        RAISE EXCEPTION '% に数値でない要素がある', b;
      END IF;
      v_arr := app.jsonb_to_int_array(p_override -> b);
      IF cardinality(v_arr) = 0 THEN
        RAISE EXCEPTION '% が空。区分を空にはできない', b;
      END IF;
      IF EXISTS (SELECT 1 FROM unnest(v_arr) x WHERE NOT (x = ANY(v_expected))) THEN
        RAISE EXCEPTION '% に 5x5 では起こり得ない値がある', b;
      END IF;
      v_all := v_all || v_arr;
    ELSE
      EXECUTE format('SELECT c.%I FROM catalog.risk_criteria_default c
                        JOIN app.tenants t ON t.dom_version_id = c.dom_version_id
                       WHERE t.id = $1', b)
        INTO v_arr USING p_tenant;
      IF v_arr IS NULL THEN
        RAISE EXCEPTION 'テナントの標準リスク基準が見つからない';
      END IF;
      v_all := v_all || v_arr;
    END IF;
  END LOOP;

  IF NOT v_touched THEN
    RAISE EXCEPTION 'risk_band の逸脱なのに上書きする区分が 1 つも無い';
  END IF;
  IF (SELECT count(DISTINCT x) FROM unnest(v_all) x) <> 14
     OR cardinality(v_all) <> 14 THEN
    RAISE EXCEPTION '上書き後の区分が 14 値を過不足なく覆っていない（重複または欠落）';
  END IF;
END $$;
ALTER FUNCTION app.check_risk_band_override(uuid, jsonb) OWNER TO schema_owner;

CREATE OR REPLACE FUNCTION app.validate_deviation_override() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.kind = 'risk_band' THEN
    PERFORM app.check_risk_band_override(NEW.tenant_id, NEW.override);
  END IF;
  RETURN NEW;
END $$;

-- ------------------------------------------------------------------
-- 1. 適用前に、既存の逸脱が新しい検査を通るか確かめる。
--    通らない行があれば ID を出して中断する（黙って残さない）。
-- ------------------------------------------------------------------
DO $$
DECLARE r record; v_bad text := '';
BEGIN
  FOR r IN SELECT id, tenant_id, override FROM app.deviations
            WHERE kind = 'risk_band' AND status IN ('requested','active') LOOP
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
-- 2. 検査を override / kind / tenant_id が動いたときだけに絞る。
--    0016 は全 UPDATE で発火するため、expire_deviations() の
--    status 更新まで検査に巻き込まれて落ち得た。
-- ------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_validate_deviation_override ON app.deviations;

CREATE TRIGGER trg_validate_deviation_override_ins
  BEFORE INSERT ON app.deviations
  FOR EACH ROW EXECUTE FUNCTION app.validate_deviation_override();

CREATE TRIGGER trg_validate_deviation_override_upd
  BEFORE UPDATE ON app.deviations
  FOR EACH ROW
  WHEN (NEW.override   IS DISTINCT FROM OLD.override
     OR NEW.kind       IS DISTINCT FROM OLD.kind
     OR NEW.tenant_id  IS DISTINCT FROM OLD.tenant_id)
  EXECUTE FUNCTION app.validate_deviation_override();

-- ------------------------------------------------------------------
-- 3. 標準リスク基準（catalog）を発行後は不変にする。
--    部分 override は「指定しなかった区分は標準値」を前提に 14 値の覆いを
--    検査している。標準側が後から動くと、その前提が崩れたことに誰も気づけない。
--    区分を変えたいときは DOM 版を上げる（設計書 1.11.5 のフィードバック機構）。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION catalog.risk_criteria_default_immutable() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, catalog AS $$
BEGIN
  IF NEW.impact_sec_formula IS DISTINCT FROM OLD.impact_sec_formula
     OR NEW.band_top_priority IS DISTINCT FROM OLD.band_top_priority
     OR NEW.band_action       IS DISTINCT FROM OLD.band_action
     OR NEW.band_consider     IS DISTINCT FROM OLD.band_consider
     OR NEW.band_accept       IS DISTINCT FROM OLD.band_accept THEN
    -- テナントが 1 つでもこの DOM 版を使っていたら動かさない
    IF EXISTS (SELECT 1 FROM app.tenants t WHERE t.dom_version_id = OLD.dom_version_id) THEN
      RAISE EXCEPTION
        '配布済みの DOM 版の標準リスク基準は変更できない。新しい DOM 版を作ること';
    END IF;
  END IF;
  RETURN NEW;
END $$;
ALTER FUNCTION catalog.risk_criteria_default_immutable() OWNER TO schema_owner;

CREATE TRIGGER trg_risk_criteria_default_immutable
  BEFORE UPDATE ON catalog.risk_criteria_default
  FOR EACH ROW EXECUTE FUNCTION catalog.risk_criteria_default_immutable();

-- テナントの DOM 版を動かすときも、有効な risk_band 逸脱が残っていたら止める
-- （新しい標準との組合せで 14 値の覆いが崩れ得るため、先に逸脱を畳ませる）。
CREATE OR REPLACE FUNCTION app.guard_tenant_dom_version() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.dom_version_id IS DISTINCT FROM OLD.dom_version_id
     AND EXISTS (SELECT 1 FROM app.deviations d
                  WHERE d.tenant_id = NEW.id AND d.kind = 'risk_band'
                    AND d.status = 'active') THEN
    RAISE EXCEPTION
      '有効な risk_band 逸脱があるテナントの DOM 版は切り替えられない。'
      ' 先に逸脱を取り下げるか失効させること';
  END IF;
  RETURN NEW;
END $$;
ALTER FUNCTION app.guard_tenant_dom_version() OWNER TO schema_owner;

CREATE TRIGGER trg_guard_tenant_dom_version
  BEFORE UPDATE ON app.tenants
  FOR EACH ROW EXECUTE FUNCTION app.guard_tenant_dom_version();

-- ------------------------------------------------------------------
-- 4. valid_to は「開いている版を閉じる」一方向だけ許す。
--    0016 は valid_to を見ていなかったので、閉じた版を NULL に戻して
--    復活させたり、終了日を後からずらしたりできた（自分のテストが踏んでいた）。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.risk_criteria_immutable() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.impact_sec_formula IS DISTINCT FROM OLD.impact_sec_formula
     OR NEW.band_top_priority IS DISTINCT FROM OLD.band_top_priority
     OR NEW.band_action       IS DISTINCT FROM OLD.band_action
     OR NEW.band_consider     IS DISTINCT FROM OLD.band_consider
     OR NEW.band_accept       IS DISTINCT FROM OLD.band_accept
     OR NEW.dom_version_id    IS DISTINCT FROM OLD.dom_version_id
     OR NEW.valid_from        IS DISTINCT FROM OLD.valid_from THEN
    RAISE EXCEPTION
      'risk_criteria は凍結された版。算定式・区分・適用開始日は書き換えられない。'
      ' 変更するときは valid_to を入れて閉じ、新しい版の行を作ること';
  END IF;
  -- 閉じた版を開き直せない／終了日を動かせない
  IF OLD.valid_to IS NOT NULL AND NEW.valid_to IS DISTINCT FROM OLD.valid_to THEN
    RAISE EXCEPTION '閉じた基準版の valid_to は変更できない（開き直し・日付の付け替えは不可）';
  END IF;
  IF NEW.valid_to IS NOT NULL AND NEW.valid_to <= OLD.valid_from THEN
    RAISE EXCEPTION 'valid_to は valid_from より後でなければならない';
  END IF;
  RETURN NEW;
END $$;

-- ------------------------------------------------------------------
-- 5. 基準版は消せない（履歴。過去時点の再現に要る）。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.risk_criteria_no_delete() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  RAISE EXCEPTION 'risk_criteria は削除できない（過去時点の再現に必要な履歴）';
END $$;
ALTER FUNCTION app.risk_criteria_no_delete() OWNER TO schema_owner;

CREATE TRIGGER trg_risk_criteria_no_delete
  BEFORE DELETE ON app.risk_criteria
  FOR EACH ROW EXECUTE FUNCTION app.risk_criteria_no_delete();

REVOKE DELETE ON app.risk_criteria FROM app_rw;
