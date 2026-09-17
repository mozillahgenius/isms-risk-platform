import 'server-only';

import { withTenantActor, type TenantReadResult } from './tenant';

export type ManagementRole = 'owner' | 'admin' | 'manager' | 'member' | 'auditor' | 'none';

export const MANAGEMENT_ROLE_LABEL: Record<ManagementRole, string> = {
  owner: 'オーナー',
  admin: '管理者',
  manager: 'マネージャー',
  member: 'メンバー',
  auditor: '監査人',
  none: '権限未設定',
};

export const ASSIGNMENT_STATUS_LABEL: Record<string, string> = {
  requested: '依頼中',
  accepted: '受領済み',
  in_progress: '対応中',
  submitted: '提出済み',
  completed: '完了',
  declined: '辞退',
  cancelled: '取消',
};

export const ASSIGNMENT_ROLE_LABEL: Record<string, string> = {
  owner: '担当責任者',
  editor: '編集担当',
  reviewer: 'レビュー担当',
  approver: '承認担当',
};

export const WORK_TYPE_LABEL: Record<string, string> = {
  asset_inventory: '情報資産の洗い出し',
  risk_assessment: 'リスクアセスメント',
  incident_response: 'インシデント対応・報告',
  training_execution: '教育・訓練',
  external_resource_review: '外部リソース確認',
  custom: 'その他の作業',
};

/** 対象レコードの種別ラベル。0058 の app.work_type_for_resource と対で持つ。 */
export const RESOURCE_TYPE_LABEL: Record<string, string> = {
  asset: '情報資産',
  risk: 'リスク',
  measure: '施策',
  incident: 'インシデント',
  training: '教育・訓練',
  vendor: '外部リソース',
  vendor_assessment: '外部リソース評価',
};

/** 作業種別ごとに選べる対象レコードの種別。work_type_for_resource の逆写像。 */
export const RESOURCE_TYPES_FOR_WORK: Record<string, string[]> = {
  asset_inventory: ['asset'],
  risk_assessment: ['risk', 'measure'],
  incident_response: ['incident'],
  training_execution: ['training'],
  external_resource_review: ['vendor', 'vendor_assessment'],
  custom: [],
};

/** 対象候補の取得件数上限。台帳が育っても選択肢の描画で画面が潰れないようにする。 */
const TARGET_LIMIT = 300;

export type AssigneeRow = {
  user_id: string;
  display_name: string;
  assignment_role: string;
  status: string;
  completion_note: string;
  department_name: string | null;
};

export type AssignmentRow = {
  id: string;
  work_type: keyof typeof WORK_TYPE_LABEL;
  title: string;
  instructions: string;
  resource_type: string | null;
  resource_id: string | null;
  resource_label: string | null;
  requester_name: string | null;
  due_date: string | null;
  status: string;
  created_at: string;
  assignees: AssigneeRow[];
  /** 閲覧者自身がこの作業の担当なら、その 1 行。担当でなければ null。 */
  mine: AssigneeRow | null;
  notified_count: number;
};

export type MemberOption = {
  id: string;
  display_name: string;
  email: string;
  role: ManagementRole;
  department_id: string | null;
  department_name: string | null;
};

export type DepartmentOption = {
  id: string;
  name: string;
  owner_name: string | null;
  active_member_count: number;
};

export type TargetOption = {
  resource_type: string;
  resource_id: string;
  label: string;
};

export type AssignmentWorkspace = {
  role: ManagementRole;
  canManage: boolean;
  currentUserId: string | null;
  users: MemberOption[];
  departments: DepartmentOption[];
  workTypes: { value: keyof typeof WORK_TYPE_LABEL; label: string }[];
  /** selectedWorkType に対応する対象レコード候補。未選択なら空。 */
  targets: TargetOption[];
  selectedWorkType: string;
  assignments: AssignmentRow[];
  mineCount: number;
  totalCount: number;
};

export type AssignmentQuery = {
  /** 'mine' なら自分が担当の作業だけ。既定は担当以外も見える範囲すべて。 */
  scope?: string;
  workType?: string;
};

async function loadTargets(
  sql: Parameters<Parameters<typeof withTenantActor>[0]>[0],
  workType: string,
): Promise<TargetOption[]> {
  const types = RESOURCE_TYPES_FOR_WORK[workType] ?? [];
  if (types.length === 0) return [];
  const out: TargetOption[] = [];
  if (types.includes('asset')) {
    const rows = await sql<{ id: string; label: string }[]>`
      SELECT id, (asset_key || ' / ' || name) AS label FROM app.assets
       WHERE tenant_id=app.current_tenant() AND status='active'
       ORDER BY asset_key LIMIT ${TARGET_LIMIT}`;
    out.push(...rows.map((r) => ({ resource_type: 'asset', resource_id: r.id, label: r.label })));
  }
  if (types.includes('risk')) {
    const rows = await sql<{ id: string; label: string }[]>`
      SELECT id, (risk_key || ' / ' || summary) AS label FROM app.risk_scenarios
       WHERE tenant_id=app.current_tenant() AND status='active'
       ORDER BY risk_key LIMIT ${TARGET_LIMIT}`;
    out.push(...rows.map((r) => ({ resource_type: 'risk', resource_id: r.id, label: r.label })));
  }
  if (types.includes('measure')) {
    const rows = await sql<{ id: string; label: string }[]>`
      SELECT id, (measure_key || ' / ' || name) AS label FROM app.measures
       WHERE tenant_id=app.current_tenant() AND status <> 'retired'
       ORDER BY measure_key LIMIT ${TARGET_LIMIT}`;
    out.push(...rows.map((r) => ({ resource_type: 'measure', resource_id: r.id, label: r.label })));
  }
  if (types.includes('incident')) {
    const rows = await sql<{ id: string; label: string }[]>`
      SELECT id, title AS label FROM app.incidents
       WHERE tenant_id=app.current_tenant()
       ORDER BY created_at DESC LIMIT ${TARGET_LIMIT}`;
    out.push(...rows.map((r) => ({ resource_type: 'incident', resource_id: r.id, label: r.label })));
  }
  if (types.includes('training')) {
    const rows = await sql<{ id: string; label: string }[]>`
      SELECT id, (fiscal_year::text || '年度 / ' || title) AS label FROM app.trainings
       WHERE tenant_id=app.current_tenant()
       ORDER BY fiscal_year DESC, title LIMIT ${TARGET_LIMIT}`;
    out.push(...rows.map((r) => ({ resource_type: 'training', resource_id: r.id, label: r.label })));
  }
  if (types.includes('vendor')) {
    const rows = await sql<{ id: string; label: string }[]>`
      SELECT id, (name || coalesce(' / ' || service_name, '')) AS label FROM app.vendors
       WHERE tenant_id=app.current_tenant()
       ORDER BY name LIMIT ${TARGET_LIMIT}`;
    out.push(...rows.map((r) => ({ resource_type: 'vendor', resource_id: r.id, label: r.label })));
  }
  if (types.includes('vendor_assessment')) {
    const rows = await sql<{ id: string; label: string }[]>`
      SELECT a.id, (v.name || ' / ' || a.assessed_on::text) AS label
        FROM app.vendor_assessments a
        JOIN app.vendors v ON v.tenant_id=a.tenant_id AND v.id=a.vendor_id
       WHERE a.tenant_id=app.current_tenant()
       ORDER BY a.assessed_on DESC LIMIT ${TARGET_LIMIT}`;
    out.push(...rows.map((r) => ({ resource_type: 'vendor_assessment', resource_id: r.id, label: r.label })));
  }
  return out;
}

export async function getAssignmentWorkspace(
  query: AssignmentQuery = {},
): Promise<TenantReadResult<AssignmentWorkspace>> {
  const selectedWorkType = query.workType && WORK_TYPE_LABEL[query.workType] ? query.workType : '';
  const mineOnly = query.scope === 'mine';
  return withTenantActor(async (sql) => {
    const [roleRows, users, departments] = await Promise.all([
      sql<{ role: ManagementRole; user_id: string | null }[]>`
        SELECT app.current_management_role() AS role,
               app.current_session_user()::text AS user_id`,
      // 依頼先の候補。0057 の写像と同じ CASE を使う（organizationRegister.ts と同一）。
      sql<MemberOption[]>`
        SELECT u.id, u.display_name, u.email::text,
               CASE
                 WHEN bool_or(m.role_key='ciso') THEN 'owner'
                 WHEN bool_or(m.role_key='secretariat') THEN 'admin'
                 WHEN bool_or(m.role_key='risk_owner') THEN 'manager'
                 WHEN bool_or(m.role_key='employee') THEN 'member'
                 WHEN bool_or(m.role_key='auditor') THEN 'auditor'
                 ELSE 'none'
               END AS role,
               (array_agg(m.department_id ORDER BY m.granted_at DESC)
                  FILTER (WHERE m.department_id IS NOT NULL))[1]::text AS department_id,
               (array_agg(d.name ORDER BY m.granted_at DESC)
                  FILTER (WHERE d.name IS NOT NULL))[1] AS department_name
          FROM app.users u
          LEFT JOIN app.memberships m
            ON m.tenant_id=u.tenant_id AND m.user_id=u.id AND m.revoked_at IS NULL
          LEFT JOIN app.departments d
            ON d.tenant_id=m.tenant_id AND d.id=m.department_id
         WHERE u.tenant_id=app.current_tenant() AND u.status='active'
         GROUP BY u.tenant_id,u.id,u.display_name,u.email
         ORDER BY u.display_name,u.email`,
      sql<DepartmentOption[]>`
        SELECT d.id, d.name, o.display_name AS owner_name,
               (SELECT count(DISTINCT m.user_id)::int
                  FROM app.memberships m JOIN app.users mu
                    ON mu.tenant_id=m.tenant_id AND mu.id=m.user_id
                 WHERE m.tenant_id=d.tenant_id AND m.department_id=d.id
                   AND m.revoked_at IS NULL AND mu.status='active') AS active_member_count
          FROM app.departments d
          LEFT JOIN app.users o ON o.tenant_id=d.tenant_id AND o.id=d.owner_user_id
         WHERE d.tenant_id=app.current_tenant()
         ORDER BY d.name`,
    ]);
    const role = roleRows[0]?.role ?? 'none';
    const currentUserId = roleRows[0]?.user_id ?? null;

    // 作業は 1 行、担当者は別行で取る。以前は min()/string_agg() で 1 行へ潰して
    // いたため、担当者ごとの担当区分と進捗が画面から読めなかった。
    const items = await sql<{
      id: string; work_type: string; title: string; instructions: string;
      resource_type: string | null; resource_id: string | null; resource_label: string | null;
      requester_name: string | null; due_date: string | null; status: string; created_at: string;
      notified_count: number;
    }[]>`
      SELECT w.id, w.work_type, w.title, w.instructions,
             w.resource_type, w.resource_id::text,
             CASE w.resource_type
               WHEN 'asset' THEN (SELECT a.asset_key || ' / ' || a.name FROM app.assets a
                                   WHERE a.tenant_id=w.tenant_id AND a.id=w.resource_id)
               WHEN 'risk' THEN (SELECT r.risk_key || ' / ' || r.summary FROM app.risk_scenarios r
                                  WHERE r.tenant_id=w.tenant_id AND r.id=w.resource_id)
               WHEN 'measure' THEN (SELECT m.measure_key || ' / ' || m.name FROM app.measures m
                                     WHERE m.tenant_id=w.tenant_id AND m.id=w.resource_id)
               WHEN 'incident' THEN (SELECT i.title FROM app.incidents i
                                      WHERE i.tenant_id=w.tenant_id AND i.id=w.resource_id)
               WHEN 'training' THEN (SELECT t.title FROM app.trainings t
                                      WHERE t.tenant_id=w.tenant_id AND t.id=w.resource_id)
               WHEN 'vendor' THEN (SELECT v.name FROM app.vendors v
                                    WHERE v.tenant_id=w.tenant_id AND v.id=w.resource_id)
               WHEN 'vendor_assessment' THEN (SELECT v.name || ' / ' || va.assessed_on::text
                                                FROM app.vendor_assessments va
                                                JOIN app.vendors v ON v.tenant_id=va.tenant_id AND v.id=va.vendor_id
                                               WHERE va.tenant_id=w.tenant_id AND va.id=w.resource_id)
               ELSE NULL
             END AS resource_label,
             creator.display_name AS requester_name,
             w.due_date::text, w.status, w.created_at::text,
             (SELECT count(*)::int FROM app.mail_outbox mo
               WHERE mo.tenant_id=w.tenant_id AND mo.purpose='work_assignment'
                 AND mo.related_type='work_item' AND mo.related_id=w.id) AS notified_count
        FROM app.work_items w
        LEFT JOIN app.users creator ON creator.tenant_id=w.tenant_id AND creator.id=w.created_by
       WHERE w.tenant_id=app.current_tenant()
         AND (app.current_management_role() IN ('owner','admin','manager')
              OR EXISTS (SELECT 1 FROM app.work_item_assignees a
                          WHERE a.tenant_id=w.tenant_id AND a.work_item_id=w.id
                            AND a.user_id=app.current_session_user()))
       ORDER BY w.created_at DESC`;

    const assigneeRows = await sql<(AssigneeRow & { work_item_id: string })[]>`
      SELECT a.work_item_id::text, a.user_id::text, u.display_name,
             a.assignment_role, a.status, a.completion_note,
             (SELECT d.name FROM app.memberships m
                JOIN app.departments d ON d.tenant_id=m.tenant_id AND d.id=m.department_id
               WHERE m.tenant_id=a.tenant_id AND m.user_id=a.user_id AND m.revoked_at IS NULL
               ORDER BY m.granted_at DESC LIMIT 1) AS department_name
        FROM app.work_item_assignees a
        JOIN app.users u ON u.tenant_id=a.tenant_id AND u.id=a.user_id
       WHERE a.tenant_id=app.current_tenant()
       ORDER BY u.display_name`;

    const byItem = new Map<string, AssigneeRow[]>();
    for (const row of assigneeRows) {
      const list = byItem.get(row.work_item_id) ?? [];
      list.push({
        user_id: row.user_id,
        display_name: row.display_name,
        assignment_role: row.assignment_role,
        status: row.status,
        completion_note: row.completion_note,
        department_name: row.department_name,
      });
      byItem.set(row.work_item_id, list);
    }

    const all: AssignmentRow[] = items.map((item) => {
      const assignees = byItem.get(item.id) ?? [];
      return {
        ...item,
        work_type: item.work_type as keyof typeof WORK_TYPE_LABEL,
        assignees,
        mine: assignees.find((a) => a.user_id === currentUserId) ?? null,
      };
    });

    const mineCount = all.filter((item) => item.mine).length;
    const filtered = all
      .filter((item) => (mineOnly ? item.mine !== null : true))
      .filter((item) => (selectedWorkType ? item.work_type === selectedWorkType : true));

    return {
      role,
      canManage: ['owner', 'admin', 'manager'].includes(role),
      currentUserId,
      users,
      departments,
      workTypes: Object.entries(WORK_TYPE_LABEL).map(([value, label]) => ({
        value: value as keyof typeof WORK_TYPE_LABEL, label,
      })),
      targets: selectedWorkType ? await loadTargets(sql, selectedWorkType) : [],
      selectedWorkType,
      assignments: filtered,
      mineCount,
      totalCount: all.length,
    };
  });
}
