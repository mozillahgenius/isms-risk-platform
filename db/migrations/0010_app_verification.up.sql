-- 0010 app: verification and evidence (design doc 2.9 second half)
CREATE TABLE app.check_runs (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  check_key     text NOT NULL REFERENCES catalog.checks(key),
  started_at    timestamptz NOT NULL, finished_at timestamptz,
  result        text NOT NULL CHECK (result IN ('pass','fail','inconclusive','error')),
  coverage_ratio numeric(4,3),
  row_count     int,
  threshold_used numeric(3,2),                      -- effective threshold when relaxed by a deviation
  deviation_id  uuid,                               -- when a deviation was applied
  error_detail  text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  CHECK (result <> 'inconclusive' OR coverage_ratio IS NOT NULL)
);
CREATE INDEX check_runs_recent ON app.check_runs (tenant_id, check_key, started_at DESC);

CREATE TABLE app.evidences (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  kind          text NOT NULL CHECK (kind IN ('auto','semi_auto','manual')),
  title         text NOT NULL,
  object_key    text,                               -- opaque key (must not contain tenant_id)
  sha256        bytea, byte_size bigint,
  collected_at  timestamptz NOT NULL,
  freshness_days smallint NOT NULL,                 -- freshness criterion per control type
  state         text NOT NULL DEFAULT 'valid'
                  CHECK (state IN ('valid','expired','unobtainable','not_collected')),
  check_run_id  uuid,
  deleted_at    timestamptz,                        -- logical deletion
  purged_at     timestamptz,                        -- physical deletion on reaching the retention limit
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, check_run_id) REFERENCES app.check_runs(tenant_id, id),
  CHECK (kind <> 'auto' OR check_run_id IS NOT NULL)
);

-- The FK on exceptions.finding_id is added later because findings is created in 0011 (design doc 2.9 / 2.10)
CREATE TABLE app.exceptions (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL,
  finding_id  uuid NOT NULL,
  reason      text NOT NULL CHECK (length(btrim(reason)) > 0),
  compensating_control text NOT NULL CHECK (length(btrim(compensating_control)) > 0),
  approved_by uuid NOT NULL, approved_at timestamptz NOT NULL,
  expires_at  timestamptz NOT NULL,                 -- no indefinite expiry allowed
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  CHECK (expires_at > approved_at)
);
