-- Rollback of 0017. Restores the 0016 state (one trigger, no valid_to check).
DROP TRIGGER IF EXISTS trg_risk_criteria_no_delete ON app.risk_criteria;
DROP FUNCTION IF EXISTS app.risk_criteria_no_delete();
GRANT DELETE ON app.risk_criteria TO app_rw;

DROP TRIGGER IF EXISTS trg_guard_tenant_dom_version ON app.tenants;
DROP FUNCTION IF EXISTS app.guard_tenant_dom_version();

DROP TRIGGER IF EXISTS trg_risk_criteria_default_immutable ON catalog.risk_criteria_default;
DROP FUNCTION IF EXISTS catalog.risk_criteria_default_immutable();

DROP TRIGGER IF EXISTS trg_validate_deviation_override_upd ON app.deviations;
DROP TRIGGER IF EXISTS trg_validate_deviation_override_ins ON app.deviations;
CREATE TRIGGER trg_validate_deviation_override
  BEFORE INSERT OR UPDATE ON app.deviations
  FOR EACH ROW EXECUTE FUNCTION app.validate_deviation_override();

-- Restore the 0016 version without the one-way valid_to check
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

-- Restore validate_deviation_override() to 0016's form "containing the check body", then
-- drop the helper added in 0017. In the reverse order, the trigger would be left in a broken state calling a
-- nonexistent function. Leaving the helper makes 0001's DROP SCHEMA app fail.
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
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(NEW.override) k WHERE k <> ALL(v_bands)) THEN
    RAISE EXCEPTION 'risk_band の override に想定外のキーがある';
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
  IF (SELECT count(DISTINCT x) FROM unnest(v_all) x) <> 14
     OR cardinality(v_all) <> 14 THEN
    RAISE EXCEPTION '上書き後の区分が 14 値を過不足なく覆っていない（重複または欠落）';
  END IF;
  RETURN NEW;
END $$;

DROP FUNCTION IF EXISTS app.check_risk_band_override(uuid, jsonb);
