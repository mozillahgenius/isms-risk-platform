-- M2: one ISO-scoped read model over the shared risk_scenario IDs.
-- Findings are never inferred from controls/audits: only this explicit bridge
-- attributes a finding to a risk scenario.
CREATE TABLE app.finding_risk_scenarios (
  tenant_id uuid NOT NULL,
  finding_id uuid NOT NULL,
  risk_scenario_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  PRIMARY KEY (tenant_id, finding_id, risk_scenario_id),
  FOREIGN KEY (tenant_id, finding_id)
    REFERENCES app.findings(tenant_id, id),
  FOREIGN KEY (tenant_id, risk_scenario_id)
    REFERENCES app.risk_scenarios(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by)
    REFERENCES app.users(tenant_id, id)
);
CREATE INDEX finding_risk_scenarios_by_risk
  ON app.finding_risk_scenarios (tenant_id, risk_scenario_id, finding_id);

ALTER TABLE app.finding_risk_scenarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.finding_risk_scenarios FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.finding_risk_scenarios FOR ALL TO app_rw
  USING (tenant_id = app.current_tenant())
  WITH CHECK (tenant_id = app.current_tenant());
CREATE POLICY tenant_read ON app.finding_risk_scenarios FOR SELECT TO app_ro
  USING (tenant_id = app.current_tenant());
REVOKE ALL ON app.finding_risk_scenarios FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.finding_risk_scenarios TO app_rw;
GRANT SELECT ON app.finding_risk_scenarios TO app_ro;

CREATE VIEW app.isms_risk_read_model WITH (security_invoker = true) AS
SELECT r.tenant_id,
       r.id AS risk_scenario_id,
       cia.id AS current_assessment_id,
       cia.status AS current_assessment_status,
       cia.prob AS current_probability,
       cia.confidentiality,
       cia.integrity,
       cia.availability,
       cia.impact_sec AS current_security_impact,
       cia.level_sec AS current_security_level,
       cia.impact_biz AS current_business_impact,
       cia.level_biz AS current_business_level,
       cia.assessed_at AS current_assessed_at,
       cia.valid_from AS current_valid_from,
       cia.valid_to AS current_valid_to,
       dev.id AS criterion_deviation_id,
       dev.status AS criterion_deviation_status,
       dev.expires_at AS criterion_deviation_expires_at,
       dev.reason AS criterion_deviation_reason,
       controls.controls,
       evidence.total_count AS evidence_total_count,
       evidence.valid_count AS evidence_valid_count,
       evidence.stale_count AS evidence_stale_count,
       evidence.expired_count AS evidence_expired_count,
       evidence.unobtainable_count AS evidence_unobtainable_count,
       evidence.not_collected_count AS evidence_not_collected_count,
       findings.findings,
       acceptance.id AS acceptance_id,
       acceptance.accepted_at,
       acceptance.accepted_by,
       acceptance.reason AS acceptance_reason,
       acceptance.residual_level AS acceptance_residual_level,
       acceptance.inherent_level AS acceptance_inherent_level,
       acceptance.evaluation_snapshot_id,
       acceptance.inherent_snapshot_id,
       snapshot_state.snapshot_count,
       CASE
         WHEN acceptance.id IS NULL THEN 'missing'
         WHEN acceptance.expected_version <> snapshot_state.snapshot_count THEN 'stale'
         WHEN residual.id IS NULL OR inherent.id IS NULL THEN 'stale'
         WHEN app.risk_evaluation_snapshot_sha256(residual) <> acceptance.evaluation_snapshot_sha256 THEN 'stale'
         WHEN app.risk_evaluation_snapshot_sha256(inherent) <> acceptance.inherent_snapshot_sha256 THEN 'stale'
         ELSE 'current'
       END AS acceptance_freshness
  FROM app.risk_scenarios r
  JOIN app.risk_scenario_frameworks iso
    ON iso.tenant_id = r.tenant_id
   AND iso.risk_scenario_id = r.id
   AND iso.framework_key = 'ISO27001:2022'
  LEFT JOIN LATERAL (
    SELECT a.*
      FROM app.risk_assessments a
     WHERE a.tenant_id = r.tenant_id
       AND a.risk_scenario_id = r.id
       AND a.recorded_until IS NULL
       AND a.valid_from <= (now() AT TIME ZONE 'Asia/Tokyo')::date
       AND (a.valid_to IS NULL OR a.valid_to > (now() AT TIME ZONE 'Asia/Tokyo')::date)
     ORDER BY a.assessed_at DESC, a.created_at DESC, a.id DESC
     LIMIT 1
  ) cia ON true
  LEFT JOIN app.risk_criteria criterion
    ON criterion.tenant_id = cia.tenant_id AND criterion.id = cia.risk_criteria_id
  LEFT JOIN app.deviations dev
    ON dev.tenant_id = criterion.tenant_id AND dev.id = criterion.deviation_id
  LEFT JOIN LATERAL (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'control_id', c.id,
             'code', c.code,
             'title', c.title_ja,
             'implementation_id', implementation.id,
             'applicability', implementation.applicability,
             'status', implementation.status,
             'rationale', implementation.rationale
           ) ORDER BY c.code, c.id), '[]'::jsonb) AS controls
      FROM app.risk_control_links rcl
      JOIN catalog.controls c ON c.id = rcl.control_id AND c.retired_at IS NULL
      JOIN catalog.control_frameworks cf
        ON cf.control_id = c.id AND cf.framework_key = 'ISO27001:2022'
      LEFT JOIN LATERAL (
        SELECT ci.id, ci.applicability, ci.status, ci.rationale
          FROM app.control_implementations ci
         WHERE ci.tenant_id = r.tenant_id
           AND ci.control_id = c.id
           AND ci.recorded_until IS NULL
           AND ci.valid_from <= (now() AT TIME ZONE 'Asia/Tokyo')::date
           AND (ci.valid_to IS NULL OR ci.valid_to > (now() AT TIME ZONE 'Asia/Tokyo')::date)
         ORDER BY ci.recorded_from DESC, ci.created_at DESC, ci.id DESC
         LIMIT 1
      ) implementation ON true
     WHERE rcl.tenant_id = r.tenant_id AND rcl.risk_scenario_id = r.id
  ) controls ON true
  LEFT JOIN LATERAL (
    SELECT count(*)::int AS total_count,
           count(*) FILTER (WHERE state = 'valid' AND fresh_until > now())::int AS valid_count,
           count(*) FILTER (WHERE state = 'valid' AND fresh_until <= now())::int AS stale_count,
           count(*) FILTER (WHERE state = 'expired')::int AS expired_count,
           count(*) FILTER (WHERE state = 'unobtainable')::int AS unobtainable_count,
           count(*) FILTER (WHERE state = 'not_collected')::int AS not_collected_count
      FROM (
        SELECT DISTINCT e.id, e.state,
               e.collected_at + make_interval(days => e.freshness_days) AS fresh_until
          FROM app.risk_control_links rcl
          JOIN catalog.control_frameworks cf
            ON cf.control_id = rcl.control_id AND cf.framework_key = 'ISO27001:2022'
          JOIN app.control_evidence_links cel
            ON cel.tenant_id = rcl.tenant_id AND cel.control_id = rcl.control_id
          JOIN app.evidences e
            ON e.tenant_id = cel.tenant_id AND e.id = cel.evidence_id
         WHERE rcl.tenant_id = r.tenant_id
           AND rcl.risk_scenario_id = r.id
           AND e.deleted_at IS NULL
           AND e.purged_at IS NULL
      ) distinct_evidence
  ) evidence ON true
  LEFT JOIN LATERAL (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', f.id,
             'source', f.source,
             'title', f.title,
             'severity', f.severity,
             'status', f.status,
             'detected_at', f.detected_at,
             'due_date', f.due_date
           ) ORDER BY f.detected_at DESC, f.id), '[]'::jsonb) AS findings
      FROM app.finding_risk_scenarios frs
      JOIN app.findings f ON f.tenant_id = frs.tenant_id AND f.id = frs.finding_id
     WHERE frs.tenant_id = r.tenant_id AND frs.risk_scenario_id = r.id
  ) findings ON true
  LEFT JOIN LATERAL (
    SELECT count(*)::int AS snapshot_count
      FROM app.risk_evaluation_snapshots s
     WHERE s.tenant_id = r.tenant_id AND s.risk_scenario_id = r.id
  ) snapshot_state ON true
  LEFT JOIN LATERAL (
    SELECT ra.*
      FROM app.risk_acceptances ra
     WHERE ra.tenant_id = r.tenant_id AND ra.risk_scenario_id = r.id
     ORDER BY ra.accepted_at DESC, ra.id DESC
     LIMIT 1
  ) acceptance ON true
  LEFT JOIN app.risk_evaluation_snapshots residual
    ON residual.tenant_id = acceptance.tenant_id AND residual.id = acceptance.evaluation_snapshot_id
  LEFT JOIN app.risk_evaluation_snapshots inherent
    ON inherent.tenant_id = acceptance.tenant_id AND inherent.id = acceptance.inherent_snapshot_id
 WHERE r.status = 'active';
ALTER VIEW app.isms_risk_read_model OWNER TO schema_owner;
GRANT SELECT ON app.isms_risk_read_model TO app_rw, app_ro;
GRANT EXECUTE ON FUNCTION app.risk_evaluation_snapshot_sha256(app.risk_evaluation_snapshots) TO app_ro;
