-- 0009 app: 統制（設計書 2.8）
CREATE TABLE app.control_implementations (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL,
  control_id  uuid NOT NULL REFERENCES catalog.controls(id),
  applicability text NOT NULL DEFAULT 'applicable'   -- 既定は適用（設計書 1.10）
                  CHECK (applicability IN ('applicable','excluded')),
  rationale   text,                                  -- excluded では必須
  status      text NOT NULL DEFAULT 'not_started'
                  CHECK (status IN ('not_started','designing','operating','verified')),
  owner_user_id uuid,
  valid_from  date NOT NULL DEFAULT current_date, valid_to date,
  recorded_from timestamptz NOT NULL DEFAULT now(), recorded_until timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id),
  CHECK (applicability <> 'excluded' OR length(btrim(coalesce(rationale,''))) > 0),
  CHECK (valid_to IS NULL OR valid_to > valid_from)
);
CREATE UNIQUE INDEX control_implementations_current
  ON app.control_implementations (tenant_id, control_id)
  WHERE valid_to IS NULL AND recorded_until IS NULL;

CREATE TABLE app.risk_control_links (
  tenant_id uuid NOT NULL, risk_scenario_id uuid NOT NULL, control_id uuid NOT NULL,
  PRIMARY KEY (tenant_id, risk_scenario_id, control_id),
  FOREIGN KEY (tenant_id, risk_scenario_id) REFERENCES app.risk_scenarios(tenant_id, id),
  FOREIGN KEY (control_id) REFERENCES catalog.controls(id)
);

-- 主キーに式は書けないため、id を立てて一意制約を部分インデックスで表現する
CREATE TABLE app.control_evidence_links (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL,
  control_id  uuid NOT NULL REFERENCES catalog.controls(id),
  evidence_id uuid,
  check_key   text REFERENCES catalog.checks(key),
  PRIMARY KEY (tenant_id, id),
  CHECK (num_nonnulls(evidence_id, check_key) = 1)   -- どちらか一方だけ
);
CREATE UNIQUE INDEX control_evidence_links_by_evidence
  ON app.control_evidence_links (tenant_id, control_id, evidence_id)
  WHERE evidence_id IS NOT NULL;
CREATE UNIQUE INDEX control_evidence_links_by_check
  ON app.control_evidence_links (tenant_id, control_id, check_key)
  WHERE check_key IS NOT NULL;
