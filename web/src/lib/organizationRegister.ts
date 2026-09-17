import 'server-only';

import { withTenantActor, type TenantReadResult } from './tenant';
import { MANAGEMENT_ROLE_LABEL, type ManagementRole } from './workAssignments';

export { MANAGEMENT_ROLE_LABEL };
export type { ManagementRole };

/**
 * 組織管理（部門・メンバー・役割）の読み取り。
 *
 * 27c56ef「RUNTIME稼働状態へ同期」で web/src/app/organization/ ごと消えていたが、
 * navigation.ts は RISK / ISMS の両モードで /organization を出し続けていたため
 * リンク先が 404 だった。復旧にあたり、読み取りを withTenant（共有トークン）から
 * withTenantActor（プロキシ本人性）へ移す。閲覧者自身の管理ロールが分からないと
 * 「誰がフォームを出してよいか」を画面側で決められないため。
 *
 * ロールは新設しない。catalog.roles_default の 5 ロール（0002 / 0029 seed）を
 * 0057 の app.current_management_role() と同じ写像で owner/admin/manager/member/
 * auditor として見せる。写像を二重に持つと必ず食い違うので、SQL 側の CASE は
 * workAssignments.ts のユーザー一覧と同じ形にそろえてある。
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

/** 利用システム（app.application_catalog）。ID連携の親であると同時に、
 *  各メンバーが登録する「うちが使っているシステム」の正本（0061）。 */
export type SystemRow = {
  id: string;
  app_key: string;
  name: string;
  provider: string;
  status: string;
  /** この部門数がこのシステムを使っていると申告している */
  department_count: number;
  /** このシステムを所在場所としている情報資産の件数 */
  asset_count: number;
};

/** 部門がどのシステムをどう使っているか。 */
export type DepartmentSystemRow = {
  department_id: string;
  department_name: string;
  application_id: string;
  system_name: string;
  usage_note: string;
};

/** 部門の中で「どのシステムに、どんな情報が、どれだけあるか」。
 *  新しい入力は持たず、資産台帳（app.assets）からの集計だけで作る。 */
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
 * どのタブでも要る「閲覧者は誰で、何ができるか」だけを取る。
 *
 * 以前は 1 リクエストで 15 本前後のクエリを常に全部投げていた（部門も、メンバーも、
 * システムも、資産の集計も、ウィザードの進捗も）。画面をマスタごとに割るなら、
 * 各画面が必要な分だけ読む形にしないと「表示は 4 画面・負荷は 4 倍」になる。
 */
export type OrganizationContext = {
  role: ManagementRole;
  /** 部門・適用範囲・審査機関の編集。オーナー・管理者（0059 の org_manage）。 */
  canManageOrg: boolean;
  /** 管理ロールそのものの変更。オーナーのみ（0057 の role_manage）。 */
  canManageRole: boolean;
  /** 利用システムの編集。監査人と所属なし以外（0061）。 */
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

/** 部門の選択肢だけが要る画面のための最小読み取り。 */
async function readDepartmentOptions(sql: Sql): Promise<{ id: string; name: string }[]> {
  return sql<{ id: string; name: string }[]>`
    SELECT id, name FROM app.departments
     WHERE tenant_id = app.current_tenant() ORDER BY name`;
}

export type MemberMasterData = OrganizationContext & {
  members: MemberRow[];
  roleCounts: Record<ManagementRole, number>;
  /** 追加フォームの「所属部門」の選択肢。部門タブの全情報は要らない。 */
  departmentOptions: { id: string; name: string }[];
};

export type DepartmentMasterData = OrganizationContext & {
  departments: DepartmentNode[];
  memberships: MembershipRow[];
  users: UserOption[];
  roles: RoleOption[];
  /** 部門の利用申告。登録はシステムマスタ側だが、部門ごとの実態表で読む。 */
  departmentSystems: DepartmentSystemRow[];
  departmentInformation: DepartmentInformationRow[];
  /** 管理部門が未設定の情報資産の件数。ここが 0 にならないと部門ビューは埋まらない。 */
  assetsWithoutDepartment: number;
};

export type SystemMasterData = OrganizationContext & {
  systems: SystemRow[];
  /** 部門の利用申告フォームの選択肢。明細そのものは部門タブで読む。 */
  departmentOptions: { id: string; name: string }[];
};

export type OrganizationProfileData = OrganizationContext & {
  tenant: TenantInfo;
  certificationBodies: CertificationBodyRow[];
};

/** メンバーマスタ。名簿とロール別人数。 */
export async function getMemberMaster(): Promise<TenantReadResult<MemberMasterData>> {
  return withTenantActor(async (sql) => {
    const context = await readContext(sql);

    // 停止・退職済みも含めて出す。名簿から静かに消えると「まだ入れるのか」が
    // 画面から確認できなくなる（app.set_tenant_context_for_proxy は status='active'
    // かつ有効な所属が 1 件ある人だけを通す＝ここが実質のアクセス権一覧になる）。
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

/** 部門マスタ。部門・責任者・所属割当と、部門ごとの利用実態。 */
export async function getDepartmentMaster(): Promise<TenantReadResult<DepartmentMasterData>> {
  return withTenantActor(async (sql) => {
    const context = await readContext(sql);

    // 部門ごとの在籍数は memberships 側で数える。ここで数えておかないと、
    // 画面が部門 × メンバーの二重ループで数えることになり、除外された部門
    // （循環参照）の分だけ数字が静かにずれる。
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

    // 部門 × 所在場所ごとの情報資産。入力欄は増やさず、資産台帳から出す。
    // 所在がシステムでも自由記述でも同じ形で並べたいので、両方で束ねる。
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

/** 利用システムマスタ。システムそのものと、部門の利用申告。 */
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

/** 組織情報。組織名・ISMS適用範囲と審査機関。 */
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
 * ウィザードの進捗。
 *
 * 以前はウィザードも getOrganizationWorkspace() を呼んでいたので、6 個の
 * count(*) を得るために名簿・部門・システム・資産集計まで全部読んでいた。
 */
export async function getWizardSteps(): Promise<TenantReadResult<WizardStepStatus[]>> {
  return withTenantActor(async (sql) => {
    const tenants = await sql<TenantInfo[]>`
      SELECT name, iso_scope_statement FROM app.tenants WHERE id = app.current_tenant()`;
    const scope = tenants[0]?.iso_scope_statement ?? '';

    // 主要ロジック(仕様書): 各ステップの完了判定は対応テーブルの1件以上の
    // データ有無で機械的に行う。
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
