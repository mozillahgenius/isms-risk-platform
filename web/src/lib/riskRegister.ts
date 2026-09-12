import 'server-only';

import { withTenant, withTenantActor, type TenantReadResult } from './tenant';

export const DEFAULT_FRAMEWORK = 'RISK-MANAGEMENT';

/**
 * Frameworks the register can be switched to.
 *
 * Only current frameworks are used as register tags. Keys not listed here fall back to the default.
 * Falling back shows the default register, so to **avoid it being misread as 0 items for the
 * specified framework**, callers display the normalized key on screen.
 */
export const REGISTER_FRAMEWORK_KEYS = ['RISK-MANAGEMENT', 'ISO27001:2022', 'IPO-KARTE'] as const;

export function normalizeFrameworkKey(value: string | string[] | undefined): string {
  const raw = Array.isArray(value) ? value[0] : value;
  return (REGISTER_FRAMEWORK_KEYS as readonly string[]).includes(raw ?? '')
    ? (raw as string)
    : DEFAULT_FRAMEWORK;
}

export type RegisterFramework = {
  key: string;
  name_ja: string;
  version: string;
  source_note: string | null;
};

export type AssetRow = {
  id: string;
  asset_key: string;
  name: string;
  asset_type: string;
  description: string;
  classification: string;
  classification_name: string;
  status: 'active' | 'retired';
  tags: string[];
  linked_risks: number;
  /** Managing department. The column has existed since 0027 but was not shown on screen. */
  owner_department_id: string | null;
  owner_department_name: string | null;
  /** Location (0061). Either something representable as a system, or not. */
  location_system_id: string | null;
  location_system_name: string | null;
  location_note: string;
};

/** Candidates offered in the asset registration form. */
export type DepartmentOption = { id: string; name: string };
export type SystemOption = { id: string; name: string; provider: string };

export type MeasureRow = {
  id: string;
  measure_key: string;
  name: string;
  summary: string;
  strategy: 'mitigate' | 'transfer' | 'avoid' | 'accept';
  status: 'planned' | 'in_progress' | 'done' | 'retired';
  tags: string[];
  linked_risks: number;
  // postgres.js returns numeric as strings. Do not cast to number
  // (added 2026-09-02; convert with Number() only right before display).
  budget_amount: string | null;
  resource_fte: string | null;
};

export type RiskRow = {
  id: string;
  risk_key: string;
  area: string;
  phase: number;
  theme: string;
  measure: string;
  frame: string;
  summary: string;
  status: 'active' | 'retired';
  tags: string[];
  assets: { id: string; asset_key: string; name: string; relation: string }[];
  snapshot_count: number;
  latest_level: number | null;
  latest_stage: SnapshotStage | null;
};

export type SnapshotStage = 'inherent' | 'before_measure' | 'after_measure';

export type SnapshotRow = {
  id: string;
  sha256: string;
  stage: SnapshotStage;
  // Fetched explicitly as a string with ::text (see the SELECT below). If postgres.js's
  // date parser returns a Date, a local-midnight Date becomes the previous day via toISOString(),
  // which can skew current/target decisions in JST (Codex review 2026-09-02).
  assessed_on: string;
  probability: number;
  impact: number;
  risk_level: number;
  rationale: string;
  source_note: string;
  measure_id: string | null;
  measure_name: string | null;
};

export type RiskWorkspaceData = {
  framework: RegisterFramework | null;
  frameworks: RegisterFramework[];
  assets: AssetRow[];
  measures: MeasureRow[];
  risks: RiskRow[];
  /** Choices for managing department and location (0061). */
  departments: DepartmentOption[];
  systems: SystemOption[];
};

export type RiskDetail = {
  risk: RiskRow;
  snapshots: SnapshotRow[];
  isms: IsoRiskReadModel | null;
  deviations: ManagementDeviationRow[];
  riskOwners: { id: string; display_name: string }[];
  approvedPolicies: ApprovedPolicyEvidence[];
};

export type ApprovedPolicyEvidence = {
  id: string;
  title: string;
  version: number;
  sha256: string;
};

export type ManagementDeviationRow = {
  id: string;
  title: string;
  description: string;
  corrective_action: string;
  owner_user_id: string;
  status: 'requested' | 'open' | 'closed' | 'expired' | 'rejected';
  due_at: string;
  expires_at: string;
  requested_by: string;
  close_note: string | null;
};

export type RiskViewerContext = {
  user_id: string;
  role_keys: string[];
};

export type IsoRiskControl = {
  control_id: string;
  code: string;
  title: string;
  implementation_id: string | null;
  applicability: 'applicable' | 'excluded' | null;
  status: 'not_started' | 'designing' | 'operating' | 'verified' | null;
  rationale: string | null;
};

export type IsoRiskFinding = {
  id: string;
  source: string;
  title: string;
  severity: string;
  status: string;
  detected_at: string;
  due_date: string | null;
};

export type IsoRiskReadModel = {
  current_assessment_id: string | null;
  current_assessment_status: string | null;
  current_probability: number | null;
  confidentiality: number | null;
  integrity: number | null;
  availability: number | null;
  current_security_impact: number | null;
  current_security_level: number | null;
  current_business_impact: number | null;
  current_business_level: number | null;
  current_assessed_at: string | null;
  current_valid_from: string | null;
  current_valid_to: string | null;
  criterion_deviation_id: string | null;
  criterion_deviation_status: string | null;
  criterion_deviation_expires_at: string | null;
  criterion_deviation_reason: string | null;
  controls: IsoRiskControl[];
  evidence_total_count: number;
  evidence_valid_count: number;
  evidence_stale_count: number;
  evidence_expired_count: number;
  evidence_unobtainable_count: number;
  evidence_not_collected_count: number;
  findings: IsoRiskFinding[];
  acceptance_id: string | null;
  accepted_at: string | null;
  accepted_by: string | null;
  acceptance_reason: string | null;
  acceptance_residual_level: number | null;
  acceptance_inherent_level: number | null;
  acceptance_expires_at: string | null;
  acceptance_expiry_status: 'legacy_unknown' | 'expired' | 'current' | null;
  evaluation_snapshot_id: string | null;
  inherent_snapshot_id: string | null;
  snapshot_count: number;
  acceptance_freshness: 'missing' | 'stale' | 'current';
};
export type IsoRemovalRequest = { id: string; entity_type: 'asset' | 'risk_scenario' | 'measure'; entity_id: string; expected_generation_id: string; status: string; expires_at: string; requested_by: string; approved_by: string | null };
export type IsoRelation = { entity_type: 'asset' | 'risk_scenario' | 'measure'; entity_id: string; generation_id: string };

const frameworkSql = async (sql: Parameters<Parameters<typeof withTenant>[0]>[0]) => {
  return sql<RegisterFramework[]>`
    SELECT key, name_ja, version, source_note
      FROM catalog.frameworks
     ORDER BY CASE key WHEN 'RISK-MANAGEMENT' THEN 1 WHEN 'ISO27001:2022' THEN 2 ELSE 3 END, key`;
};

export async function listRegisterFrameworks(): Promise<RegisterFramework[]> {
  const result = await withTenant(frameworkSql);
  return result.ok ? result.data : [];
}

export async function getRiskWorkspace(
  frameworkKey = DEFAULT_FRAMEWORK,
): Promise<TenantReadResult<RiskWorkspaceData>> {
  return withTenant(async (sql) => {
    const frameworks = await frameworkSql(sql);
    const framework = frameworks.find((item) => item.key === frameworkKey) ?? null;
    const assets = await sql<AssetRow[]>`
      SELECT a.id, a.asset_key, a.name, a.asset_type, a.description, a.classification,
             coalesce(ac.name_ja, a.classification) AS classification_name, a.status,
             coalesce(array_agg(DISTINCT af.framework_key) FILTER (WHERE af.framework_key IS NOT NULL), ARRAY[]::text[]) AS tags,
             (SELECT count(*)::int FROM app.risk_scenario_assets rsa
               WHERE rsa.tenant_id = a.tenant_id AND rsa.asset_id = a.id) AS linked_risks,
             a.owner_department_id::text, d.name AS owner_department_name,
             a.location_system_id::text, s.name AS location_system_name, a.location_note
        FROM app.assets a
        JOIN app.asset_frameworks selected_af
          ON selected_af.tenant_id = a.tenant_id AND selected_af.asset_id = a.id
         AND selected_af.framework_key = ${frameworkKey}
        LEFT JOIN app.asset_frameworks af
          ON af.tenant_id = a.tenant_id AND af.asset_id = a.id
        LEFT JOIN catalog.asset_classes_default ac ON ac.key = a.classification
        LEFT JOIN app.departments d
          ON d.tenant_id = a.tenant_id AND d.id = a.owner_department_id
        LEFT JOIN app.application_catalog s
          ON s.tenant_id = a.tenant_id AND s.id = a.location_system_id
       WHERE a.status = 'active'
       GROUP BY a.tenant_id, a.id, a.asset_key, a.name, a.asset_type, a.description,
                a.classification, ac.name_ja, a.status,
                a.owner_department_id, d.name,
                a.location_system_id, s.name, a.location_note
       ORDER BY a.asset_key, a.id`;
    const measures = await sql<MeasureRow[]>`
      SELECT m.id, m.measure_key, m.name, m.summary, m.strategy, m.status,
             m.budget_amount, m.resource_fte,
             coalesce(array_agg(DISTINCT mf.framework_key) FILTER (WHERE mf.framework_key IS NOT NULL), ARRAY[]::text[]) AS tags,
             (SELECT count(*)::int FROM app.risk_treatments rt
               WHERE rt.tenant_id = m.tenant_id AND rt.measure_id = m.id) AS linked_risks
        FROM app.measures m
        JOIN app.measure_frameworks selected_mf
          ON selected_mf.tenant_id = m.tenant_id AND selected_mf.measure_id = m.id
         AND selected_mf.framework_key = ${frameworkKey}
        LEFT JOIN app.measure_frameworks mf
          ON mf.tenant_id = m.tenant_id AND mf.measure_id = m.id
       WHERE m.status <> 'retired'
       GROUP BY m.tenant_id, m.id, m.measure_key, m.name, m.summary, m.strategy, m.status,
                m.budget_amount, m.resource_fte
       ORDER BY m.measure_key, m.id`;
    const risks = await listRisksForSql(sql, frameworkKey);
    const departments = await sql<DepartmentOption[]>`
      SELECT id, name FROM app.departments
       WHERE tenant_id = app.current_tenant() ORDER BY name`;
    // Only active systems can be chosen as a location. Allowing retired ones yields
    // a register where "information lives in a place that no longer exists".
    const systems = await sql<SystemOption[]>`
      SELECT id, name, provider FROM app.application_catalog
       WHERE tenant_id = app.current_tenant() AND status <> 'retired'
       ORDER BY name`;
    return { framework, frameworks, assets, measures, risks, departments, systems };
  });
}

async function listRisksForSql(
  sql: Parameters<Parameters<typeof withTenant>[0]>[0],
  frameworkKey: string,
): Promise<RiskRow[]> {
  return sql<RiskRow[]>`
    SELECT r.id, r.risk_key, r.area, r.phase, r.theme, r.measure, r.frame, r.summary, r.status,
           coalesce(array_agg(DISTINCT rf.framework_key) FILTER (WHERE rf.framework_key IS NOT NULL), ARRAY[]::text[]) AS tags,
           coalesce(jsonb_agg(DISTINCT jsonb_build_object(
             'id', a.id, 'asset_key', a.asset_key, 'name', a.name, 'relation', rsa.relation
           )) FILTER (WHERE a.id IS NOT NULL), '[]'::jsonb) AS assets,
           (SELECT count(*)::int FROM app.risk_evaluation_snapshots s
             WHERE s.tenant_id = r.tenant_id AND s.risk_scenario_id = r.id) AS snapshot_count,
           latest.risk_level AS latest_level,
           latest.stage AS latest_stage
      FROM app.risk_scenarios r
      JOIN app.risk_scenario_frameworks selected_rf
        ON selected_rf.tenant_id = r.tenant_id AND selected_rf.risk_scenario_id = r.id
       AND selected_rf.framework_key = ${frameworkKey}
      LEFT JOIN app.risk_scenario_frameworks rf
        ON rf.tenant_id = r.tenant_id AND rf.risk_scenario_id = r.id
      LEFT JOIN app.risk_scenario_assets rsa
        ON rsa.tenant_id = r.tenant_id AND rsa.risk_scenario_id = r.id
      LEFT JOIN app.assets a
        ON a.tenant_id = rsa.tenant_id AND a.id = rsa.asset_id
      LEFT JOIN LATERAL (
        -- assessed_on <= 今日(JST) のものだけを「現状」とする。将来日付は目標
        -- (未到達)であり、一覧の現状リスクレベルに混ぜると実際より軽く/重く
        -- 見える(2026-09-02 画面①実装時に発見。既存の欠陥、今回のtarget機能
        -- 追加とは別)。CURRENT_DATE はセッションのtimezone設定に依存するため、
        -- 明示的にAsia/Tokyoで計算する(Codexレビュー2026-09-02指摘: UI側の
        -- toISOString()はUTC基準なので、日付境界で1日ずれうる。両側をJSTへ統一)。
        SELECT s.risk_level, s.stage
          FROM app.risk_evaluation_snapshots s
         WHERE s.tenant_id = r.tenant_id AND s.risk_scenario_id = r.id
           AND s.assessed_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date
         ORDER BY s.assessed_on DESC, s.created_at DESC, s.id DESC
         LIMIT 1
      ) latest ON true
     WHERE r.status = 'active'
     GROUP BY r.tenant_id, r.id, r.risk_key, r.area, r.phase, r.theme, r.measure,
              r.frame, r.summary, r.status, latest.risk_level, latest.stage
     ORDER BY r.phase, r.area, r.risk_key, r.id`;
}

export async function getRiskDetail(
  id: string,
  frameworkKey = DEFAULT_FRAMEWORK,
): Promise<TenantReadResult<RiskDetail>> {
  return withTenant(async (sql) => {
    const risks = await listRisksForSql(sql, frameworkKey);
    const risk = risks.find((item) => item.id === id);
    if (!risk) throw new Error('risk not found');
    const [snapshots, ismsRows, deviations, riskOwners, approvedPolicies] = await Promise.all([
      sql<SnapshotRow[]>`
      SELECT s.id, app.risk_evaluation_snapshot_sha256(s) AS sha256,
             s.stage, s.assessed_on::text, s.probability, s.impact, s.risk_level,
             s.rationale, s.source_note, s.measure_id, m.name AS measure_name
        FROM app.risk_evaluation_snapshots s
        LEFT JOIN app.measures m
          ON m.tenant_id = s.tenant_id AND m.id = s.measure_id
       WHERE s.tenant_id = app.current_tenant() AND s.risk_scenario_id = ${id}::uuid
       ORDER BY s.assessed_on, s.created_at, s.id`,
      frameworkKey === 'ISO27001:2022'
        ? sql<IsoRiskReadModel[]>`
            SELECT model.*,
                   acceptance.expires_at::text AS acceptance_expires_at,
                   acceptance.expiry_status AS acceptance_expiry_status
              FROM app.isms_risk_read_model model
              LEFT JOIN app.risk_acceptance_status acceptance
                ON acceptance.tenant_id=model.tenant_id
               AND acceptance.id=model.acceptance_id
             WHERE model.tenant_id = app.current_tenant()
               AND model.risk_scenario_id = ${id}::uuid`
        : Promise.resolve([] as IsoRiskReadModel[]),
      sql<ManagementDeviationRow[]>`
        SELECT d.id,d.title,d.description,d.corrective_action,d.owner_user_id,
               d.status,d.due_at::text,d.expires_at::text,d.requested_by,d.close_note
          FROM app.management_deviations d
          JOIN app.management_deviation_risks link
            ON link.tenant_id=d.tenant_id AND link.deviation_id=d.id
         WHERE d.tenant_id=app.current_tenant() AND link.risk_scenario_id=${id}::uuid
         ORDER BY d.requested_at DESC,d.id DESC`,
      sql<{ id: string; display_name: string }[]>`
        SELECT DISTINCT u.id,u.display_name
          FROM app.users u JOIN app.memberships m
            ON m.tenant_id=u.tenant_id AND m.user_id=u.id
         WHERE u.tenant_id=app.current_tenant() AND u.status='active'
           AND m.role_key='risk_owner' AND m.revoked_at IS NULL
         ORDER BY u.display_name,u.id`,
      sql<ApprovedPolicyEvidence[]>`
        SELECT pv.id,p.title,pv.version,
               encode(digest(convert_to(pv.body_md,'UTF8'),'sha256'),'hex') AS sha256
          FROM app.policy_versions pv
          JOIN app.policies p ON p.tenant_id=pv.tenant_id AND p.id=pv.policy_id
         WHERE pv.tenant_id=app.current_tenant() AND pv.approved_at IS NOT NULL
           AND pv.effective_from<=(now() AT TIME ZONE 'Asia/Tokyo')::date
           AND (pv.superseded_at IS NULL OR pv.superseded_at>now())
         ORDER BY p.title,pv.version DESC,pv.id DESC`,
    ]);
    return { risk, snapshots, isms: ismsRows[0] ?? null, deviations, riskOwners, approvedPolicies };
  });
}

/** UI visibility only; database functions remain the authorization authority. */
export async function getRiskViewerContext(): Promise<TenantReadResult<RiskViewerContext | null>> {
  return withTenantActor(async (sql) => {
    const rows = await sql<RiskViewerContext[]>`
      SELECT u.id AS user_id,
             coalesce(
               array_agg(m.role_key ORDER BY m.role_key)
                 FILTER (WHERE m.revoked_at IS NULL),
               ARRAY[]::text[]
             ) AS role_keys
        FROM app.users u
        LEFT JOIN app.memberships m
          ON m.tenant_id = u.tenant_id AND m.user_id = u.id
       WHERE u.tenant_id = app.current_tenant()
         AND u.id = app.current_session_user()
         AND u.status = 'active'
       GROUP BY u.id`;
    return rows[0] ?? null;
  });
}

export async function getAssetsForFramework(frameworkKey: string): Promise<AssetRow[]> {
  const result = await getRiskWorkspace(frameworkKey);
  return result.ok ? result.data.assets : [];
}

export async function getMeasuresForFramework(frameworkKey: string): Promise<MeasureRow[]> {
  const result = await getRiskWorkspace(frameworkKey);
  return result.ok ? result.data.measures : [];
}

/** Server-only read model used by ISO removal forms/pending panel; RLS binds it to the signed tenant. */
export async function getIsoRemovalContext(): Promise<TenantReadResult<{ relations: IsoRelation[]; pending: IsoRemovalRequest[] }>> {
  return withTenant(async (sql) => ({
    relations: await sql<IsoRelation[]>`SELECT entity_type,entity_id,generation_id FROM app.framework_relation_origins WHERE framework_key='ISO27001:2022'`,
    pending: await sql<IsoRemovalRequest[]>`SELECT id,entity_type,entity_id,expected_generation_id,status,expires_at::text,requested_by,approved_by FROM app.iso_framework_removal_requests WHERE status IN ('requested','approved') ORDER BY expires_at,id`,
  }));
}
