'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { withTenantWrite } from '@/lib/tenant';

// Based as-is on the implementation from before it was removed in 27c56ef. The input-validation conventions
// (no truncation, reject UUIDs and dates by format, today in JST) were settled in
// Codex review at the time, so do not change them. What was added: member
// registration, suspension, reactivation, and department updates (4 in total).

const text = (form: FormData, key: string, max = 1000): string => {
  const value = String(form.get(key) ?? '').trim();
  if (!value || value.length > max) throw new Error(`${key} is required`);
  return value;
};

// Reject values over the limit rather than silently truncating (Codex review 2026-09-03: truncation
// silently alters data). Callers try/catch and route to a friendly
// ?error=invalid_input.
const optionalText = (form: FormData, key: string, max = 4000): string | null => {
  const value = String(form.get(key) ?? '').trim();
  if (value.length > max) throw new Error(`${key} が長すぎます`);
  return value || null;
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const uuidText = (form: FormData, key: string): string => {
  const value = text(form, key, 80);
  if (!UUID_RE.test(value)) throw new Error(`${key} の形式が不正です`);
  return value;
};
const optionalUuidText = (form: FormData, key: string): string | null => {
  const value = optionalText(form, key, 80);
  if (value !== null && !UUID_RE.test(value)) throw new Error(`${key} の形式が不正です`);
  return value;
};

const ROLE_KEY_RE = /^[a-z][a-z_]{0,39}$/;
const roleKeyText = (form: FormData, key: string): string => {
  const value = text(form, key, 40);
  if (!ROLE_KEY_RE.test(value)) throw new Error(`${key} の形式が不正です`);
  return value;
};

// Same mapping as app.current_management_role() in 0057. Do not add roles here.
const MANAGEMENT_ROLES = ['owner', 'admin', 'manager', 'member', 'auditor'] as const;
type ManagementRoleInput = (typeof MANAGEMENT_ROLES)[number];
const ROLE_KEY_FOR: Record<ManagementRoleInput, string> = {
  owner: 'ciso', admin: 'secretariat', manager: 'risk_owner', member: 'employee', auditor: 'auditor',
};
const managementRole = (form: FormData, key: string): ManagementRoleInput => {
  const value = text(form, key, 20);
  if (!MANAGEMENT_ROLES.includes(value as ManagementRoleInput)) throw new Error(`${key} の形式が不正です`);
  return value as ManagementRoleInput;
};

// citext treats case as equal, but normalize to lowercase before inserting for display and matching.
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const emailText = (form: FormData, key: string): string => {
  const value = text(form, key, 254).toLowerCase();
  if (!EMAIL_RE.test(value)) throw new Error(`${key} の形式が不正です`);
  return value;
};

// Follows the policy established from 0037 onward as-is.
const optionalIsoDate = (form: FormData, key: string, label: string): string | null => {
  const raw = String(form.get(key) ?? '').trim();
  if (!raw) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(raw)) throw new Error(`${label} はYYYY-MM-DD形式で入力してください`);
  const d = new Date(`${raw}T00:00:00Z`);
  const [y, m, day] = raw.split('-').map(Number);
  if (d.getUTCFullYear() !== y || d.getUTCMonth() + 1 !== m || d.getUTCDate() !== day) {
    throw new Error(`${label} が実在する日付ではありません`);
  }
  return raw;
};

// "Today" in JST. new Date().toISOString() is UTC-based, so between 0-9 JST it shifts
// to the previous day (same convention as established in screen 1 riskRegister.ts; Codex review 2026-09-03).
const todayJst = (): string => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Tokyo' }).format(new Date());

/**
 * Which tab to return to after saving.
 *
 * Since the screen is split per master, returning every action to a single /organization
 * would mean "saving a department sends you to the member roster". The return target is
 * fixed on the action side (taking it from the form means a screen that forgot the hidden
 * field silently falls back to the default tab = the hardest breakage to notice).
 */
const ORG_TAB = {
  members: '/organization',
  departments: '/organization/departments',
  systems: '/organization/systems',
  profile: '/organization/profile',
} as const;
type OrgTab = keyof typeof ORG_TAB;

const ORG_ROUTES = Object.values(ORG_TAB);

/** mode (isms / risk) switches the whole nav. Dropping it on every save would send
 *  someone working in risk-management mode back to the ISMS ordering each time. */
function orgHref(tab: OrgTab, form: FormData, params: Record<string, string>): string {
  const query = new URLSearchParams();
  const mode = String(form.get('_mode') ?? '').trim();
  if (mode === 'isms' || mode === 'risk') query.set('mode', mode);
  for (const [key, value] of Object.entries(params)) query.set(key, value);
  const qs = query.toString();
  return qs ? `${ORG_TAB[tab]}?${qs}` : ORG_TAB[tab];
}

/** The 4 tabs are just different views of the same data, so invalidate them together.
 *  Manually maintaining "this action only affects this tab" inevitably goes stale somewhere. */
function revalidateOrganization(): void {
  for (const route of ORG_ROUTES) revalidatePath(route);
}

function parseOrRedirect<T>(tab: OrgTab, form: FormData, parse: () => T): T {
  try {
    return parse();
  } catch {
    redirect(orgHref(tab, form, { error: 'invalid_input' }));
  }
}

export async function saveScopeStatement(form: FormData) {
  const scopeStatement = parseOrRedirect('profile', form, () => optionalText(form, 'iso_scope_statement', 4000) ?? '');
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'org_manage')`;
    await sql`
      UPDATE app.tenants SET iso_scope_statement = ${scopeStatement}
       WHERE id = app.current_tenant()`;
  });
  if (!result.ok) redirect(orgHref('profile', form, { error: result.reason }));
  revalidateOrganization();
  revalidatePath('/wizard');
  redirect(orgHref('profile', form, { saved: '1' }));
}

export async function saveDepartment(form: FormData) {
  const { name, parentId, ownerUserId } = parseOrRedirect('departments', form, () => ({
    name: text(form, 'name', 200),
    parentId: optionalUuidText(form, 'parent_id'),
    ownerUserId: optionalUuidText(form, 'owner_user_id'),
  }));
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'org_manage')`;
    if (ownerUserId) {
      // Prevent retired/suspended users from being made the responsible person. Lock the target row
      // with FOR UPDATE before checking (closes the TOCTOU where another transaction changes status
      // after the check and before the INSERT). The DB trigger in 0043 is the real backstop.
      const owner = await sql<{ id: string }[]>`
        SELECT id FROM app.users
         WHERE tenant_id = app.current_tenant() AND id = ${ownerUserId}::uuid AND status = 'active'
         FOR UPDATE`;
      if (owner.length === 0) return 'inactive_owner' as const;
    }
    await sql`
      INSERT INTO app.departments (tenant_id, name, parent_id, owner_user_id, created_by, updated_by)
      VALUES (app.current_tenant(), ${name},
              ${parentId ? parentId : null}::uuid, ${ownerUserId ? ownerUserId : null}::uuid,
              app.current_session_user(), app.current_session_user())`;
    return 'ok' as const;
  });
  if (!result.ok) redirect(orgHref('departments', form, { error: result.reason }));
  if (result.data !== 'ok') redirect(orgHref('departments', form, { error: result.data }));
  revalidateOrganization();
  redirect(orgHref('departments', form, { saved: '1' }));
}

/**
 * Rename a department, change its parent department, or replace its head (manager).
 *
 * The old implementation had only INSERT, so a mistakenly created department could not be fixed.
 * Allowing the parent to change makes cycles possible, so detect and reject cycles here
 * (OrgChart's "cycle or hierarchy too deep" display is the last line of defense;
 * preventing creation comes first).
 */
export async function updateDepartment(form: FormData) {
  const { id, name, parentId, ownerUserId } = parseOrRedirect('departments', form, () => ({
    id: uuidText(form, 'department_id'),
    name: text(form, 'name', 200),
    parentId: optionalUuidText(form, 'parent_id'),
    ownerUserId: optionalUuidText(form, 'owner_user_id'),
  }));
  if (parentId === id) redirect(orgHref('departments', form, { error: 'department_cycle' }));
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'org_manage')`;
    if (ownerUserId) {
      const owner = await sql<{ id: string }[]>`
        SELECT id FROM app.users
         WHERE tenant_id = app.current_tenant() AND id = ${ownerUserId}::uuid AND status = 'active'
         FOR UPDATE`;
      if (owner.length === 0) return 'inactive_owner' as const;
    }
    if (parentId) {
      // Walk from the new parent to the root; if we come back to ourselves, it is a cycle.
      const cycle = await sql<{ cycle: boolean }[]>`
        WITH RECURSIVE ancestors(id, parent_id, depth) AS (
          SELECT d.id, d.parent_id, 1
            FROM app.departments d
           WHERE d.tenant_id = app.current_tenant() AND d.id = ${parentId}::uuid
          UNION ALL
          SELECT d.id, d.parent_id, a.depth + 1
            FROM app.departments d
            JOIN ancestors a ON a.parent_id = d.id
           WHERE d.tenant_id = app.current_tenant() AND a.depth < 50
        )
        SELECT bool_or(id = ${id}::uuid) AS cycle FROM ancestors`;
      if (cycle[0]?.cycle) return 'department_cycle' as const;
    }
    const rows = await sql<{ id: string }[]>`
      UPDATE app.departments
         SET name = ${name},
             parent_id = ${parentId ? parentId : null}::uuid,
             owner_user_id = ${ownerUserId ? ownerUserId : null}::uuid,
             updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid
       RETURNING id`;
    return rows.length === 1 ? ('ok' as const) : ('not_found' as const);
  });
  if (!result.ok) redirect(orgHref('departments', form, { error: result.reason }));
  if (result.data !== 'ok') redirect(orgHref('departments', form, { error: result.data }));
  revalidateOrganization();
  revalidatePath('/operations/access');
  redirect(orgHref('departments', form, { saved: '1' }));
}

export async function saveMembership(form: FormData) {
  const { userId, roleKey, departmentId, grantedAt } = parseOrRedirect('departments', form, () => ({
    userId: uuidText(form, 'user_id'),
    roleKey: roleKeyText(form, 'role_key'),
    departmentId: optionalUuidText(form, 'department_id'),
    grantedAt: optionalIsoDate(form, 'granted_at', '任命日') ?? todayJst(),
  }));
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'role_manage')`;
    // Lock the target user row with FOR UPDATE to serialize concurrent assignments to the same user.
    // Without the lock, 0005's auditor dual-role prohibition trigger misses each other's uncommitted rows.
    const lockedUser = await sql<{ id: string }[]>`
      SELECT id FROM app.users
       WHERE tenant_id = app.current_tenant() AND id = ${userId}::uuid AND status = 'active'
       FOR UPDATE`;
    if (lockedUser.length === 0) return 'inactive_user' as const;

    // (tenant_id, user_id, role_key) is UNIQUE. If a revoked row remains,
    // reassignment becomes a duplicate, so write it as un-revoking that row.
    const rows = await sql<{ id: string }[]>`
      INSERT INTO app.memberships
        (tenant_id, user_id, role_key, department_id, granted_at, granted_by, created_by, updated_by)
      VALUES (app.current_tenant(), ${userId}::uuid, ${roleKey},
              ${departmentId ? departmentId : null}::uuid,
              (${grantedAt}::date::timestamp AT TIME ZONE 'Asia/Tokyo'),
              app.current_session_user(), app.current_session_user(), app.current_session_user())
      ON CONFLICT (tenant_id, user_id, role_key) DO UPDATE
        SET revoked_at = NULL,
            department_id = EXCLUDED.department_id,
            granted_at = EXCLUDED.granted_at,
            granted_by = app.current_session_user(),
            updated_at = now(), updated_by = app.current_session_user()
      RETURNING id`;
    return rows.length > 0 ? ('ok' as const) : ('duplicate_membership' as const);
  });
  if (!result.ok) redirect(orgHref('departments', form, { error: result.reason }));
  if (result.data !== 'ok') redirect(orgHref('departments', form, { error: result.data }));
  revalidateOrganization();
  revalidatePath('/operations/access');
  redirect(orgHref('departments', form, { saved: '1' }));
}

/**
 * Add one member.
 *
 * app.set_tenant_context_for_proxy(0050) only admits "people with status='active' and
 * exactly 1 active membership". So this is an **operation that grants access**,
 * not adding a name to a displayed roster. Only owners and admins can run it (0059's
 * member_manage). Only owners may grant owner privileges themselves.
 */
export async function addMember(form: FormData) {
  const { displayName, email, role, departmentId } = parseOrRedirect('members', form, () => ({
    displayName: text(form, 'display_name', 200),
    email: emailText(form, 'email'),
    role: managementRole(form, 'role'),
    departmentId: optionalUuidText(form, 'department_id'),
  }));
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'member_manage')`;
    if (role === 'owner') {
      await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'role_manage')`;
    }
    const existing = await sql<{ id: string; status: string }[]>`
      SELECT id, status FROM app.users
       WHERE tenant_id = app.current_tenant() AND email = ${email}::citext
       FOR UPDATE`;
    if (existing.length > 0) return 'duplicate_email' as const;
    const created = await sql<{ id: string }[]>`
      INSERT INTO app.users (tenant_id, email, display_name, status, created_by, updated_by)
      VALUES (app.current_tenant(), ${email}::citext, ${displayName}, 'active',
              app.current_session_user(), app.current_session_user())
      RETURNING id`;
    const userId = created[0]?.id;
    if (!userId) throw new Error('member not created');
    await sql`
      INSERT INTO app.memberships
        (tenant_id, user_id, role_key, department_id, granted_by, created_by, updated_by)
      VALUES (app.current_tenant(), ${userId}::uuid, ${ROLE_KEY_FOR[role]},
              ${departmentId ? departmentId : null}::uuid,
              app.current_session_user(), app.current_session_user(), app.current_session_user())`;
    return 'ok' as const;
  });
  if (!result.ok) redirect(orgHref('members', form, { error: result.reason }));
  if (result.data !== 'ok') redirect(orgHref('members', form, { error: result.data }));
  revalidateOrganization();
  revalidatePath('/operations/access');
  revalidatePath('/operations/assignments');
  redirect(orgHref('members', form, { saved: '1' }));
}

/**
 * Replace a member's management role.
 *
 * Revoke all existing management roles, then re-create exactly one. With several, the
 * CASE in app.current_management_role() lets the higher one win, and the displayed and actual
 * permissions diverge. Auditors end up single-role due to 0005's dual-role prohibition trigger.
 */
export async function saveMemberRole(form: FormData) {
  const { userId, role } = parseOrRedirect('members', form, () => ({
    userId: uuidText(form, 'user_id'),
    role: managementRole(form, 'role'),
  }));
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'role_manage')`;
    // If owners drop to 0, role_manage passes for nobody and permissions can no longer be restored
    // from the UI. 0059's constraint trigger is the last line of defense, but being DEFERRED it only
    // fails at COMMIT and cannot give a reason. Check here first and return readable wording.
    if (role !== 'owner') {
      // Take a tenant-scoped advisory lock before counting. Otherwise two operations demoting different
      // owners at the same time each see "the other one remains" and both succeed.
      await sql`SELECT app.lock_owner_guard(app.current_tenant())`;
      const owners = await sql<{ n: number }[]>`
        SELECT count(*)::int AS n
          FROM app.memberships m JOIN app.users u
            ON u.tenant_id = m.tenant_id AND u.id = m.user_id
         WHERE m.tenant_id = app.current_tenant() AND m.role_key = 'ciso'
           AND m.revoked_at IS NULL AND u.status = 'active'
           AND m.user_id <> ${userId}::uuid`;
      if ((owners[0]?.n ?? 0) === 0) return 'last_owner' as const;
    }
    await sql`
      UPDATE app.memberships
         SET revoked_at = now(), updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND user_id = ${userId}::uuid
         AND role_key IN ('ciso','secretariat','risk_owner','employee','auditor')
         AND revoked_at IS NULL`;
    await sql`
      INSERT INTO app.memberships
        (tenant_id, user_id, role_key, granted_by, created_by, updated_by, revoked_at)
      VALUES (app.current_tenant(), ${userId}::uuid, ${ROLE_KEY_FOR[role]},
              app.current_session_user(), app.current_session_user(), app.current_session_user(), NULL)
      ON CONFLICT (tenant_id, user_id, role_key) DO UPDATE
        SET revoked_at = NULL, granted_by = app.current_session_user(),
            granted_at = now(), updated_at = now(), updated_by = app.current_session_user()`;
    return 'ok' as const;
  });
  if (!result.ok) redirect(orgHref('members', form, { error: result.reason }));
  if (result.data !== 'ok') redirect(orgHref('members', form, { error: result.data }));
  revalidateOrganization();
  revalidatePath('/operations/access');
  revalidatePath('/operations/assignments');
  redirect(orgHref('members', form, { saved: '1' }));
}

/**
 * Change membership status. Suspending blocks set_tenant_context_for_proxy =
 * effectively suspending access. You cannot suspend yourself (the moment you do, your own
 * permissions vanish, and one click could create a state nobody can undo).
 */
export async function setMemberStatus(form: FormData) {
  const { userId, status } = parseOrRedirect('members', form, () => {
    const value = text(form, 'status', 20);
    if (!['active', 'suspended', 'left'].includes(value)) throw new Error('status の形式が不正です');
    return { userId: uuidText(form, 'user_id'), status: value };
  });
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'member_manage')`;
    const self = await sql<{ id: string }[]>`SELECT app.current_session_user() AS id`;
    if (self[0]?.id === userId) return 'self_status' as const;
    if (status !== 'active') {
      await sql`SELECT app.lock_owner_guard(app.current_tenant())`;
      const owners = await sql<{ n: number }[]>`
        SELECT count(*)::int AS n
          FROM app.memberships m JOIN app.users u
            ON u.tenant_id = m.tenant_id AND u.id = m.user_id
         WHERE m.tenant_id = app.current_tenant() AND m.role_key = 'ciso'
           AND m.revoked_at IS NULL AND u.status = 'active'
           AND m.user_id <> ${userId}::uuid`;
      if ((owners[0]?.n ?? 0) === 0) return 'last_owner' as const;
    }
    const rows = await sql<{ id: string }[]>`
      UPDATE app.users
         SET status = ${status}, updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${userId}::uuid
       RETURNING id`;
    return rows.length === 1 ? ('ok' as const) : ('not_found' as const);
  });
  if (!result.ok) redirect(orgHref('members', form, { error: result.reason }));
  if (result.data !== 'ok') redirect(orgHref('members', form, { error: result.data }));
  revalidateOrganization();
  revalidatePath('/operations/access');
  revalidatePath('/operations/assignments');
  redirect(orgHref('members', form, { saved: '1' }));
}

export async function saveCertificationBody(form: FormData) {
  const {
    bodyName, certificationStandard, certificateNumber,
    initialCertifiedOn, lastAuditOn, nextAuditOn, contactInfo, sourceNote,
  } = parseOrRedirect('profile', form, () => {
    const initial = optionalIsoDate(form, 'initial_certified_on', '初回認証日');
    const last = optionalIsoDate(form, 'last_audit_on', '直近審査日');
    const next = optionalIsoDate(form, 'next_audit_on', '次回審査予定日');
    if (initial && last && initial > last) throw new Error('初回認証日は直近審査日より前である必要があります');
    if (last && next && last > next) throw new Error('直近審査日は次回審査予定日より前である必要があります');
    if (initial && next && initial > next) throw new Error('初回認証日は次回審査予定日より前である必要があります');
    return {
      bodyName: text(form, 'body_name', 200),
      certificationStandard: text(form, 'certification_standard', 200),
      certificateNumber: optionalText(form, 'certificate_number', 200) ?? '',
      initialCertifiedOn: initial,
      lastAuditOn: last,
      nextAuditOn: next,
      contactInfo: optionalText(form, 'contact_info', 2000) ?? '',
      sourceNote: optionalText(form, 'source_note', 2000) ?? '',
    };
  });
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'org_manage')`;
    await sql`
      INSERT INTO app.certification_bodies
        (tenant_id, body_name, certification_standard, certificate_number,
         initial_certified_on, last_audit_on, next_audit_on, contact_info, source_note,
         created_by, updated_by)
      VALUES
        (app.current_tenant(), ${bodyName}, ${certificationStandard}, ${certificateNumber},
         ${initialCertifiedOn}::date, ${lastAuditOn}::date, ${nextAuditOn}::date,
         ${contactInfo}, ${sourceNote}, app.current_session_user(), app.current_session_user())`;
  });
  if (!result.ok) redirect(orgHref('profile', form, { error: result.reason }));
  revalidateOrganization();
  revalidatePath('/wizard');
  redirect(orgHref('profile', form, { saved: '1' }));
}

// ------------------------------------------------------------------
// Systems in use (0061)
//
// The source of truth is app.application_catalog. Created in 0045 as the parent for ID/license integration
// and left empty, it has been promoted to the list of "systems we use".
// No new systems table is built, so as not to create a 4th "system-like thing" after
// app.vendors (outsourcing vendors) and assets.asset_type (free text);
// otherwise nobody could say which one is the source of truth.
// ------------------------------------------------------------------

/**
 * Build an app_key from the name.
 *
 * 0045's CHECK is `^[a-z0-9][a-z0-9_.-]{0,99}$`. The table is already applied, so
 * the constraint is left as is and this side produces values that satisfy it. **Users are not
 * asked to enter an app_key** (people on the ground use system names, not a key scheme).
 * In case nothing alphanumeric remains (e.g. Japanese names), use 'system' as the base when empty.
 */
function systemSlug(name: string): string {
  const base = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80);
  return /^[a-z0-9]/.test(base) ? base : 'system';
}

const SYSTEM_STATUSES = ['planned', 'active', 'paused', 'retired'] as const;

export async function saveSystem(form: FormData) {
  const { name, provider, status } = parseOrRedirect('systems', form, () => {
    const rawStatus = String(form.get('status') ?? 'active');
    if (!SYSTEM_STATUSES.includes(rawStatus as (typeof SYSTEM_STATUSES)[number])) {
      throw new Error('status の形式が不正です');
    }
    // provider is also normalized to lowercase alphanumerics to match 0045's CHECK. unknown if empty.
    const rawProvider = (optionalText(form, 'provider', 100) ?? '')
      .toLowerCase()
      .replace(/[^a-z0-9_.-]+/g, '-')
      .replace(/^-+|-+$/g, '');
    return {
      name: text(form, 'name', 200),
      provider: /^[a-z0-9]/.test(rawProvider) ? rawProvider : 'unknown',
      status: rawStatus,
    };
  });
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_system_edit_permission()`;
    // app_key is unique. If a system with the same name already exists, append a sequence number.
    const base = systemSlug(name);
    const taken = await sql<{ app_key: string }[]>`
      SELECT app_key FROM app.application_catalog
       WHERE tenant_id = app.current_tenant()
         AND (app_key = ${base} OR app_key LIKE ${base + '-%'})`;
    const used = new Set(taken.map((row) => row.app_key));
    let appKey = base;
    for (let n = 2; used.has(appKey) && n < 1000; n += 1) appKey = `${base}-${n}`;
    if (used.has(appKey)) return 'duplicate_system' as const;
    // 0045 revokes DML on application_catalog from app_rw, so
    // go through 0061's dedicated RPC instead of a direct INSERT.
    await sql`SELECT app.create_system(${appKey}, ${name}, ${provider}, ${status})`;
    return 'ok' as const;
  });
  if (!result.ok) redirect(orgHref('systems', form, { error: result.reason }));
  if (result.data !== 'ok') redirect(orgHref('systems', form, { error: result.data }));
  revalidateOrganization();
  revalidatePath('/risk-management/assets');
  revalidatePath('/operations/identity-access');
  redirect(orgHref('systems', form, { saved: '1' }));
}

export async function updateSystem(form: FormData) {
  const { id, name, provider, status } = parseOrRedirect('systems', form, () => {
    const rawStatus = String(form.get('status') ?? 'active');
    if (!SYSTEM_STATUSES.includes(rawStatus as (typeof SYSTEM_STATUSES)[number])) {
      throw new Error('status の形式が不正です');
    }
    const rawProvider = (optionalText(form, 'provider', 100) ?? '')
      .toLowerCase()
      .replace(/[^a-z0-9_.-]+/g, '-')
      .replace(/^-+|-+$/g, '');
    return {
      id: uuidText(form, 'application_id'),
      name: text(form, 'name', 200),
      provider: /^[a-z0-9]/.test(rawProvider) ? rawProvider : 'unknown',
      status: rawStatus,
    };
  });
  const result = await withTenantWrite(async (sql) => {
    // Before retiring, check whether any asset references it as its location.
    // Retiring while references remain yields a register where "information lives in a place that no longer exists".
    // The RPC has the same check and is the real backstop. This is an early check so we can
    // return readable wording.
    if (status === 'retired') {
      const linked = await sql<{ n: number }[]>`
        SELECT count(*)::int AS n FROM app.assets
         WHERE tenant_id = app.current_tenant() AND status = 'active'
           AND location_system_id = ${id}::uuid`;
      if ((linked[0]?.n ?? 0) > 0) return 'system_in_use' as const;
    }
    await sql`SELECT app.update_system(${id}::uuid, ${name}, ${provider}, ${status})`;
    return 'ok' as const;
  });
  if (!result.ok) redirect(orgHref('systems', form, { error: result.reason }));
  if (result.data !== 'ok') redirect(orgHref('systems', form, { error: result.data }));
  revalidateOrganization();
  revalidatePath('/risk-management/assets');
  redirect(orgHref('systems', form, { saved: '1' }));
}

/** How a department uses the system. Only record the usage (the asset register is the source of truth for the information handled). */
export async function saveDepartmentSystem(form: FormData) {
  const { departmentId, applicationId, usageNote } = parseOrRedirect('systems', form, () => ({
    departmentId: uuidText(form, 'department_id'),
    applicationId: uuidText(form, 'application_id'),
    usageNote: optionalText(form, 'usage_note', 2000) ?? '',
  }));
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_system_edit_permission()`;
    await sql`
      INSERT INTO app.department_systems
        (tenant_id, department_id, application_id, usage_note, created_by, updated_by)
      VALUES (app.current_tenant(), ${departmentId}::uuid, ${applicationId}::uuid, ${usageNote},
              app.current_session_user(), app.current_session_user())
      ON CONFLICT (tenant_id, department_id, application_id) DO UPDATE
        SET usage_note = EXCLUDED.usage_note`;
  });
  if (!result.ok) redirect(orgHref('systems', form, { error: result.reason }));
  revalidateOrganization();
  redirect(orgHref('systems', form, { saved: '1' }));
}

export async function removeDepartmentSystem(form: FormData) {
  const { departmentId, applicationId } = parseOrRedirect('departments', form, () => ({
    departmentId: uuidText(form, 'department_id'),
    applicationId: uuidText(form, 'application_id'),
  }));
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_system_edit_permission()`;
    await sql`
      DELETE FROM app.department_systems
       WHERE tenant_id = app.current_tenant()
         AND department_id = ${departmentId}::uuid
         AND application_id = ${applicationId}::uuid`;
  });
  if (!result.ok) redirect(orgHref('departments', form, { error: result.reason }));
  revalidateOrganization();
  redirect(orgHref('departments', form, { saved: '1' }));
}
