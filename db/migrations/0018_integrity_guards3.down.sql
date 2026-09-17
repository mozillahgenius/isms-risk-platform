-- 0018 の巻き戻し（0017 の状態へ戻す）
DROP POLICY IF EXISTS ctx_deviation_lookup ON app.deviations;

CREATE OR REPLACE FUNCTION catalog.risk_criteria_default_immutable() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, catalog AS $$
BEGIN
  IF NEW.impact_sec_formula IS DISTINCT FROM OLD.impact_sec_formula
     OR NEW.band_top_priority IS DISTINCT FROM OLD.band_top_priority
     OR NEW.band_action       IS DISTINCT FROM OLD.band_action
     OR NEW.band_consider     IS DISTINCT FROM OLD.band_consider
     OR NEW.band_accept       IS DISTINCT FROM OLD.band_accept THEN
    IF EXISTS (SELECT 1 FROM app.tenants t WHERE t.dom_version_id = OLD.dom_version_id) THEN
      RAISE EXCEPTION
        '配布済みの DOM 版の標準リスク基準は変更できない。新しい DOM 版を作ること';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION app.validate_deviation_override() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.kind = 'risk_band' THEN
    PERFORM app.check_risk_band_override(NEW.tenant_id, NEW.override);
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_validate_deviation_override_upd ON app.deviations;
CREATE TRIGGER trg_validate_deviation_override_upd
  BEFORE UPDATE ON app.deviations
  FOR EACH ROW
  WHEN (NEW.override   IS DISTINCT FROM OLD.override
     OR NEW.kind       IS DISTINCT FROM OLD.kind
     OR NEW.tenant_id  IS DISTINCT FROM OLD.tenant_id)
  EXECUTE FUNCTION app.validate_deviation_override();

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
