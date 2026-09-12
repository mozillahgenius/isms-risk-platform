-- 0008 app: risk (design doc 2.7)
-- risk_criteria → risk_scenarios → risk_assessments → risk_treatments

CREATE TABLE app.risk_criteria (              -- criteria version effective for the tenant (freezes the result of resolving deviations)
  id             uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL,
  dom_version_id uuid NOT NULL REFERENCES catalog.dom_versions(id),
  -- Same CHECK as the catalog side. If this were free text, for an unknown formula
  -- validate_impact_sec below would expect NULL and an invalid impact_sec would slip through.
  impact_sec_formula text NOT NULL
                 CHECK (impact_sec_formula IN ('max_cia','avg_cia')),
  band_top_priority int[] NOT NULL, band_action int[] NOT NULL,
  band_consider     int[] NOT NULL, band_accept int[] NOT NULL,
  deviation_id   uuid,                             -- when derived from a deviation
  approved_by    uuid, approved_at timestamptz,
  valid_from     date NOT NULL, valid_to date,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE TABLE app.risk_scenarios (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  template_id   uuid REFERENCES catalog.risk_scenario_templates(id),
  domain        text NOT NULL, theme text NOT NULL, measure text NOT NULL,
  frame         text NOT NULL CHECK (frame IN ('管理可能性','精度','スピード')),
  summary       text NOT NULL,
  department_id uuid,                              -- risk owner's department
  asset_id      uuid,
  status        text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','retired')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, department_id) REFERENCES app.departments(tenant_id, id)
);
-- Business key of the register. Prevents duplicate registration of the same scenario (enforces on the DB side
-- the rule "a duplicate business key is an error" defined for the Phase0 round trip).
CREATE UNIQUE INDEX risk_scenarios_business_key
  ON app.risk_scenarios (tenant_id, domain, theme, measure, frame, summary)
  WHERE status = 'active';

CREATE TABLE app.risk_assessments (
  id               uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL,
  risk_scenario_id uuid NOT NULL,
  risk_criteria_id uuid NOT NULL,
  status           text NOT NULL DEFAULT 'draft'
                     CHECK (status IN ('draft','submitted','approved','superseded')),
  prob             smallint NOT NULL CHECK (prob BETWEEN 1 AND 5),
  confidentiality  smallint CHECK (confidentiality BETWEEN 1 AND 5),
  integrity        smallint CHECK (integrity       BETWEEN 1 AND 5),
  availability     smallint CHECK (availability    BETWEEN 1 AND 5),
  impact_sec       smallint CHECK (impact_sec BETWEEN 1 AND 5),
  impact_biz       smallint CHECK (impact_biz BETWEEN 1 AND 5),
  level_sec        smallint GENERATED ALWAYS AS (prob * impact_sec) STORED,
  level_biz        smallint GENERATED ALWAYS AS (prob * impact_biz) STORED,
  rationale        text,
  assessed_by      uuid NOT NULL, assessed_at timestamptz NOT NULL DEFAULT now(),
  approved_by      uuid,          approved_at timestamptz,
  valid_from       date        NOT NULL,
  valid_to         date,
  recorded_from    timestamptz NOT NULL DEFAULT now(),
  recorded_until   timestamptz,
  supersedes_id    uuid,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, risk_scenario_id) REFERENCES app.risk_scenarios(tenant_id, id),
  FOREIGN KEY (tenant_id, risk_criteria_id) REFERENCES app.risk_criteria(tenant_id, id),
  CHECK (valid_to       IS NULL OR valid_to       >  valid_from),
  CHECK (recorded_until IS NULL OR recorded_until >  recorded_from),
  CHECK (status <> 'approved' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
  CHECK (status <> 'approved' OR impact_sec IS NOT NULL OR impact_biz IS NOT NULL),
  EXCLUDE USING gist (
    tenant_id WITH =, risk_scenario_id WITH =,
    daterange(valid_from, valid_to, '[)') WITH &&
  ) WHERE (recorded_until IS NULL)
);
CREATE UNIQUE INDEX risk_assessments_current
  ON app.risk_assessments (tenant_id, risk_scenario_id)
  WHERE valid_to IS NULL AND recorded_until IS NULL;

-- The DB rejects impact_sec unless it matches the formula (default max_cia) (acceptance #13)
CREATE OR REPLACE FUNCTION app.validate_impact_sec() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE v_formula text; v_expected smallint;
BEGIN
  SELECT impact_sec_formula INTO v_formula
    FROM app.risk_criteria WHERE tenant_id = NEW.tenant_id AND id = NEW.risk_criteria_id;
  IF NEW.impact_sec IS NULL THEN RETURN NEW; END IF;
  IF NEW.confidentiality IS NULL OR NEW.integrity IS NULL OR NEW.availability IS NULL THEN
    RAISE EXCEPTION 'C/I/A are required when impact_sec is set';
  END IF;
  -- Without an ELSE, an unknown formula makes v_expected NULL, and the comparison below
  -- becomes NULL (neither false nor true), letting invalid values slip through. Always fail.
  v_expected := CASE v_formula
    WHEN 'max_cia' THEN greatest(NEW.confidentiality, NEW.integrity, NEW.availability)
    WHEN 'avg_cia' THEN ceil((NEW.confidentiality + NEW.integrity + NEW.availability)/3.0)
    ELSE NULL
  END;
  IF v_expected IS NULL THEN
    RAISE EXCEPTION 'unknown impact_sec_formula: %', coalesce(v_formula, '(criteria not found)');
  END IF;
  IF NEW.impact_sec <> v_expected THEN
    RAISE EXCEPTION 'impact_sec % does not match formula % (expected %)',
      NEW.impact_sec, v_formula, v_expected;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_validate_impact_sec BEFORE INSERT OR UPDATE ON app.risk_assessments
  FOR EACH ROW EXECUTE FUNCTION app.validate_impact_sec();

CREATE TABLE app.risk_treatments (
  id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  risk_assessment_id uuid NOT NULL,
  strategy           text NOT NULL CHECK (strategy IN ('mitigate','transfer','avoid','accept')),
  action_plan        text NOT NULL,
  owner_user_id      uuid, due_date date,
  prob_after         smallint CHECK (prob_after BETWEEN 1 AND 5),
  impact_sec_after   smallint CHECK (impact_sec_after BETWEEN 1 AND 5),
  impact_biz_after   smallint CHECK (impact_biz_after BETWEEN 1 AND 5),
  level_sec_after    smallint GENERATED ALWAYS AS (prob_after * impact_sec_after) STORED,
  level_biz_after    smallint GENERATED ALWAYS AS (prob_after * impact_biz_after) STORED,
  increase_reason    text,                          -- required when it increased on reassessment
  status             text NOT NULL DEFAULT 'planned'
                       CHECK (status IN ('planned','in_progress','done','cancelled')),
  approved_by        uuid, approved_at timestamptz,
  valid_from   date NOT NULL, valid_to date,
  recorded_from timestamptz NOT NULL DEFAULT now(), recorded_until timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, risk_assessment_id) REFERENCES app.risk_assessments(tenant_id, id),
  CHECK (valid_to       IS NULL OR valid_to       >  valid_from),
  CHECK (recorded_until IS NULL OR recorded_until >  recorded_from)
);

-- Within the same cycle, residual > inherent is rejected. An increase on reassessment requires a reason (acceptance #12)
CREATE OR REPLACE FUNCTION app.validate_residual() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE v_inherent smallint; v_same_cycle boolean; v_residual smallint;
BEGIN
  SELECT a.level_sec, (a.valid_from = NEW.valid_from) INTO v_inherent, v_same_cycle
    FROM app.risk_assessments a
   WHERE a.tenant_id = NEW.tenant_id AND a.id = NEW.risk_assessment_id;
  -- The design doc looks at NEW.level_sec_after, but generated columns are not yet computed
  -- at BEFORE-trigger time and are always NULL. = This check was being bypassed (measured).
  -- Compute it ourselves from the source columns. Rationale: docs/DECISIONS.md D-04.
  v_residual := NEW.prob_after * NEW.impact_sec_after;
  IF v_residual IS NULL OR v_inherent IS NULL THEN RETURN NEW; END IF;
  IF v_residual > v_inherent THEN
    IF v_same_cycle THEN
      RAISE EXCEPTION 'residual risk (%) cannot exceed inherent risk (%) in the same cycle',
        v_residual, v_inherent;
    ELSIF length(btrim(coalesce(NEW.increase_reason,''))) = 0 THEN
      RAISE EXCEPTION 'increase_reason is required when residual risk increases on reassessment';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_validate_residual BEFORE INSERT OR UPDATE ON app.risk_treatments
  FOR EACH ROW EXECUTE FUNCTION app.validate_residual();
