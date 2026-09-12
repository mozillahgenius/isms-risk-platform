-- 0013 app: deviations (design doc 2.5 / 1.11) and the view resolving effective risk criteria

CREATE TABLE app.deviations (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  kind          text NOT NULL CHECK (kind IN (
                  'risk_band','check_disable','check_threshold',
                  'calendar_extend','policy_edit')),
  target_key    text NOT NULL,                     -- key on the catalog side
  override      jsonb NOT NULL,                    -- value after override
  reason        text NOT NULL CHECK (length(btrim(reason)) > 0),
  compensating_control text,                       -- required for check_disable
  status        text NOT NULL DEFAULT 'requested'
                  CHECK (status IN ('requested','active','expired','withdrawn','rejected')),
  requested_by  uuid NOT NULL, requested_at timestamptz NOT NULL DEFAULT now(),
  approved_by   uuid,          approved_at  timestamptz,
  expires_at    timestamptz,                       -- required when active
  withdrawn_at  timestamptz,
  weight        numeric(4,1) NOT NULL,             -- weight for the standard conformance score (design doc 1.12)
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),

  CHECK (kind <> 'check_disable' OR length(btrim(coalesce(compensating_control,''))) > 0),
  -- approved_at is required too. The design doc only requires approved_by and expires_at, but
  -- if approved_at is NULL the expiry-cap CHECK below becomes a NULL comparison, and although
  -- "expiry is required" the cap never applies (NULL passes a CHECK).
  CHECK (status <> 'active'
         OR (approved_by IS NOT NULL AND approved_at IS NOT NULL AND expires_at IS NOT NULL)),
  CHECK (approved_at IS NULL OR expires_at IS NULL OR expires_at > approved_at),
  -- expiry cap (design doc 1.11.3)
  CHECK (status <> 'active' OR expires_at <= approved_at + CASE kind
           WHEN 'check_disable'   THEN interval '180 days'
           WHEN 'check_threshold' THEN interval '180 days'
           ELSE interval '365 days' END)
);
CREATE INDEX deviations_active
  ON app.deviations (tenant_id, kind, target_key) WHERE status = 'active';

-- Risk criteria deviations: "one at a time per tenant".
-- Allowing several active ones makes effective_risk_criteria return multiple rows for a tenant,
-- leaving it undecided which criteria are effective (the design doc's view ignores target_key).
CREATE UNIQUE INDEX deviations_one_active_risk_band
  ON app.deviations (tenant_id)
  WHERE kind = 'risk_band' AND status = 'active';

-- Move expired ones from active → expired daily (automatic return to standard; acceptance #4)
CREATE OR REPLACE FUNCTION app.expire_deviations() RETURNS int
LANGUAGE sql SET search_path = pg_catalog, app AS $$
  WITH x AS (
    UPDATE app.deviations SET status = 'expired'
    WHERE status = 'active' AND expires_at <= now() RETURNING 1
  ) SELECT count(*)::int FROM x;
$$;
ALTER FUNCTION app.expire_deviations() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.expire_deviations() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.expire_deviations() TO app_rw;

-- ------------------------------------------------------------------
-- Effective settings must always be resolved through this view (if the app reads
-- catalog directly, it behaves as if deviations did not exist).
--
-- Two fixes relative to design doc 2.5 (rationale in docs/DECISIONS.md D-03):
--   1. Set security_invoker = true explicitly. By default (evaluated with definer rights)
--      the underlying tables are read with the view owner's rights, not the caller's, bypassing RLS.
--   2. The design doc writes (d.override->>'band_top_priority')::int[], but
--      ->> returns a JSON array as the string '[15, 16]', which cannot be cast to int[]
--      (PostgreSQL array literals look like '{15,16}').
--      The array is built via jsonb_array_elements_text instead.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.jsonb_to_int_array(p jsonb) RETURNS int[]
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT CASE
           WHEN p IS NULL OR jsonb_typeof(p) <> 'array' THEN NULL
           ELSE ARRAY(SELECT jsonb_array_elements_text(p)::int)
         END
$$;
ALTER FUNCTION app.jsonb_to_int_array(jsonb) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.jsonb_to_int_array(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.jsonb_to_int_array(jsonb) TO app_rw, app_ro;

CREATE VIEW app.effective_risk_criteria WITH (security_invoker = true) AS
SELECT t.id AS tenant_id,
       coalesce(app.jsonb_to_int_array(d.override->'band_top_priority'), c.band_top_priority)
         AS band_top_priority,
       coalesce(app.jsonb_to_int_array(d.override->'band_action'),       c.band_action)
         AS band_action,
       coalesce(app.jsonb_to_int_array(d.override->'band_consider'),     c.band_consider)
         AS band_consider,
       coalesce(app.jsonb_to_int_array(d.override->'band_accept'),       c.band_accept)
         AS band_accept,
       c.impact_sec_formula,
       (d.id IS NOT NULL) AS is_deviated
FROM app.tenants t
JOIN catalog.risk_criteria_default c ON c.dom_version_id = t.dom_version_id
LEFT JOIN app.deviations d
  ON d.tenant_id = t.id AND d.kind = 'risk_band' AND d.status = 'active';
ALTER VIEW app.effective_risk_criteria OWNER TO schema_owner;
GRANT SELECT ON app.effective_risk_criteria TO app_rw, app_ro;
