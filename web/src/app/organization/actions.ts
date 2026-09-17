'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { withTenantWrite } from '@/lib/tenant';

// 27c56ef で消える前の実装をそのまま土台にしている。入力検証の規約
// （切り詰めない・UUID と日付は形式で弾く・JST 基準の今日）は当時の
// Codex レビューで固まったものなので変えない。足したのはメンバーの
// 登録・停止・再開・部門の更新の 4 つ。

const text = (form: FormData, key: string, max = 1000): string => {
  const value = String(form.get(key) ?? '').trim();
  if (!value || value.length > max) throw new Error(`${key} is required`);
  return value;
};

// 上限超過は黙って切り詰めず拒否する(Codexレビュー2026-09-03指摘: 切り詰めは
// データの黙った改変になる)。呼び出し側でtry/catchしてフレンドリーな
// ?error=invalid_input へ寄せる。
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

// 0057 の app.current_management_role() と同じ写像。ここでロールを増やさない。
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

// citext なので大小は同一視されるが、表示と突合のために小文字へそろえてから入れる。
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const emailText = (form: FormData, key: string): string => {
  const value = text(form, key, 254).toLowerCase();
  if (!EMAIL_RE.test(value)) throw new Error(`${key} の形式が不正です`);
  return value;
};

// 0037以降で確立した方針をそのまま踏襲する。
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

// JST基準の「今日」。new Date().toISOString()はUTC基準なのでJST 0-9時に前日へ
// ずれる(画面①riskRegister.tsで確立した規約と同じ、Codexレビュー2026-09-03指摘)。
const todayJst = (): string => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Tokyo' }).format(new Date());

/**
 * 保存後にどのタブへ戻すか。
 *
 * 画面をマスタごとに割ったので、どの操作もひとつの /organization へ戻していると
 * 「部門を保存したらメンバー名簿に飛ばされる」ことになる。戻り先はアクション側に
 * 固定して持つ（フォームから貰う形にすると、隠しフィールドを付け忘れた画面が
 * 黙って既定のタブへ落ちる＝一番気づきにくい壊れ方をする）。
 */
const ORG_TAB = {
  members: '/organization',
  departments: '/organization/departments',
  systems: '/organization/systems',
  profile: '/organization/profile',
} as const;
type OrgTab = keyof typeof ORG_TAB;

const ORG_ROUTES = Object.values(ORG_TAB);

/** mode（isms / risk）はナビ全体の切り替えに使う。保存のたびに落としていると、
 *  リスク管理モードで作業している人が毎回 ISMS 側の並びへ戻される。 */
function orgHref(tab: OrgTab, form: FormData, params: Record<string, string>): string {
  const query = new URLSearchParams();
  const mode = String(form.get('_mode') ?? '').trim();
  if (mode === 'isms' || mode === 'risk') query.set('mode', mode);
  for (const [key, value] of Object.entries(params)) query.set(key, value);
  const qs = query.toString();
  return qs ? `${ORG_TAB[tab]}?${qs}` : ORG_TAB[tab];
}

/** 4 タブは同じデータを別の切り口で見ているだけなので、まとめて捨てる。
 *  「この操作はこのタブにしか響かない」を手で維持すると必ずどこかが古びる。 */
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
      // 退職・停止済みユーザーを責任者にできないようにする。FOR UPDATE で対象行を
      // ロックしてから確認する（確認後・INSERT前に別トランザクションが status を
      // 変える TOCTOU を塞ぐ）。0043 の DB トリガーが真のバックストップ。
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
 * 部門の改称・上位部門の変更・責任者（マネージャー）の差し替え。
 *
 * 旧実装は INSERT しか無く、間違えて作った部門を直せなかった。親を変えられる
 * ようにすると循環参照が作れてしまうので、ここで閉路を検出して拒む
 * （OrgChart 側の「循環参照または階層が深すぎる」表示は最後の砦であって、
 * そもそも作らせないのが先）。
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
      // 新しい親から根まで辿り、自分に戻ってきたら閉路。
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
    // 対象ユーザー行を FOR UPDATE でロックし、同一ユーザーへの同時割当を直列化する。
    // ロックが無いと 0005 の監査人兼任禁止トリガーが互いの未コミット行を見落とす。
    const lockedUser = await sql<{ id: string }[]>`
      SELECT id FROM app.users
       WHERE tenant_id = app.current_tenant() AND id = ${userId}::uuid AND status = 'active'
       FOR UPDATE`;
    if (lockedUser.length === 0) return 'inactive_user' as const;

    // (tenant_id, user_id, role_key) は UNIQUE。失効済みの行が残っていると
    // 再割当が duplicate になるので、失効を戻す形で書く。
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
 * メンバーを 1 人増やす。
 *
 * app.set_tenant_context_for_proxy(0050) は「status='active' かつ有効な所属が
 * ちょうど 1 件ある人」しか通さない。つまりここは**アクセス権を配る操作**であり、
 * 表示上の名簿追加ではない。オーナーと管理者だけが実行できる（0059 の
 * member_manage）。オーナー権限そのものを配れるのはオーナーだけにする。
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
 * メンバーの管理ロールを差し替える。
 *
 * 既存の管理ロールをすべて失効させてから 1 つだけ立て直す。複数立てると
 * app.current_management_role() の CASE で上位が勝ち、画面の表示と実際の
 * 権限が食い違う。監査人は 0005 の兼任禁止トリガーがあるので単独になる。
 */
export async function saveMemberRole(form: FormData) {
  const { userId, role } = parseOrRedirect('members', form, () => ({
    userId: uuidText(form, 'user_id'),
    role: managementRole(form, 'role'),
  }));
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'role_manage')`;
    // オーナーが 0 人になると role_manage が誰にも通らず、画面から権限を戻せなく
    // なる。0059 の制約トリガーが最後の砦だが、DEFERRED なので COMMIT 時にしか
    // 落ちず理由を出せない。ここで先に見て、読める言葉で返す。
    if (role !== 'owner') {
      // 数える前にテナント単位の助言ロックを取る。取らないと、別々のオーナーを
      // 同時に降ろす 2 つの操作が互いに「相手が残っている」と見て両方通る。
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
 * 在籍状態の変更。停止すると set_tenant_context_for_proxy を通れなくなる＝
 * 実質のアクセス停止。自分自身は止められない（止めた瞬間に自分の権限も消え、
 * 誰も戻せない状態を 1 クリックで作れてしまう）。
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
// 利用システム（0061）
//
// 正本は app.application_catalog。ID・ライセンス連携の親として 0045 で
// 作られたまま空だったものを「うちが使っているシステム」の一覧に昇格させた。
// 新しいシステム表を建てないのは、app.vendors（委託先）と
// assets.asset_type（自由記述）に続く 4 つ目の「システムらしきもの」を
// 作らないため。どれが正本か言えなくなる。
// ------------------------------------------------------------------

/**
 * 名称から app_key を作る。
 *
 * 0045 の CHECK は `^[a-z0-9][a-z0-9_.-]{0,99}$`。適用済みのテーブルなので
 * 制約は変えず、こちら側が満たす値を作る。**利用者に app_key を入力させない**
 * （現場が使うのはシステムの名前であって、キーの体系ではない）。
 * 日本語名など英数字が残らない場合に備えて、空になったら 'system' を土台にする。
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
    // provider も 0045 の CHECK に合わせて小文字英数へ寄せる。空なら unknown。
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
    // app_key は一意。同じ名前のシステムが既にあれば連番を足す。
    const base = systemSlug(name);
    const taken = await sql<{ app_key: string }[]>`
      SELECT app_key FROM app.application_catalog
       WHERE tenant_id = app.current_tenant()
         AND (app_key = ${base} OR app_key LIKE ${base + '-%'})`;
    const used = new Set(taken.map((row) => row.app_key));
    let appKey = base;
    for (let n = 2; used.has(appKey) && n < 1000; n += 1) appKey = `${base}-${n}`;
    if (used.has(appKey)) return 'duplicate_system' as const;
    // 0045 が app_rw から application_catalog の DML を剥奪しているので、
    // 直接 INSERT せず 0061 の専用 RPC を通す。
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
    // 廃止にする前に、所在場所として参照している資産が無いか見る。
    // 参照が残ったまま廃止すると「もう無い場所に情報がある」台帳になる。
    // RPC 側にも同じ検査があり、そちらが真のバックストップ。ここは読める
    // 言葉を返すための先出し。
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

/** 部門がそのシステムをどう使っているか。使い方だけを書く（扱う情報は資産台帳が正本）。 */
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
