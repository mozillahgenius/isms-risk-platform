-- 0019 の巻き戻し（0018 の advisory lock 方式へ戻す）
CREATE OR REPLACE FUNCTION app.validate_deviation_override() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.kind = 'risk_band' THEN
    PERFORM pg_advisory_xact_lock(hashtext('isms.tenant.' || NEW.tenant_id::text));
    PERFORM app.check_risk_band_override(NEW.tenant_id, NEW.override);
  END IF;
  RETURN NEW;
END $$;

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
