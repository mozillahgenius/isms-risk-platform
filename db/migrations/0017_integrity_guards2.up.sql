-- 0017 Close holes in the checks added in 0016.
--   1. It could be applied while overlooking existing invalid deviations
--   2. The check ran on every UPDATE, so even expiry processing could fail as collateral damage
--   3. If the standard criteria / DOM version changed later, combinations with partial overrides would break
--   4. A frozen criteria version could be "closed and then reopened"
--   5. Criteria versions could be DELETEd

-- ------------------------------------------------------------------
-- 0. Make the check body a standalone function callable independently of the trigger.
--    Otherwise we can't verify before applying whether "existing rows pass this check".
--    The 0016 trigger function now just calls this function.
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
-- 1. Before applying, verify that existing deviations pass the new check.
--    If any row fails, print its ID and abort (don't silently leave it).
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
-- 2. Restrict the check to when override / kind / tenant_id change.
--    0016 fired on every UPDATE, so even the status update in
--    expire_deviations() got caught up in the check and could fail.
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
-- 3. Make the standard risk criteria (catalog) immutable once published.
--    Partial overrides are checked for covering all 14 values on the premise that
--    "unspecified bands take the standard values". If the standard side changed later, nobody would notice the premise broke.
--    To change bands, bump the DOM version (the feedback mechanism in design doc 1.11.5).
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION catalog.risk_criteria_default_immutable() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, catalog AS $$
BEGIN
  IF NEW.impact_sec_formula IS DISTINCT FROM OLD.impact_sec_formula
     OR NEW.band_top_priority IS DISTINCT FROM OLD.band_top_priority
     OR NEW.band_action       IS DISTINCT FROM OLD.band_action
     OR NEW.band_consider     IS DISTINCT FROM OLD.band_consider
     OR NEW.band_accept       IS DISTINCT FROM OLD.band_accept THEN
    -- Don't change it if even one tenant uses this DOM version
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

-- Also block changing a tenant's DOM version while active risk_band deviations remain
-- (the 14-value coverage could break in combination with the new standard, so have the deviations wound down first).
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
-- 4. Allow valid_to changes only in one direction: "closing an open version".
--    0016 didn't look at valid_to, so a closed version could be revived by setting it back to NULL,
--    or its end date shifted afterwards (our own test was doing this).
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
  -- A closed version can't be reopened / its end date can't be moved
  IF OLD.valid_to IS NOT NULL AND NEW.valid_to IS DISTINCT FROM OLD.valid_to THEN
    RAISE EXCEPTION '閉じた基準版の valid_to は変更できない（開き直し・日付の付け替えは不可）';
  END IF;
  IF NEW.valid_to IS NOT NULL AND NEW.valid_to <= OLD.valid_from THEN
    RAISE EXCEPTION 'valid_to は valid_from より後でなければならない';
  END IF;
  RETURN NEW;
END $$;

-- ------------------------------------------------------------------
-- 5. Criteria versions can't be deleted (history; needed to reproduce past states).
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
