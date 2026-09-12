-- 0002 catalog: DOM skeleton (first half of design doc 2.4)
-- dom_versions → roles_default → asset_classes_default
--   → calendar_events_default → risk_criteria_default → policies_default

CREATE TABLE catalog.dom_versions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version      text NOT NULL UNIQUE,               -- '2026.1'
  released_at  timestamptz NOT NULL,
  changelog    text NOT NULL,
  is_current   boolean NOT NULL DEFAULT false
);
CREATE UNIQUE INDEX dom_versions_one_current ON catalog.dom_versions (is_current) WHERE is_current;

CREATE TABLE catalog.roles_default (
  key         text PRIMARY KEY
                CHECK (key IN ('ciso','secretariat','risk_owner','auditor','employee')),
  name_ja     text NOT NULL,
  description text NOT NULL,
  sort_order  smallint NOT NULL
);

CREATE TABLE catalog.asset_classes_default (
  key          text PRIMARY KEY
                 CHECK (key IN ('top_secret','confidential','internal','public')),
  name_ja      text NOT NULL,
  rank         smallint NOT NULL,                  -- 4=top secret ... 1=public
  external_share_policy text NOT NULL
                 CHECK (external_share_policy IN ('forbidden','approval_required','allowed')),
  UNIQUE (rank)
);

CREATE TABLE catalog.risk_criteria_default (
  dom_version_id uuid NOT NULL REFERENCES catalog.dom_versions(id),
  impact_sec_formula text NOT NULL DEFAULT 'max_cia'
                 CHECK (impact_sec_formula IN ('max_cia','avg_cia')),
  -- Acceptance bands. Hold the 14 possible values as a set (design doc 1.5.2)
  band_top_priority int[] NOT NULL DEFAULT '{15,16,20,25}',
  band_action       int[] NOT NULL DEFAULT '{8,9,10,12}',
  band_consider     int[] NOT NULL DEFAULT '{3,4,5,6}',
  band_accept       int[] NOT NULL DEFAULT '{1,2}',
  due_days_top_priority smallint NOT NULL DEFAULT 30,
  due_days_action       smallint NOT NULL DEFAULT 90,
  PRIMARY KEY (dom_version_id),
  -- Subqueries can't be written in CHECK, so express it via array length
  CHECK (cardinality(band_top_priority) + cardinality(band_action)
       + cardinality(band_consider)     + cardinality(band_accept) = 14)
);

-- "Covers the 14 values exactly with no duplicates" can't be written as a CHECK, so a trigger checks it
CREATE OR REPLACE FUNCTION catalog.validate_risk_bands() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, catalog AS $$
DECLARE v_all int[]; v_expected int[] := ARRAY[1,2,3,4,5,6,8,9,10,12,15,16,20,25];
BEGIN
  v_all := NEW.band_top_priority || NEW.band_action || NEW.band_consider || NEW.band_accept;
  IF (SELECT count(DISTINCT x) FROM unnest(v_all) x) <> 14 THEN
    RAISE EXCEPTION 'risk bands contain duplicates';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_all) x WHERE NOT (x = ANY(v_expected))) THEN
    RAISE EXCEPTION 'risk bands contain values that 5x5 cannot produce';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_validate_risk_bands
  BEFORE INSERT OR UPDATE ON catalog.risk_criteria_default
  FOR EACH ROW EXECUTE FUNCTION catalog.validate_risk_bands();

CREATE TABLE catalog.calendar_events_default (
  key            text PRIMARY KEY,
  name_ja        text NOT NULL,
  cadence        text NOT NULL
                   CHECK (cadence IN ('daily','weekly','monthly','quarterly','semiannual','annual','event')),
  offset_months  smallint,                         -- months from the start of the period (for annual/semiannual)
  owner_role     text NOT NULL REFERENCES catalog.roles_default(key),
  clause_ref     text,                             -- '9.2' etc.
  extendable     boolean NOT NULL DEFAULT true     -- whether cycle extension is allowed as a deviation
);

CREATE TABLE catalog.policies_default (
  key            text PRIMARY KEY,
  dom_version_id uuid NOT NULL REFERENCES catalog.dom_versions(id),
  title_ja       text NOT NULL,
  body_md        text NOT NULL,                    -- standard body
  clause_refs    text[] NOT NULL,
  sort_order     smallint NOT NULL
);
