import 'server-only';

import { withTenantActor, type TenantReadResult } from './tenant';
import { MANAGEMENT_ROLE_LABEL, type ManagementRole } from './workAssignments';

export { MANAGEMENT_ROLE_LABEL };
export type { ManagementRole };

/**
 * Reading organization management data (departments, members, roles).
 *
 * A previous change deleted web/src/app/organization/ entirely, but
 * navigation.ts kept showing /organization in both RISK / ISMS modes, so
 * the link target was a 404. As part of restoring it, reads move from withTenant (shared token) to
 * withTenantActor (proxy identity). Without knowing the viewer's own management role,
 * the screen cannot decide which viewers it may present the edit forms to.
 *
 * No new roles are created. The 5 roles in catalog.roles_default (0002 / 0029 seed) are shown as
 * owner/admin/manager/member/auditor using the same mapping as app.current_management_role() in 0057.
 * Keeping the mapping in two places inevitably leads to divergence, so the SQL CASE is
 * written in the same form as the user list in workAssignments.ts.
 */

export type TenantInfo = {
  name: string;
  iso_scope_statement: string;
};

export type CertificationBodyRow = {
  id: string;
  body_name: string;
  certification_standard: string;
  certificate_number: string;
  initial_certified_on: string | null;
  last_audit_on: string | null;
  next_audit_on: string | null;
  contact_info: string;
  source_note: string;
};

export type DepartmentNode = {
  id: string;
  name: string;
  parent_id: string | null;
  owner_user_id: string | null;
  owner_name: string | null;
  member_count: number;
};

export type MembershipRow = {
  id: string;
  user_id: string;
  display_name: string;
  role_key: string;
  role_name: string | null;
  department_id: string | null;
  department_name: string | null;
  granted_at: string;
};

export type MemberRow = {
  id: string;
  display_name: string;
  email: string;
  status: string;
  role: ManagementRole;
  role_keys: string[];
  department_id: string | null;
  department_name: string | null;
  leads_departments: string[];
};

/** Systems in use (app.application_catalog). The parent for identity federation, and also
 *  the source of truth (0061) for "systems we use" that each member registers. */
export type SystemRow = {
  id: string;
  app_key: string;
  name: string;
  provider: string;
  status: string;
  /** Number of departments that declare they use this system */
  department_count: number;
  /** Number of information assets located in this system */
  asset_count: number;
};

/** Which systems a department uses and how. */
export type DepartmentSystemRow = {
  department_id: string;
  department_name: string;
  application_id: string;
  system_name: string;
  usage_note: string;
};

/** Within a department, "which systems hold what information, and how much".
 *  Takes no new input; built only from aggregates of the asset register (app.assets). */
export type DepartmentInformationRow = {
  department_id: string;
  department_name: string;
  application_id: string | null;
  system_name: string | null;
  location_note: string;
  asset_count: number;
  asset_names: string[];
  classifications: string[];
};

export type WizardStepStatus = {
  step: number;
  label: string;
  complete: boolean;
};

export type UserOption = { id: string; display_name: string };
export type RoleOption = { key: string; name_ja: string };


const EMPTY_ROLE_COUNTS: Record<ManagementRole, number> = {
  owner: 0, admin: 0, manager: 0, member: 0, auditor: 0, none: 0,
};

/**
 * Fetches only "who the viewer is and what they can do", which every tab needs.
 *
 * Previously a single request always issued around 15 queries (departments, members,
 * systems, asset aggregates, wizard progress). If the screen is split per master,
 * each screen must read only what it needs, or it becomes "4 screens displayed, 4x the load".
 */
export type OrganizationContext = {
  role: ManagementRole;
  /** Editing departments, scope, and certification body. Owners and admins (org_manage in 0059). */
  canManageOrg: boolean;
  /** Changing management roles themselves. Owners only (role_manage in 0057). */
  canManageRole: boolean;
  /** Editing systems in use. Everyone except auditors and those with no membership (0061). */
  canEditSystems: boolean;
  currentUserId: string | null;
};

type Sql = Parameters<Parameters<typeof withTenantActor>[0]>[0];

async function readContext(sql: Sql): Promise<OrganizationContext> {
  const rows = await sql<{ role: ManagementRole; user_id: string | null }[]>`
    SELECT app.current_management_role() AS role,
           app.current_session_user()::text AS user_id`;
  const role = rows[0]?.role ?? 'none';
  return {
    role,
    canManageOrg: ['owner', 'admin'].includes(role),
    canManageRole: role === 'owner',
    canEditSystems: !['none', 'auditor'].includes(role),
    currentUserId: rows[0]?.user_id ?? null,
  };
}

/** Minimal read for screens that only need the department options. */
async function readDepartmentOptions(sql: Sql): Promise<{ id: string; name: string }[]> {
  return sql<{ id: string; name: string }[]>`
    SELECT id, name FROM app.departments
     WHERE tenant_id = app.current_tenant() ORDER BY name`;
}

export type MemberMasterData = OrganizationContext & {
  members: MemberRow[];
  roleCounts: Record<ManagementRole, number>;
  /** Options for "department" in the add form. The full department tab data is not needed. */
  departmentOptions: { id: string; name: string }[];
};

export type DepartmentMasterData = OrganizationContext & {
  departments: DepartmentNode[];
  memberships: MembershipRow[];
  users: UserOption[];
  roles: RoleOption[];
  /** Department usage declarations. Registered on the system master side, but read in the per-department actuals table. */
  departmentSystems: DepartmentSystemRow[];
  departmentInformation: DepartmentInformationRow[];
  /** Count of information assets with no managing department set. The department view will not be filled until this is 0. */
  assetsWithoutDepartment: number;
};

export type SystemMasterData = OrganizationContext & {
  systems: SystemRow[];
  /** Options for the department usage declaration form. The details themselves are read in the department tab. */
  departmentOptions: { id: string; name: string }[];
};

export type OrganizationProfileData = OrganizationContext & {
  tenant: TenantInfo;
  certificationBodies: CertificationBodyRow[];
};

/** Member master. Roster and headcount per role. */
export async function getMemberMaster(): Promise<TenantReadResult<MemberMasterData>> {
  return withTenantActor(async (sql) => {
    const context = await readContext(sql);

    // Include suspended and departed members too. If they silently vanish from the roster, "can they still get in?"
    // can no longer be checked from the screen (app.set_tenant_context_for_proxy passes only people with status='active'
    // and one valid membership, so this is effectively the access list).
    const members = await sql<MemberRow[]>`
      SELECT u.id, u.display_name, u.email::text, u.status,
             CASE
               WHEN bool_or(m.role_key='ciso') THEN 'owner'
               WHEN bool_or(m.role_key='secretariat') THEN 'admin'
               WHEN bool_or(m.role_key='risk_owner') THEN 'manager'
               WHEN bool_or(m.role_key='employee') THEN 'member'
               WHEN bool_or(m.role_key='auditor') THEN 'auditor'
               ELSE 'none'
             END AS role,
             coalesce(array_agg(DISTINCT m.role_key) FILTER (WHERE m.role_key IS NOT NULL),
                      ARRAY[]::text[]) AS role_keys,
             (array_agg(m.department_id ORDER BY m.granted_at DESC)
                FILTER (WHERE m.department_id IS NOT NULL))[1]::text AS department_id,
             (array_agg(d.name ORDER BY m.granted_at DESC)
                FILTER (WHERE d.name IS NOT NULL))[1] AS department_name,
             coalesce(array_agg(DISTINCT led.name) FILTER (WHERE led.name IS NOT NULL),
                      ARRAY[]::text[]) AS leads_departments
        FROM app.users u
        LEFT JOIN app.memberships m
          ON m.tenant_id=u.tenant_id AND m.user_id=u.id AND m.revoked_at IS NULL
        LEFT JOIN app.departments d
          ON d.tenant_id=m.tenant_id AND d.id=m.department_id
        LEFT JOIN app.departments led
          ON led.tenant_id=u.tenant_id AND led.owner_user_id=u.id
       WHERE u.tenant_id = app.current_tenant()
       GROUP BY u.tenant_id, u.id, u.display_name, u.email, u.status
       ORDER BY u.status, u.display_name, u.email`;

    const departmentOptions = await readDepartmentOptions(sql);

    const roleCounts = { ...EMPTY_ROLE_COUNTS };
    for (const member of members) {
      if (member.status !== 'active') continue;
      roleCounts[member.role] += 1;
    }

    return { ...context, members, roleCounts, departmentOptions };
  });
}

/** Department master. Departments, heads, membership assignments, and per-department usage. */
export async function getDepartmentMaster(): Promise<TenantReadResult<DepartmentMasterData>> {
  return withTenantActor(async (sql) => {
    const context = await readContext(sql);

    // Headcount per department is counted on the memberships side. If it were not counted here,
    // the screen would count with a department x member double loop, and the numbers would silently drift
    // by the excluded departments (circular references).
    const departments = await sql<DepartmentNode[]>`
      SELECT d.id, d.name, d.parent_id, d.owner_user_id, u.display_name AS owner_name,
             (SELECT count(DISTINCT m.user_id)::int
                FROM app.memberships m
               WHERE m.tenant_id = d.tenant_id AND m.department_id = d.id
                 AND m.revoked_at IS NULL) AS member_count
        FROM app.departments d
        LEFT JOIN app.users u ON u.tenant_id = d.tenant_id AND u.id = d.owner_user_id
       WHERE d.tenant_id = app.current_tenant()
       ORDER BY d.name`;

    const memberships = await sql<MembershipRow[]>`
      SELECT m.id, m.user_id, u.display_name, m.role_key, r.name_ja AS role_name,
             m.department_id, d.name AS department_name,
             (m.granted_at AT TIME ZONE 'Asia/Tokyo')::date::text AS granted_at
        FROM app.memberships m
        JOIN app.users u ON u.tenant_id = m.tenant_id AND u.id = m.user_id
        LEFT JOIN app.departments d ON d.tenant_id = m.tenant_id AND d.id = m.department_id
        LEFT JOIN catalog.roles_default r ON r.key = m.role_key
       WHERE m.tenant_id = app.current_tenant() AND m.revoked_at IS NULL
       ORDER BY d.name NULLS LAST, u.display_name`;

    const users = await sql<UserOption[]>`
      SELECT id, display_name FROM app.users
       WHERE tenant_id = app.current_tenant() AND status = 'active'
       ORDER BY display_name`;

    const roles = await sql<RoleOption[]>`
      SELECT key, name_ja FROM catalog.roles_default ORDER BY sort_order`;

    const departmentSystems = await sql<DepartmentSystemRow[]>`
      SELECT ds.department_id::text, d.name AS department_name,
             ds.application_id::text, a.name AS system_name, ds.usage_note
        FROM app.department_systems ds
        JOIN app.departments d ON d.tenant_id = ds.tenant_id AND d.id = ds.department_id
        JOIN app.application_catalog a ON a.tenant_id = ds.tenant_id AND a.id = ds.application_id
       WHERE ds.tenant_id = app.current_tenant()
       ORDER BY d.name, a.name`;

    // Information assets per department x location. No new input fields; derived from the asset register.
    // We want to list them the same way whether the location is a system or free text, so group by both.
    const departmentInformation = await sql<DepartmentInformationRow[]>`
      SELECT a.owner_department_id::text AS department_id, d.name AS department_name,
             a.location_system_id::text AS application_id, s.name AS system_name,
             a.location_note,
             count(*)::int AS asset_count,
             array_agg(a.name ORDER BY a.asset_key) AS asset_names,
             array_agg(DISTINCT coalesce(ac.name_ja, a.classification)) AS classifications
        FROM app.assets a
        JOIN app.departments d ON d.tenant_id = a.tenant_id AND d.id = a.owner_department_id
        LEFT JOIN app.application_catalog s
          ON s.tenant_id = a.tenant_id AND s.id = a.location_system_id
        LEFT JOIN catalog.asset_classes_default ac ON ac.key = a.classification
       WHERE a.tenant_id = app.current_tenant() AND a.status = 'active'
       GROUP BY a.owner_department_id, d.name, a.location_system_id, s.name, a.location_note
       ORDER BY d.name, s.name NULLS LAST, a.location_note`;

    const orphanAssets = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n FROM app.assets
       WHERE tenant_id = app.current_tenant() AND status = 'active'
         AND owner_department_id IS NULL`;

    return {
      ...context,
      departments,
      memberships,
      users,
      roles,
      departmentSystems,
      departmentInformation,
      assetsWithoutDepartment: orphanAssets[0]?.n ?? 0,
    };
  });
}

/** System-in-use master. The systems themselves, and department usage declarations. */
export async function getSystemMaster(): Promise<TenantReadResult<SystemMasterData>> {
  return withTenantActor(async (sql) => {
    const context = await readContext(sql);

    const systems = await sql<SystemRow[]>`
      SELECT a.id, a.app_key, a.name, a.provider, a.status,
             (SELECT count(*)::int FROM app.department_systems ds
               WHERE ds.tenant_id = a.tenant_id AND ds.application_id = a.id) AS department_count,
             (SELECT count(*)::int FROM app.assets ast
               WHERE ast.tenant_id = a.tenant_id AND ast.location_system_id = a.id
                 AND ast.status = 'active') AS asset_count
        FROM app.application_catalog a
       WHERE a.tenant_id = app.current_tenant()
       ORDER BY (a.status = 'retired'), a.name`;

    const departmentOptions = await readDepartmentOptions(sql);

    return { ...context, systems, departmentOptions };
  });
}

/** Organization info. Organization name, ISMS scope, and certification body. */
export async function getOrganizationProfile(): Promise<TenantReadResult<OrganizationProfileData>> {
  return withTenantActor(async (sql) => {
    const context = await readContext(sql);

    const tenants = await sql<TenantInfo[]>`
      SELECT name, iso_scope_statement FROM app.tenants WHERE id = app.current_tenant()`;
    const tenant = tenants[0] ?? { name: '', iso_scope_statement: '' };

    const certificationBodies = await sql<CertificationBodyRow[]>`
      SELECT id, body_name, certification_standard, certificate_number,
             initial_certified_on::text, last_audit_on::text, next_audit_on::text,
             contact_info, source_note
        FROM app.certification_bodies
       WHERE tenant_id = app.current_tenant()
       ORDER BY body_name`;

    return { ...context, tenant, certificationBodies };
  });
}

/**
 * Wizard progress.
 *
 * Previously the wizard also called getOrganizationWorkspace(), so to get 6
 * count(*) values it read everything, including the roster, departments, systems, and asset aggregates.
 */
export async function getWizardSteps(): Promise<TenantReadResult<WizardStepStatus[]>> {
  return withTenantActor(async (sql) => {
    const tenants = await sql<TenantInfo[]>`
      SELECT name, iso_scope_statement FROM app.tenants WHERE id = app.current_tenant()`;
    const scope = tenants[0]?.iso_scope_statement ?? '';

    // Core logic (spec): each step's completion is determined mechanically by whether the corresponding table
    // has at least one row of data.
    const [assetCount, competencyCount, incidentCount, costCount, certCount] = await Promise.all([
      sql<{ n: number }[]>`SELECT count(*)::int AS n FROM app.risk_scenarios`.then((r) => r[0]?.n ?? 0),
      sql<{ n: number }[]>`SELECT count(*)::int AS n FROM app.competency_requirements`.then((r) => r[0]?.n ?? 0),
      sql<{ n: number }[]>`SELECT count(*)::int AS n FROM app.incidents`.then((r) => r[0]?.n ?? 0),
      sql<{ n: number }[]>`SELECT count(*)::int AS n FROM app.education_records`.then((r) => r[0]?.n ?? 0),
      sql<{ n: number }[]>`SELECT count(*)::int AS n FROM app.certification_bodies`.then((r) => r[0]?.n ?? 0),
    ]);

    return [
      { step: 1, label: '初期設定(組織名・適用範囲)', complete: scope.trim().length > 0 },
      { step: 2, label: '適用範囲・審査機関', complete: certCount > 0 },
      { step: 3, label: '資産・リスク登録', complete: assetCount > 0 },
      { step: 4, label: '力量・教育', complete: competencyCount > 0 },
      { step: 5, label: 'ルールと運用(インシデント管理等)', complete: incidentCount > 0 },
      { step: 6, label: '振り返りの仕組み化(教育コスト記録等)', complete: costCount > 0 },
    ];
  });
}
