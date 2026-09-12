import 'server-only';

import { withTenant, type TenantReadResult } from './tenant';

export type IncidentSeverity = 'critical' | 'high' | 'medium' | 'low';
export type IncidentStatus = 'open' | 'contained' | 'closed';

export type RiskOwnerOption = {
  user_id: string;
  display_name: string;
  department_name: string | null;
  // false: not currently an active risk_owner, but currently assigned to an existing incident,
  // so the value must not be removed from the options (Codex review 2026-09-02 finding:
  // restricting to active caused existing assignments to be silently cleared every time an edit was saved).
  is_active_pool: boolean;
};

export type RiskOption = {
  id: string;
  theme: string;
  department_id: string | null;
};

export type MeasureOption = {
  id: string;
  measure_key: string;
  name: string;
};

export type IncidentRow = {
  id: string;
  title: string;
  summary: string;
  occurred_at: string | Date | null;
  detected_at: string | Date | null;
  severity: IncidentSeverity | null;
  status: IncidentStatus;
  resolved_at: string | Date | null;
  related_risk_id: string | null;
  related_risk_theme: string | null;
  related_measure_id: string | null;
  related_measure_name: string | null;
  assignee_user_id: string | null;
  assignee_name: string | null;
  // Risk owner of the related risk's department. Used to suggest a default when assignee is unset.
  suggested_owner_user_id: string | null;
  suggested_owner_name: string | null;
};

export type IncidentWorkspaceData = {
  incidents: IncidentRow[];
  riskOwners: RiskOwnerOption[];
  risks: RiskOption[];
  measures: MeasureOption[];
};

export async function getIncidentWorkspace(): Promise<TenantReadResult<IncidentWorkspaceData>> {
  return withTenant(async (sql) => {
    const incidents = await sql<IncidentRow[]>`
      SELECT i.id, i.title, i.summary, i.occurred_at, i.detected_at, i.severity, i.status,
             i.resolved_at, i.related_risk_id, r.theme AS related_risk_theme,
             i.related_measure_id, m.name AS related_measure_name,
             i.assignee_user_id, au.display_name AS assignee_name,
             ou.id AS suggested_owner_user_id, ou.display_name AS suggested_owner_name
        FROM app.incidents i
        LEFT JOIN app.risk_scenarios r ON r.tenant_id = i.tenant_id AND r.id = i.related_risk_id
        LEFT JOIN app.measures m ON m.tenant_id = i.tenant_id AND m.id = i.related_measure_id
        LEFT JOIN app.users au ON au.tenant_id = i.tenant_id AND au.id = i.assignee_user_id
        LEFT JOIN app.departments d ON d.tenant_id = i.tenant_id AND d.id = r.department_id
        LEFT JOIN app.users ou ON ou.tenant_id = i.tenant_id AND ou.id = d.owner_user_id
                               AND ou.status = 'active'
       ORDER BY i.occurred_at DESC NULLS LAST, i.created_at DESC`;

    // Options are "currently active risk_owner" union "users currently assigned to an existing incident
    // (even if they have left or had their role removed)". Excluding the latter means that just editing and saving
    // that incident silently clears the assignment (Codex review 2026-09-02 finding).
    const riskOwners = await sql<RiskOwnerOption[]>`
      SELECT user_id, display_name, department_name, is_active_pool FROM (
        SELECT DISTINCT ON (user_id) user_id, display_name, department_name, is_active_pool
          FROM (
            SELECT u.id AS user_id, u.display_name, d.name AS department_name, true AS is_active_pool
              FROM app.memberships mem
              JOIN app.users u ON u.tenant_id = mem.tenant_id AND u.id = mem.user_id
              LEFT JOIN app.departments d ON d.tenant_id = mem.tenant_id AND d.id = mem.department_id
             WHERE mem.role_key = 'risk_owner' AND mem.revoked_at IS NULL AND u.status = 'active'
            UNION ALL
            SELECT DISTINCT u.id, u.display_name, NULL, false
              FROM app.incidents i
              JOIN app.users u ON u.tenant_id = i.tenant_id AND u.id = i.assignee_user_id
             WHERE i.tenant_id = app.current_tenant()
          ) opts
         -- 同じuser_idが両方に出た場合、is_active_pool=trueの行(department_name有り)を優先する
         ORDER BY user_id, is_active_pool DESC NULLS LAST
      ) dedup
      ORDER BY is_active_pool DESC, display_name`;

    const risks = await sql<RiskOption[]>`
      SELECT id, theme, department_id FROM app.risk_scenarios
       WHERE status = 'active' ORDER BY theme`;

    const measures = await sql<MeasureOption[]>`
      SELECT id, measure_key, name FROM app.measures
       WHERE status <> 'retired' ORDER BY measure_key`;

    return { incidents, riskOwners, risks, measures };
  });
}
