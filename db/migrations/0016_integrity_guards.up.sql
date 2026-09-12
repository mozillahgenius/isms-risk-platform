-- 0016 Validation of deviation override values, and immutability of risk criteria versions.
--
-- Added under a new number instead of rewriting 0013 / 0008 directly. In already-applied environments,
-- rewriting an existing migration is rejected by the checksum check (scripts/migrate.sh), so
-- fixes must always ship as a subsequent migration.

-- ------------------------------------------------------------------
-- 1. Validate deviation overrides
--
-- 0013 accepted override as plain jsonb, so even values like `{"band_accept":[99]}`,
-- impossible in a 5x5, could be registered. app.effective_risk_criteria
-- returns them as-is as "effective criteria", which breaks acceptance decisions.
-- Also, non-array values silently fall back to the standard values via coalesce (the error is invisible).
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

  -- Don't silently ignore unknown keys (a typo would remain as a "deviation that has no effect")
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
      -- Unspecified bands use the standard values as-is (the view's coalesce).
      -- Add the standard values here too, so coverage can be checked.
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

  -- The 4 bands together must cover the 14 values exactly, with no duplicates
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
-- 2. Make risk criteria versions immutable
--
-- app.risk_criteria is "a frozen version of the criteria effective for the tenant" (design doc 2.7).
-- Yet the formula and bands could be UPDATEd afterwards, and existing risk_assessments are
-- not re-validated, so stored impact_sec and the formula would remain inconsistent.
-- Versions are meant to be recreated (close valid_to and create a new row), so rewriting their contents is forbidden.
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
