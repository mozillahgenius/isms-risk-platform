'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { withTenantWrite } from '@/lib/tenant';
import { assignmentNotificationBody, queueMail } from '@/lib/mailOutbox';
import {
  ASSIGNMENT_ROLE_LABEL, RESOURCE_TYPES_FOR_WORK, WORK_TYPE_LABEL,
} from '@/lib/workAssignments';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const WORK_TYPES = Object.keys(WORK_TYPE_LABEL);
const ASSIGNMENT_ROLES = ['owner', 'editor', 'reviewer', 'approver'] as const;
const ASSIGNMENT_STATUSES = ['requested', 'accepted', 'in_progress', 'submitted', 'completed', 'declined', 'cancelled'] as const;

function value(form: FormData, key: string, max = 1000): string {
  const raw = String(form.get(key) ?? '').trim();
  if (!raw || raw.length > max) throw new Error(`${key} is required`);
  return raw;
}

function optional(form: FormData, key: string, max = 4000): string | null {
  const raw = String(form.get(key) ?? '').trim();
  return raw ? raw.slice(0, max) : null;
}

function route(form: FormData, path: string): string {
  const params = new URLSearchParams();
  const mode = String(form.get('mode') ?? '');
  if (mode === 'isms' || mode === 'risk') params.set('mode', mode);
  const scope = String(form.get('scope') ?? '');
  if (scope === 'mine') params.set('scope', 'mine');
  const query = params.toString();
  if (!query) return path;
  return `${path}${path.includes('?') ? '&' : '?'}${query}`;
}

function safeUuid(valueToCheck: string, key: string): string {
  if (!UUID.test(valueToCheck)) throw new Error(`invalid ${key}`);
  return valueToCheck;
}

function uuidList(form: FormData, key: string): string[] {
  return form.getAll(key)
    .map((item) => String(item).trim())
    .filter(Boolean)
    .map((item) => safeUuid(item, key));
}

/** 対象レコードは "<type>:<uuid>" の 1 値で来る。種別だけ差し替えられると困るため。 */
function parseTarget(form: FormData, workType: string): { type: string; id: string } | null {
  const raw = String(form.get('target') ?? '').trim();
  if (!raw) return null;
  const [type, id] = raw.split(':');
  const allowed = RESOURCE_TYPES_FOR_WORK[workType] ?? [];
  if (!allowed.includes(type)) throw new Error('invalid target');
  return { type, id: safeUuid(id ?? '', 'target') };
}

/**
 * 作業を作り、担当者へ配る。
 *
 * 担当者は「個人を選ぶ」と「部門を選ぶ」の両方から集める。部門を選んだ場合は
 * その時点で在籍している所属メンバーへ展開して固定する（後から部門の構成が
 * 変わっても、依頼済みの担当が勝手に増減しないようにする）。
 */
export async function saveAssignment(form: FormData) {
  const workType = value(form, 'work_type', 40);
  if (!WORK_TYPES.includes(workType)) throw new Error('invalid work_type');
  const pickedUsers = uuidList(form, 'assignee_user_id');
  const pickedDepartments = uuidList(form, 'department_id');
  if (pickedUsers.length === 0 && pickedDepartments.length === 0) {
    redirect(route(form, '/operations/assignments?error=no_assignee'));
  }
  const title = value(form, 'title', 240);
  const instructions = optional(form, 'instructions', 4000) ?? '';
  const assignmentRole = value(form, 'assignment_role', 20);
  if (!ASSIGNMENT_ROLES.includes(assignmentRole as (typeof ASSIGNMENT_ROLES)[number])) {
    throw new Error('invalid assignment_role');
  }
  const dueDate = optional(form, 'due_date', 10);
  const target = parseTarget(form, workType);
  const notify = String(form.get('notify') ?? '') === 'on';

  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'assign')`;

    const departmentMembers = pickedDepartments.length === 0 ? [] : await sql<{ user_id: string }[]>`
      SELECT DISTINCT m.user_id::text
        FROM app.memberships m
        JOIN app.users u ON u.tenant_id=m.tenant_id AND u.id=m.user_id
       WHERE m.tenant_id=app.current_tenant()
         AND m.department_id = ANY(${pickedDepartments}::uuid[])
         AND m.revoked_at IS NULL AND u.status='active'`;
    const assignees = [...new Set([...pickedUsers, ...departmentMembers.map((r) => r.user_id)])];
    if (assignees.length === 0) return { outcome: 'empty_department' as const };

    const rows = await sql<{ id: string }[]>`
      INSERT INTO app.work_items
        (tenant_id, work_type, title, instructions, due_date,
         resource_type, resource_id, created_by, updated_by)
      VALUES
        (app.current_tenant(), ${workType}, ${title}, ${instructions}, ${dueDate}::date,
         ${target?.type ?? null}, ${target?.id ?? null}::uuid,
         app.current_session_user(), app.current_session_user())
      RETURNING id`;
    const workItemId = rows[0]?.id;
    if (!workItemId) throw new Error('work item not created');

    for (const assignee of assignees) {
      await sql`
        INSERT INTO app.work_item_assignees
          (tenant_id, work_item_id, user_id, assignment_role, created_by, updated_by)
        VALUES
          (app.current_tenant(), ${workItemId}::uuid, ${assignee}::uuid, ${assignmentRole},
           app.current_session_user(), app.current_session_user())`;
    }

    if (notify) {
      await notifyAssignees(sql, {
        workItemId, assignees, workType, title, instructions, dueDate,
        assignmentRole, resourceLabel: target ? `${target.type}:${target.id}` : null,
      });
    }
    return { outcome: 'ok' as const };
  });

  if (!result.ok) redirect(route(form, `/operations/assignments?error=${result.reason}`));
  if (result.data.outcome !== 'ok') redirect(route(form, `/operations/assignments?error=${result.data.outcome}`));
  revalidatePath('/operations/assignments');
  redirect(route(form, '/operations/assignments?saved=1'));
}

async function notifyAssignees(
  sql: Parameters<Parameters<typeof withTenantWrite>[0]>[0],
  input: {
    workItemId: string; assignees: string[]; workType: string; title: string;
    instructions: string; dueDate: string | null; assignmentRole: string;
    resourceLabel: string | null;
  },
) {
  const requester = await sql<{ display_name: string }[]>`
    SELECT display_name FROM app.users
     WHERE tenant_id=app.current_tenant() AND id=app.current_session_user()`;
  const recipients = await sql<{ id: string; display_name: string; email: string }[]>`
    SELECT id, display_name, email::text FROM app.users
     WHERE tenant_id=app.current_tenant() AND id = ANY(${input.assignees}::uuid[])
       AND status='active'`;
  const label = await resourceLabelFor(sql, input.resourceLabel);
  for (const recipient of recipients) {
    await queueMail(sql, {
      purpose: 'work_assignment',
      toEmail: recipient.email,
      toName: recipient.display_name,
      subject: `【依頼】${input.title}`,
      bodyText: assignmentNotificationBody({
        assigneeName: recipient.display_name,
        requesterName: requester[0]?.display_name ?? '事務局',
        workTypeLabel: WORK_TYPE_LABEL[input.workType] ?? input.workType,
        title: input.title,
        instructions: input.instructions,
        resourceLabel: label,
        assignmentRoleLabel: ASSIGNMENT_ROLE_LABEL[input.assignmentRole] ?? input.assignmentRole,
        dueDate: input.dueDate,
      }),
      relatedType: 'work_item',
      relatedId: input.workItemId,
    });
  }
}

/** "<type>:<uuid>" を人が読める名前へ。見つからなければ通知本文から落とす。 */
async function resourceLabelFor(
  sql: Parameters<Parameters<typeof withTenantWrite>[0]>[0],
  target: string | null,
): Promise<string | null> {
  if (!target) return null;
  const [type, id] = target.split(':');
  const rows = await sql<{ label: string | null }[]>`
    SELECT CASE ${type}
      WHEN 'asset' THEN (SELECT asset_key || ' / ' || name FROM app.assets
                          WHERE tenant_id=app.current_tenant() AND id=${id}::uuid)
      WHEN 'risk' THEN (SELECT risk_key || ' / ' || summary FROM app.risk_scenarios
                         WHERE tenant_id=app.current_tenant() AND id=${id}::uuid)
      WHEN 'measure' THEN (SELECT measure_key || ' / ' || name FROM app.measures
                            WHERE tenant_id=app.current_tenant() AND id=${id}::uuid)
      WHEN 'incident' THEN (SELECT title FROM app.incidents
                             WHERE tenant_id=app.current_tenant() AND id=${id}::uuid)
      WHEN 'training' THEN (SELECT title FROM app.trainings
                             WHERE tenant_id=app.current_tenant() AND id=${id}::uuid)
      WHEN 'vendor' THEN (SELECT name FROM app.vendors
                           WHERE tenant_id=app.current_tenant() AND id=${id}::uuid)
      WHEN 'vendor_assessment' THEN (SELECT v.name || ' / ' || va.assessed_on::text
                                       FROM app.vendor_assessments va
                                       JOIN app.vendors v ON v.tenant_id=va.tenant_id AND v.id=va.vendor_id
                                      WHERE va.tenant_id=app.current_tenant() AND va.id=${id}::uuid)
      ELSE NULL END AS label`;
  return rows[0]?.label ?? null;
}

/** 作業を作ったあとで担当者を足す。部門指定もここで展開する。 */
export async function addAssignees(form: FormData) {
  const workItemId = safeUuid(value(form, 'work_item_id', 80), 'work_item_id');
  const pickedUsers = uuidList(form, 'assignee_user_id');
  const pickedDepartments = uuidList(form, 'department_id');
  const assignmentRole = value(form, 'assignment_role', 20);
  if (!ASSIGNMENT_ROLES.includes(assignmentRole as (typeof ASSIGNMENT_ROLES)[number])) {
    throw new Error('invalid assignment_role');
  }
  const notify = String(form.get('notify') ?? '') === 'on';
  if (pickedUsers.length === 0 && pickedDepartments.length === 0) {
    redirect(route(form, '/operations/assignments?error=no_assignee'));
  }
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'assign')`;
    const item = await sql<{
      work_type: string; title: string; instructions: string; due_date: string | null;
      resource_type: string | null; resource_id: string | null;
    }[]>`
      SELECT work_type, title, instructions, due_date::text,
             resource_type, resource_id::text
        FROM app.work_items
       WHERE tenant_id=app.current_tenant() AND id=${workItemId}::uuid
         AND status NOT IN ('completed','cancelled')
       FOR UPDATE`;
    if (item.length !== 1) return { outcome: 'not_found' as const };

    const departmentMembers = pickedDepartments.length === 0 ? [] : await sql<{ user_id: string }[]>`
      SELECT DISTINCT m.user_id::text
        FROM app.memberships m
        JOIN app.users u ON u.tenant_id=m.tenant_id AND u.id=m.user_id
       WHERE m.tenant_id=app.current_tenant()
         AND m.department_id = ANY(${pickedDepartments}::uuid[])
         AND m.revoked_at IS NULL AND u.status='active'`;
    const wanted = [...new Set([...pickedUsers, ...departmentMembers.map((r) => r.user_id)])];
    if (wanted.length === 0) return { outcome: 'empty_department' as const };

    const added: string[] = [];
    for (const assignee of wanted) {
      // 既に担当なら担当区分だけ変える。二重に依頼メールを送らないよう、
      // 新しく足りた人だけを通知対象にする。
      const rows = await sql<{ user_id: string }[]>`
        INSERT INTO app.work_item_assignees
          (tenant_id, work_item_id, user_id, assignment_role, created_by, updated_by)
        VALUES
          (app.current_tenant(), ${workItemId}::uuid, ${assignee}::uuid, ${assignmentRole},
           app.current_session_user(), app.current_session_user())
        ON CONFLICT (tenant_id, work_item_id, user_id) DO NOTHING
        RETURNING user_id::text`;
      if (rows.length === 1) added.push(assignee);
    }
    if (notify && added.length > 0) {
      await notifyAssignees(sql, {
        workItemId,
        assignees: added,
        workType: item[0].work_type,
        title: item[0].title,
        instructions: item[0].instructions,
        dueDate: item[0].due_date,
        assignmentRole,
        resourceLabel: item[0].resource_type && item[0].resource_id
          ? `${item[0].resource_type}:${item[0].resource_id}` : null,
      });
    }
    return { outcome: 'ok' as const };
  });
  if (!result.ok) redirect(route(form, `/operations/assignments?error=${result.reason}`));
  if (result.data.outcome !== 'ok') redirect(route(form, `/operations/assignments?error=${result.data.outcome}`));
  revalidatePath('/operations/assignments');
  redirect(route(form, '/operations/assignments?saved=1'));
}

export async function removeAssignee(form: FormData) {
  const workItemId = safeUuid(value(form, 'work_item_id', 80), 'work_item_id');
  const assignee = safeUuid(value(form, 'assignee_user_id', 80), 'assignee_user_id');
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'assign')`;
    // 担当が 0 人の作業を残さない。0 人になると誰も進められず、
    // 一覧には「依頼中」のまま居座る。
    const remaining = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n FROM app.work_item_assignees
       WHERE tenant_id=app.current_tenant() AND work_item_id=${workItemId}::uuid
         AND user_id <> ${assignee}::uuid`;
    if ((remaining[0]?.n ?? 0) === 0) return 'last_assignee' as const;
    const rows = await sql<{ user_id: string }[]>`
      DELETE FROM app.work_item_assignees
       WHERE tenant_id=app.current_tenant() AND work_item_id=${workItemId}::uuid
         AND user_id=${assignee}::uuid
       RETURNING user_id::text`;
    return rows.length === 1 ? ('ok' as const) : ('not_found' as const);
  });
  if (!result.ok) redirect(route(form, `/operations/assignments?error=${result.reason}`));
  if (result.data !== 'ok') redirect(route(form, `/operations/assignments?error=${result.data}`));
  revalidatePath('/operations/assignments');
  redirect(route(form, '/operations/assignments?saved=1'));
}

export async function cancelAssignment(form: FormData) {
  const workItemId = safeUuid(value(form, 'work_item_id', 80), 'work_item_id');
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'assign')`;
    const rows = await sql<{ id: string }[]>`
      UPDATE app.work_items
         SET status='cancelled', updated_at=now(), updated_by=app.current_session_user()
       WHERE tenant_id=app.current_tenant() AND id=${workItemId}::uuid
         AND status NOT IN ('completed','cancelled')
       RETURNING id`;
    if (rows.length !== 1) return 'not_found' as const;
    await sql`
      UPDATE app.work_item_assignees
         SET status='cancelled', updated_at=now(), updated_by=app.current_session_user()
       WHERE tenant_id=app.current_tenant() AND work_item_id=${workItemId}::uuid
         AND status NOT IN ('completed','declined','cancelled')`;
    return 'ok' as const;
  });
  if (!result.ok) redirect(route(form, `/operations/assignments?error=${result.reason}`));
  if (result.data !== 'ok') redirect(route(form, `/operations/assignments?error=${result.data}`));
  revalidatePath('/operations/assignments');
  redirect(route(form, '/operations/assignments?saved=1'));
}

export async function updateAssignment(form: FormData) {
  const workItemId = safeUuid(value(form, 'work_item_id', 80), 'work_item_id');
  const assignee = safeUuid(value(form, 'assignee_user_id', 80), 'assignee_user_id');
  const status = value(form, 'status', 30);
  if (!ASSIGNMENT_STATUSES.includes(status as (typeof ASSIGNMENT_STATUSES)[number])) throw new Error('invalid status');
  const completionNote = optional(form, 'completion_note', 4000) ?? '';
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_work_item_permission(${workItemId}::uuid, 'status')`;
    const rows = await sql<{ work_item_id: string }[]>`
      UPDATE app.work_item_assignees
         SET status=${status}, completion_note=${completionNote},
             completed_at=CASE WHEN ${status}='completed' THEN coalesce(completed_at, now()) ELSE NULL END,
             updated_at=now(), updated_by=app.current_session_user()
       WHERE tenant_id=app.current_tenant() AND work_item_id=${workItemId}::uuid
         AND user_id=${assignee}::uuid
       RETURNING work_item_id`;
    if (rows.length !== 1) throw new Error('assignment not found');
    await sql`
      UPDATE app.work_items
         SET status=CASE
                      WHEN NOT EXISTS (
                        SELECT 1 FROM app.work_item_assignees
                         WHERE tenant_id=app.current_tenant()
                           AND work_item_id=${workItemId}::uuid
                           AND status NOT IN ('completed','declined','cancelled')
                      ) THEN 'completed'
                      WHEN ${status} IN ('in_progress','submitted') THEN ${status}
                      ELSE status
                    END,
             updated_at=now(), updated_by=app.current_session_user()
       WHERE tenant_id=app.current_tenant() AND id=${workItemId}::uuid`;
    return rows[0].work_item_id;
  });
  if (!result.ok) redirect(route(form, `/operations/assignments?error=${result.reason}`));
  revalidatePath('/operations/assignments');
  redirect(route(form, '/operations/assignments?saved=1'));
}

/**
 * 権限管理画面（/operations/access）からのロール変更。
 *
 * 組織画面の saveMemberRole と同じ規則で動かす。最後のオーナーを降ろせない
 * のも同じ（0059 の制約トリガーが最後の砦）。
 */
export async function saveManagementRole(form: FormData) {
  const userId = safeUuid(value(form, 'user_id', 80), 'user_id');
  const role = value(form, 'role', 20);
  const roles = ['owner', 'admin', 'manager', 'member', 'auditor'] as const;
  if (!roles.includes(role as (typeof roles)[number])) throw new Error('invalid role');
  const roleMap: Record<(typeof roles)[number], string> = {
    owner: 'ciso', admin: 'secretariat', manager: 'risk_owner', member: 'employee', auditor: 'auditor',
  };
  const roleKey = roleMap[role as (typeof roles)[number]];
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'role_manage')`;
    if (role !== 'owner') {
      // 組織画面側と同じ理由でテナント単位に直列化する（0059 の制約トリガーが
      // 最後の砦だが、DEFERRED なので COMMIT 時にしか落ちず理由を出せない）。
      await sql`SELECT app.lock_owner_guard(app.current_tenant())`;
      const owners = await sql<{ n: number }[]>`
        SELECT count(*)::int AS n
          FROM app.memberships m JOIN app.users u
            ON u.tenant_id=m.tenant_id AND u.id=m.user_id
         WHERE m.tenant_id=app.current_tenant() AND m.role_key='ciso'
           AND m.revoked_at IS NULL AND u.status='active'
           AND m.user_id <> ${userId}::uuid`;
      if ((owners[0]?.n ?? 0) === 0) return 'last_owner' as const;
    }
    await sql`
      UPDATE app.memberships
         SET revoked_at=now(), updated_at=now(), updated_by=app.current_session_user()
       WHERE tenant_id=app.current_tenant() AND user_id=${userId}::uuid
         AND role_key IN ('ciso','secretariat','risk_owner','employee','auditor')
         AND revoked_at IS NULL`;
    await sql`
      INSERT INTO app.memberships
        (tenant_id, user_id, role_key, granted_by, created_by, updated_by, revoked_at)
      VALUES
        (app.current_tenant(), ${userId}::uuid, ${roleKey}, app.current_session_user(),
         app.current_session_user(), app.current_session_user(), NULL)
      ON CONFLICT (tenant_id, user_id, role_key) DO UPDATE
        SET revoked_at=NULL, granted_by=app.current_session_user(),
            granted_at=now(), updated_at=now(), updated_by=app.current_session_user()`;
    return 'ok' as const;
  });
  if (!result.ok) redirect(route(form, `/operations/access?error=${result.reason}`));
  if (result.data !== 'ok') redirect(route(form, `/operations/access?error=${result.data}`));
  revalidatePath('/operations/access');
  revalidatePath('/organization');
  revalidatePath('/operations/assignments');
  redirect(route(form, '/operations/access?saved=1'));
}
