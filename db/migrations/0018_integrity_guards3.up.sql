-- 0018 Close holes in the checks from 0017.
--   1. The pre-check of existing rows saw 0 rows due to FORCE RLS, so it effectively checked nothing
--   2. Immutability of the standard criteria covered only some columns
--   3. No check ran when a deviation's status was set back to active
--   4. A DOM version switch and a deviation registration running concurrently could both pass without seeing each other

-- ------------------------------------------------------------------
-- 1. Let the definer (schema_owner) read app.deviations across tenants.
--
--    0017's pre-check runs as schema_owner, but app.deviations has
--    FORCE RLS and no schema_owner policy, so it **appeared to have 0 rows**.
--    The check "stop if there are existing invalid rows" succeeded without looking at anything.
--    Treat it the same as sessions / memberships / users / tenants.
-- ------------------------------------------------------------------
CREATE POLICY ctx_deviation_lookup ON app.deviations FOR SELECT TO schema_owner
  USING (true);

-- Check existing rows again (this time they are actually visible)
DO $$
DECLARE r record; v_bad text := '';
BEGIN
  FOR r IN SELECT id, tenant_id, override FROM app.deviations
            WHERE kind = 'risk_band'
              AND status IN ('requested','active','expired','withdrawn') LOOP
    -- Include expired / withdrawn too. Since there is a path to set status back to active,
    -- we don't accept "it's inactive now, so it may stay invalid".
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
-- 2. Extend immutability of the standard criteria to all columns.
--    0017 checked only the formula and the 4 bands, so the deadlines (due_days_*) and
--    the primary key dom_version_id could be changed.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION catalog.risk_criteria_default_immutable() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, catalog AS $$
BEGIN
  -- Re-pointing the primary key is always forbidden (it would change which DOM version the criteria belong to)
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
-- 3. Also check when status becomes active.
--    0017 fired only when override / kind / tenant_id changed, so
--    the path "set a row that expired while invalid back to active" was open.
--    Also serialize with DOM version switches via a per-tenant advisory lock (4).
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.validate_deviation_override() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.kind = 'risk_band' THEN
    -- Serialize per tenant. Without this, when a DOM version switch and
    -- a deviation registration run concurrently, neither sees the other's uncommitted rows,
    -- leaving the combination "new standard x override validated against the old standard".
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
-- 4. Take the same lock on the DOM version switch side too.
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
