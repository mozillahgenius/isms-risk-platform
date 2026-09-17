-- 0016 逸脱の上書き値の検証と、リスク基準版の不変化。
--
-- 0013 / 0008 を直接書き換えず新しい番号で足す。適用済みの環境では
-- 既存 migration の書き換えが checksum 検査で拒否される（scripts/migrate.sh）ため、
-- 修正は必ず後続の migration として届ける。

-- ------------------------------------------------------------------
-- 1. 逸脱の override を検証する
--
-- 0013 は override を素の jsonb で受けており、`{"band_accept":[99]}` のような
-- 5x5 では起こり得ない値でも登録できた。app.effective_risk_criteria は
-- それをそのまま「有効な基準」として返すため、受容判断が壊れる。
-- また配列でない値は coalesce で黙って標準値へ落ちる（誤りが見えない）。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.validate_deviation_override() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  v_expected constant int[] := ARRAY[1,2,3,4,5,6,8,9,10,12,15,16,20,25];
  v_bands constant text[] := ARRAY['band_top_priority','band_action','band_consider','band_accept'];
  b text;
  v_all int[] := ARRAY[]::int[];
  v_arr int[];
  v_touched boolean := false;
BEGIN
  IF NEW.kind <> 'risk_band' THEN
    RETURN NEW;
  END IF;
  IF jsonb_typeof(NEW.override) <> 'object' THEN
    RAISE EXCEPTION 'risk_band の override はオブジェクトでなければならない';
  END IF;

  -- 知らないキーを黙って無視しない（誤字が「効いていない逸脱」として残る）
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(NEW.override) k
              WHERE k <> ALL(v_bands)) THEN
    RAISE EXCEPTION 'risk_band の override に想定外のキーがある: %',
      (SELECT string_agg(k, ', ') FROM jsonb_object_keys(NEW.override) k
        WHERE k <> ALL(v_bands));
  END IF;

  FOREACH b IN ARRAY v_bands LOOP
    IF NEW.override ? b THEN
      v_touched := true;
      IF jsonb_typeof(NEW.override -> b) <> 'array' THEN
        RAISE EXCEPTION '% は配列でなければならない', b;
      END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(NEW.override -> b) e
                  WHERE jsonb_typeof(e) <> 'number') THEN
        RAISE EXCEPTION '% に数値でない要素がある', b;
      END IF;
      v_arr := app.jsonb_to_int_array(NEW.override -> b);
      IF cardinality(v_arr) = 0 THEN
        RAISE EXCEPTION '% が空。区分を空にはできない', b;
      END IF;
      IF EXISTS (SELECT 1 FROM unnest(v_arr) x WHERE NOT (x = ANY(v_expected))) THEN
        RAISE EXCEPTION '% に 5x5 では起こり得ない値がある', b;
      END IF;
      v_all := v_all || v_arr;
    ELSE
      -- 指定されなかった区分は標準値がそのまま使われる（ビューの coalesce）。
      -- 覆いの検査をするため、ここでも標準値を足しておく。
      EXECUTE format('SELECT c.%I FROM catalog.risk_criteria_default c
                        JOIN app.tenants t ON t.dom_version_id = c.dom_version_id
                       WHERE t.id = $1', b)
        INTO v_arr USING NEW.tenant_id;
      IF v_arr IS NULL THEN
        RAISE EXCEPTION 'テナントの標準リスク基準が見つからない';
      END IF;
      v_all := v_all || v_arr;
    END IF;
  END LOOP;

  IF NOT v_touched THEN
    RAISE EXCEPTION 'risk_band の逸脱なのに上書きする区分が 1 つも無い';
  END IF;

  -- 4 区分を合わせて 14 値を過不足なく覆い、重複が無いこと
  IF (SELECT count(DISTINCT x) FROM unnest(v_all) x) <> 14
     OR cardinality(v_all) <> 14 THEN
    RAISE EXCEPTION '上書き後の区分が 14 値を過不足なく覆っていない（重複または欠落）';
  END IF;

  RETURN NEW;
END $$;
ALTER FUNCTION app.validate_deviation_override() OWNER TO schema_owner;

CREATE TRIGGER trg_validate_deviation_override
  BEFORE INSERT OR UPDATE ON app.deviations
  FOR EACH ROW EXECUTE FUNCTION app.validate_deviation_override();

-- ------------------------------------------------------------------
-- 2. リスク基準版を不変にする
--
-- app.risk_criteria は「テナントで有効な基準の版を凍結したもの」（設計書 2.7）。
-- ところが算定式やバンドを後から UPDATE でき、既存の risk_assessments は
-- 再検証されないため、保存済み impact_sec と算定式が食い違ったまま残る。
-- 版は作り直す（valid_to を閉じて新しい行を作る）ものなので、中身の書き換えを禁じる。
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
  RETURN NEW;
END $$;
ALTER FUNCTION app.risk_criteria_immutable() OWNER TO schema_owner;

CREATE TRIGGER trg_risk_criteria_immutable
  BEFORE UPDATE ON app.risk_criteria
  FOR EACH ROW EXECUTE FUNCTION app.risk_criteria_immutable();
