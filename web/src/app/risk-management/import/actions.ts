'use server';

import { createHash } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import type { TransactionSql } from 'postgres';
import {
  IMPORT_LIMITS, capIssues, orderDepartments, parseCsv, validateAssets, validateAssignments, validateDepartments,
  validatePolicies, validateRisks,
  type AssetImportRow, type AssignmentImportRow, type DepartmentImportRow, type ImportKind, type PolicyImportRow,
  type RiskImportRow, type RowIssue,
} from '@/lib/csvImport';
import { withTenantActor, withTenantWrite } from '@/lib/tenant';

// Initial data import (design doc 2026-09-11 §8). Starting from assets and risks (design decision 2026-09-12).
//
// Flow: pick a file and "check the contents" (writes nothing) -> if there are no errors, "import"
//       (writes all rows in one transaction; if even one row fails, nothing is kept) -> "undo" if needed
//       (retires rows instead of deleting them; rows edited after import or referenced by other records are excluded and counted).
// A key that matches an existing one is an error, not an overwrite (re-running the same file creates nothing = idempotent; fix data in the existing screens).
// The write path is the same as the existing save (require_work_permission, set_management_frameworks_for_work).
// The file itself is not stored (only the hash, counts, and per-row results go into the import record 0071).
// Only owner / admin can import (the DB's records_role_allows('import') makes the final decision).
// Policies only get a draft version added (approval and activation happen only via approve_policy_version / activate_policy_version on the policy screen).
// Standard policies exist in every tenant, so for policies alone an overlap with an existing one is not an error; a version is added to that policy instead (design decision 2026-09-12).

export type PlanRow = { row: number; key: string; label: string };

export type ImportState = {
  stage: 'idle' | 'checked' | 'imported' | 'failed';
  kind: ImportKind;
  /** The checked contents. Sent back unchanged when importing (the server checks everything again). */
  csv: string;
  sha256: string;
  issues: RowIssue[];
  plan: PlanRow[];
  message: string;
  created?: number;
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO = 'ISO27001:2022';
const RISK_MANAGEMENT = 'RISK-MANAGEMENT';

const KINDS: readonly ImportKind[] = ['assets', 'risks', 'departments', 'assignments', 'policies'];
const readKind = (form: FormData): ImportKind => {
  const value = String(form.get('kind') ?? '');
  return (KINDS as readonly string[]).includes(value) ? (value as ImportKind) : 'assets';
};
// Normalize line breaks to LF before hashing. When the checked contents are sent back via the form, the browser converts line breaks to CRLF
// (without normalizing, the same contents would hash differently at check time and at import time).
const sha256Hex = (text: string): string =>
  createHash('sha256').update(text.replace(/\r\n?/g, '\n'), 'utf8').digest('hex');
const failed = (kind: ImportKind, message: string, issues: RowIssue[] = []): ImportState => ({
  stage: 'failed', kind, csv: '', sha256: '', issues, plan: [], message,
});
const byRow = (a: RowIssue, b: RowIssue) => a.row - b.row;

/** Reads the selected file as a UTF-8 string. Size and character encoding are checked here. */
async function readUpload(form: FormData): Promise<{ text: string } | { error: string }> {
  const file = form.get('file');
  if (!(file instanceof File) || file.size === 0) return { error: 'ファイルを選んでください' };
  if (file.size > IMPORT_LIMITS.maxBytes) return { error: `ファイルが大きすぎます（${IMPORT_LIMITS.maxBytes / 1_000_000} MB まで）` };
  try {
    return { text: new TextDecoder('utf-8', { fatal: true }).decode(await file.arrayBuffer()) };
  } catch {
    return { error: '文字コードは UTF-8 で保存してください（表計算ソフトなら「CSV UTF-8」で書き出す）' };
  }
}

type Examined = {
  issues: RowIssue[];
  plan: PlanRow[];
  assets: AssetImportRow[];
  risks: RiskImportRow[];
  /** Key of a risk's related asset -> asset ID (active assets only). */
  assetIds: Map<string, string>;
  departments: DepartmentImportRow[];
  /** Name of a registered parent department -> department ID (only names that occur exactly once). */
  parentIds: Map<string, string>;
  /** Owner's email -> user ID (active users only). */
  ownerIds: Map<string, string>;
  assignments: AssignmentImportRow[];
  /** Name of the target department -> department ID (only names that occur exactly once). */
  deptIds: Map<string, string>;
  /** User's email -> membership row that has not been revoked. */
  members: Map<string, { id: string; roleKey: string }[]>;
  policies: PolicyImportRow[];
  /** Policy row number -> existing policy to add a version to (null means create a new one), and the number of the version to add. */
  policyTargets: Map<number, { policyId: string | null; nextVersion: number }>;
};

type NamedDepartment = { name: string; id: string; n: number };

/** Looks up departments by name (names have no unique constraint, so also returns how many share the name). */
async function departmentsByName(sql: TransactionSql, names: string[]): Promise<Map<string, NamedDepartment>> {
  const rows = await sql<NamedDepartment[]>`
    SELECT name, min(id::text) AS id, count(*)::int AS n FROM app.departments
     WHERE tenant_id = app.current_tenant() AND name = ANY(${names}::text[]) GROUP BY name`;
  return new Map(rows.map((r) => [r.name, r]));
}

/**
 * Checks the contents (shape and values, plus duplicates against existing data and references, via the DB). Writes nothing.
 * lock: in the check right before importing, take a share lock on the referenced user rows (so a user suspended after the check is not made
 * an owner, and their membership is not edited; the suspension update waits until this transaction ends). Not used for read-only checks.
 */
async function examine(sql: TransactionSql, kind: ImportKind, text: string, lock = false): Promise<Examined> {
  const empty: Examined = {
    issues: [], plan: [], assets: [], risks: [], assetIds: new Map(), departments: [], parentIds: new Map(),
    ownerIds: new Map(), assignments: [], deptIds: new Map(), members: new Map(), policies: [], policyTargets: new Map(),
  };
  // Normalize line breaks to LF before reading. The browser converts them to CRLF when the checked contents are sent back via the form, so without this
  // line breaks inside quotes (such as policy bodies) differ between check time and import time, and CRs remain in the imported body.
  const parsed = parseCsv(text.replace(/\r\n?/g, '\n'));
  if (!parsed.ok) return { ...empty, issues: [{ row: 0, message: parsed.error }] };

  if (kind === 'assets') {
    const classes = (await sql<{ key: string }[]>`SELECT key FROM catalog.asset_classes_default ORDER BY key`).map((r) => r.key);
    const v = validateAssets(parsed.header, parsed.rows, classes);
    const keys = v.rows.map((r) => r.assetKey);
    const existing = new Set((await sql<{ asset_key: string }[]>`
      SELECT asset_key FROM app.assets WHERE tenant_id = app.current_tenant() AND asset_key = ANY(${keys}::text[])`)
      .map((r) => r.asset_key));
    for (const r of v.rows) {
      if (existing.has(r.assetKey)) {
        v.issues.push({ row: r.row, column: 'asset_key', message: 'この資産キーはもう登録されています（上書きしません。直すときは資産の画面で）' });
      }
    }
    const bad = new Set(v.issues.map((i) => i.row));
    const ok = v.rows.filter((r) => !bad.has(r.row));
    return { ...empty, issues: v.issues.sort(byRow), plan: ok.map((r) => ({ row: r.row, key: r.assetKey, label: r.name })), assets: ok };
  }

  if (kind === 'departments') {
    const v = validateDepartments(parsed.header, parsed.rows);
    const names = [...new Set(v.rows.flatMap((d) => [d.name, d.parentName]).filter(Boolean))];
    const existing = await departmentsByName(sql, names);
    const inFile = new Set(v.rows.map((d) => d.name));
    const emails = [...new Set(v.rows.map((d) => d.ownerEmail).filter(Boolean))];
    const ownerIds = new Map((await sql<{ id: string; email: string }[]>`
      SELECT id, lower(email::text) AS email FROM app.users
       WHERE tenant_id = app.current_tenant() AND status = 'active' AND lower(email::text) = ANY(${emails}::text[])
       ${lock ? sql`FOR SHARE` : sql``}`)
      .map((u) => [u.email, u.id] as const));
    const parentIds = new Map<string, string>();
    for (const d of v.rows) {
      if (existing.has(d.name)) {
        v.issues.push({ row: d.row, column: 'name', message: 'この名前の部署はもう登録されています（上書きしません。直すときは組織の画面で）' });
      }
      if (d.parentName && !inFile.has(d.parentName)) {
        const parent = existing.get(d.parentName);
        if (!parent) {
          v.issues.push({ row: d.row, column: 'parent_name', message: '上位の部署が見つかりません（登録済みの部署か、同じファイルの部署を指してください）' });
        } else if (parent.n > 1) {
          v.issues.push({ row: d.row, column: 'parent_name', message: '同じ名前の部署が複数あって上位が決まりません（組織の画面で名前を分けてから）' });
        } else {
          parentIds.set(d.parentName, parent.id);
        }
      }
      if (d.ownerEmail && !ownerIds.has(d.ownerEmail)) {
        v.issues.push({ row: d.row, column: 'owner_email', message: '在籍中の利用者が見つかりません' });
      }
    }
    const bad = new Set(v.issues.map((i) => i.row));
    const ok = v.rows.filter((d) => !bad.has(d.row));
    return {
      ...empty, issues: v.issues.sort(byRow),
      plan: ok.map((d) => ({ row: d.row, key: d.name, label: d.parentName ? `上位: ${d.parentName}` : '最上位' })),
      departments: ok, parentIds, ownerIds,
    };
  }

  if (kind === 'assignments') {
    const v = validateAssignments(parsed.header, parsed.rows);
    const depts = await departmentsByName(sql, [...new Set(v.rows.map((a) => a.departmentName))]);
    const emails = v.rows.map((a) => a.email);
    const memberRows = await sql<{ email: string; membership_id: string; role_key: string }[]>`
      SELECT lower(u.email::text) AS email, m.id AS membership_id, m.role_key
        FROM app.users u JOIN app.memberships m ON m.tenant_id = u.tenant_id AND m.user_id = u.id
       WHERE u.tenant_id = app.current_tenant() AND u.status = 'active' AND m.revoked_at IS NULL
         AND lower(u.email::text) = ANY(${emails}::text[])
       ${lock ? sql`FOR SHARE OF u` : sql``}`;
    const [{ role }] = await sql<{ role: string }[]>`SELECT app.current_management_role() AS role`;
    const members = new Map<string, { id: string; roleKey: string }[]>();
    for (const m of memberRows) {
      members.set(m.email, [...(members.get(m.email) ?? []), { id: m.membership_id, roleKey: m.role_key }]);
    }
    const deptIds = new Map<string, string>();
    for (const a of v.rows) {
      const d = depts.get(a.departmentName);
      if (!d) {
        v.issues.push({ row: a.row, column: 'department_name', message: '部署が見つかりません（先に部署を取り込むか、組織の画面で作ってください）' });
      } else if (d.n > 1) {
        v.issues.push({ row: a.row, column: 'department_name', message: '同じ名前の部署が複数あって決まりません（組織の画面で名前を分けてから）' });
      } else {
        deptIds.set(a.departmentName, d.id);
      }
      const rows = members.get(a.email) ?? [];
      if (rows.length === 0) {
        v.issues.push({ row: a.row, column: 'email', message: '在籍中で所属のある利用者が見つかりません（利用者は組織の画面で追加します）' });
      } else if (role !== 'owner' && rows.some((m) => m.roleKey === 'ciso')) {
        // The DB also lets only role_manage (owner) write the top-management row. Failing at write time cannot give a reason, so stop here.
        v.issues.push({ row: a.row, column: 'email', message: '最高責任者の所属は、オーナーだけが部署を割り当てられます' });
      }
    }
    const bad = new Set(v.issues.map((i) => i.row));
    const ok = v.rows.filter((a) => !bad.has(a.row));
    return {
      ...empty, issues: v.issues.sort(byRow),
      plan: ok.map((a) => ({ row: a.row, key: a.email, label: `→ ${a.departmentName}` })),
      assignments: ok, deptIds, members,
    };
  }

  if (kind === 'policies') {
    const v = validatePolicies(parsed.header, parsed.rows);
    const keys = [...new Set(v.rows.map((p) => p.catalogKey).filter(Boolean))];
    const titles = [...new Set(v.rows.filter((p) => !p.catalogKey).map((p) => p.title))];
    // Right before importing, lock the policy rows (so that after the version number is decided, no other version is added to the same policy;
    // adding a version takes a foreign-key share lock on the policy row, so it waits here).
    // Order: read -> lock the read policies in id order -> read again (Codex review 2026-09-12).
    //   A statement that waited on a lock reads the latest version from its pre-wait snapshot, so locking and reading are separate statements.
    //   Locks are taken in id order (the same order as undo; acquiring in opposite orders causes deadlock).
    //   If the re-read shows a policy that is not locked (one created during the check), do not import and ask for a re-check.
    type PolicyHit = {
      id: string; catalog_key: string | null; title: string; latest_version: number | null; latest_body: string | null;
    };
    const readPolicies = () => sql<PolicyHit[]>`
      SELECT p.id, p.catalog_key, p.title, lv.version AS latest_version, lv.body_md AS latest_body
        FROM app.policies p
        LEFT JOIN LATERAL (
          SELECT v.version, v.body_md FROM app.policy_versions v
           WHERE v.tenant_id = p.tenant_id AND v.policy_id = p.id ORDER BY v.version DESC LIMIT 1) lv ON true
       WHERE p.tenant_id = app.current_tenant()
         AND (p.catalog_key = ANY(${keys}::text[]) OR p.title = ANY(${titles}::text[]))`;
    let found: PolicyHit[] = await readPolicies();
    if (lock) {
      const locked = new Set(found.map((f) => f.id));
      await sql`
        SELECT id FROM app.policies
         WHERE tenant_id = app.current_tenant() AND id = ANY(${[...locked]}::uuid[])
         ORDER BY id FOR UPDATE`;
      found = await readPolicies();
      if (found.some((f) => !locked.has(f.id))) {
        return { ...empty, issues: [{ row: 0, message: '確かめている間に規程が追加されました。何も書き込んでいません。もう一度確かめてください' }] };
      }
    }
    const byKey = new Map(found.filter((f) => f.catalog_key).map((f) => [f.catalog_key as string, f]));
    const byTitle = new Map<string, PolicyHit[]>();
    for (const f of found) byTitle.set(f.title, [...(byTitle.get(f.title) ?? []), f]);
    const targets = new Map<number, { policyId: string | null; nextVersion: number }>();
    const usedBy = new Map<string, number>();
    const plan: PlanRow[] = [];
    for (const p of v.rows) {
      const column = p.catalogKey ? 'catalog_key' : 'title';
      let target: PolicyHit | null;
      if (p.catalogKey) {
        target = byKey.get(p.catalogKey) ?? null;
        if (!target) {
          v.issues.push({ row: p.row, column, message: 'この catalog_key の標準規程がありません（取り込みでは標準規程を作りません）' });
          continue;
        }
      } else {
        const hits = byTitle.get(p.title) ?? [];
        if (hits.length > 1) {
          v.issues.push({ row: p.row, column, message: '同じ題名の規程が複数あって決まりません（catalog_key で指してください）' });
          continue;
        }
        target = hits[0] ?? null;
      }
      if (target) {
        const first = usedBy.get(target.id);
        if (first !== undefined) {
          v.issues.push({ row: p.row, column, message: `${first} 行目と同じ規程を指しています（1 つの規程に 1 行）` });
          continue;
        }
        usedBy.set(target.id, p.row);
        // A body identical to the latest version is not added (re-running the same file creates nothing; the same applies when the standard body is imported as is).
        if ((target.latest_body ?? '').replace(/\r\n?/g, '\n').trim() === p.bodyMd) {
          v.issues.push({ row: p.row, column: 'body_md', message: '最新の版と同じ本文です（足す下書きがありません）' });
          continue;
        }
      }
      const nextVersion = (target?.latest_version ?? 0) + 1;
      targets.set(p.row, { policyId: target?.id ?? null, nextVersion });
      plan.push({
        row: p.row, key: p.catalogKey || p.title,
        label: target ? `既存の規程「${target.title}」に下書きを足す（v${nextVersion}）` : '規程を新しく作る（v1 の下書き）',
      });
    }
    return {
      ...empty, issues: v.issues.sort(byRow), plan,
      policies: v.rows.filter((p) => targets.has(p.row)), policyTargets: targets,
    };
  }

  const v = validateRisks(parsed.header, parsed.rows);
  const keys = v.rows.map((r) => r.riskKey);
  const existing = new Set((await sql<{ risk_key: string }[]>`
    SELECT risk_key FROM app.risk_scenarios WHERE tenant_id = app.current_tenant() AND risk_key = ANY(${keys}::text[])`)
    .map((r) => r.risk_key));
  const wanted = [...new Set(v.rows.flatMap((r) => r.assetKeys))];
  const assetIds = new Map((await sql<{ id: string; asset_key: string }[]>`
    SELECT id, asset_key FROM app.assets
     WHERE tenant_id = app.current_tenant() AND status = 'active' AND asset_key = ANY(${wanted}::text[])`)
    .map((r) => [r.asset_key, r.id] as const));
  for (const r of v.rows) {
    if (existing.has(r.riskKey)) {
      v.issues.push({ row: r.row, column: 'risk_key', message: 'このリスクキーはもう登録されています（上書きしません。直すときはリスクの画面で）' });
    }
    const missing = r.assetKeys.filter((k) => !assetIds.has(k));
    if (missing.length > 0) {
      v.issues.push({ row: r.row, column: 'asset_keys', message: `登録されていない（または廃止した）資産です: ${missing.join(', ')}。先に資産を取り込んでください` });
    }
  }
  const bad = new Set(v.issues.map((i) => i.row));
  const ok = v.rows.filter((r) => !bad.has(r.row));
  return {
    ...empty, issues: v.issues.sort(byRow), plan: ok.map((r) => ({ row: r.row, key: r.riskKey, label: r.theme })),
    risks: ok, assetIds,
  };
}

/** Checks the contents (writes nothing). */
export async function previewImport(_prev: ImportState, form: FormData): Promise<ImportState> {
  const kind = readKind(form);
  const upload = await readUpload(form);
  if ('error' in upload) return failed(kind, upload.error);
  const result = await withTenantActor(async (sql) => {
    const [{ allowed }] = await sql<{ allowed: boolean }[]>`SELECT app.records_role_allows('import') AS allowed`;
    if (!allowed) return null;
    return examine(sql, kind, upload.text);
  });
  if (!result.ok) return failed(kind, '本人と役割を確かめられませんでした。ページを開き直してください');
  if (result.data === null) return failed(kind, '取り込めるのは最高責任者・管理者だけです');
  const { plan } = result.data;
  const issues = capIssues(result.data.issues);
  return {
    stage: 'checked', kind, csv: upload.text, sha256: sha256Hex(upload.text), issues, plan,
    message: issues.length > 0
      ? `${issues.length} 件の誤りがあります。ファイルを直して、もう一度確かめてください（1 件でも誤りがあると取り込めません）`
      : plan.length > 0 ? `${plan.length} 件を取り込めます` : '取り込む行がありません',
  };
}

/** Imports the checked contents. The server checks everything again and writes all rows in one transaction. */
export async function applyImport(_prev: ImportState, form: FormData): Promise<ImportState> {
  const kind = readKind(form);
  const text = String(form.get('csv') ?? '');
  if (!text) return failed(kind, '確かめた中身がありません。ファイルを選んで、もう一度確かめてください');
  if (new TextEncoder().encode(text).length > IMPORT_LIMITS.maxBytes) return failed(kind, 'ファイルが大きすぎます');
  const sha256 = sha256Hex(text);
  // Import only exactly what was checked (compare the hash sent back by the screen with the hash of the received contents).
  // The contents are fully re-checked on the server before import, so this guards against a mismatch between the check result and the imported contents.
  if (String(form.get('checked_sha256') ?? '') !== sha256) {
    return failed(kind, '確かめた中身と取り込む中身が違います。ファイルを選んで、もう一度確かめてください');
  }
  const source = `CSV 取り込み（${new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10)}）`;

  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_records_role('import')`;
    // Imports for the same tenant run one at a time (department names have no unique constraint, so importing the same name concurrently
    // would have both see it as "not registered" and create a duplicate). Take the lock before checking (to see the result of an import that finished first).
    await sql`SELECT pg_advisory_xact_lock(hashtextextended('app.import:' || app.current_tenant()::text, 0))`;
    const ex = await examine(sql, kind, text, true);
    // If someone registered the same key after the check, this errors here (before writing, so nothing is kept).
    if (ex.issues.length > 0) return { issues: ex.issues, created: 0 };
    // Row count is CSV rows; item count is rows created (for assignments, membership rows updated). An assignment can cover multiple membership rows for one person.
    const rowCount = kind === 'assets' ? ex.assets.length : kind === 'risks' ? ex.risks.length
      : kind === 'departments' ? ex.departments.length : kind === 'policies' ? ex.policies.length : ex.assignments.length;
    // For policies, the details are the number of versions added plus the number of newly created policies.
    const count = kind === 'assignments'
      ? ex.assignments.reduce((n, a) => n + (ex.members.get(a.email)?.length ?? 0), 0)
      : kind === 'policies'
        ? ex.policies.length + ex.policies.filter((p) => !ex.policyTargets.get(p.row)?.policyId).length
        : rowCount;
    if (count === 0) return { issues: [{ row: 0, message: '取り込む行がありません' }], created: 0 };

    const [batch] = await sql<{ id: string }[]>`
      INSERT INTO app.import_batches (tenant_id, kind, file_sha256, row_count, created_count, imported_by)
      VALUES (app.current_tenant(), ${kind}, decode(${sha256}, 'hex'), ${rowCount}, ${count}, app.current_session_user())
      RETURNING id`;

    if (kind === 'assets') {
      await sql`SELECT app.require_work_permission('asset', NULL::uuid, 'create')`;
      for (const a of ex.assets) {
        const [asset] = await sql<{ id: string }[]>`
          INSERT INTO app.assets (tenant_id, asset_key, name, asset_type, description, classification, source_note, created_by, updated_by)
          VALUES (app.current_tenant(), ${a.assetKey}, ${a.name}, ${a.assetType}, ${a.description}, ${a.classification}, ${source},
                  app.current_session_user(), app.current_session_user())
          RETURNING id`;
        const frameworks = a.iso ? [RISK_MANAGEMENT, ISO] : [RISK_MANAGEMENT];
        await sql`SELECT app.set_management_frameworks_for_work('asset', ${asset.id}::uuid, ${frameworks}::text[])`;
        await sql`
          INSERT INTO app.import_batch_items (tenant_id, batch_id, row_no, target_type, target_id)
          VALUES (app.current_tenant(), ${batch.id}::uuid, ${a.row}, 'asset', ${asset.id}::uuid)`;
      }
    } else if (kind === 'risks') {
      await sql`SELECT app.require_work_permission('risk', NULL::uuid, 'create')`;
      for (const r of ex.risks) {
        const [risk] = await sql<{ id: string }[]>`
          INSERT INTO app.risk_scenarios (tenant_id, risk_key, domain, area, phase, theme, measure, frame, summary, status,
                                          created_by, updated_by)
          VALUES (app.current_tenant(), ${r.riskKey}, ${r.area}, ${r.area}, ${r.phase}, ${r.theme}, ${r.measure}, ${r.frame},
                  ${r.summary}, 'active', app.current_session_user(), app.current_session_user())
          RETURNING id`;
        const frameworks = r.iso ? [RISK_MANAGEMENT, ISO] : [RISK_MANAGEMENT];
        await sql`SELECT app.set_management_frameworks_for_work('risk_scenario', ${risk.id}::uuid, ${frameworks}::text[])`;
        // For related assets, the first is primary and the rest secondary (same order as the seed script).
        for (const [index, key] of r.assetKeys.entries()) {
          await sql`
            INSERT INTO app.risk_scenario_assets (tenant_id, risk_scenario_id, asset_id, relation)
            VALUES (app.current_tenant(), ${risk.id}::uuid, ${ex.assetIds.get(key)!}::uuid, ${index === 0 ? 'primary' : 'secondary'})`;
        }
        await sql`
          INSERT INTO app.import_batch_items (tenant_id, batch_id, row_no, target_type, target_id)
          VALUES (app.current_tenant(), ${batch.id}::uuid, ${r.row}, 'risk', ${risk.id}::uuid)`;
      }
    } else if (kind === 'departments') {
      // Department writes require the same permission as the existing save (the DB's guard_org_department also checks org_manage).
      await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'org_manage')`;
      const ids = new Map(ex.parentIds);
      for (const d of orderDepartments(ex.departments)) {
        const parentId = d.parentName ? ids.get(d.parentName) ?? null : null;
        const ownerId = d.ownerEmail ? ex.ownerIds.get(d.ownerEmail) ?? null : null;
        const [dept] = await sql<{ id: string }[]>`
          INSERT INTO app.departments (tenant_id, name, parent_id, owner_user_id, created_by, updated_by)
          VALUES (app.current_tenant(), ${d.name}, ${parentId}::uuid, ${ownerId}::uuid,
                  app.current_session_user(), app.current_session_user())
          RETURNING id`;
        ids.set(d.name, dept.id);
        await sql`
          INSERT INTO app.import_batch_items (tenant_id, batch_id, row_no, target_type, target_id)
          VALUES (app.current_tenant(), ${batch.id}::uuid, ${d.row}, 'department', ${dept.id}::uuid)`;
      }
    } else if (kind === 'policies') {
      // Only add a draft version. Existing versions are untouched (superseded_at is not set either; expiring is activation's job).
      // Detail rows are inserted in a statement separate from the one creating the rows (for every kind). The DB's detail guard (0077) checks the record of created rows
      // (written by an AFTER INSERT trigger at the end of the statement), so creating rows and details in one statement (WITH ... INSERT) is rejected.
      for (const p of ex.policies) {
        const target = ex.policyTargets.get(p.row)!;
        let policyId = target.policyId;
        if (!policyId) {
          const [created] = await sql<{ id: string }[]>`
            INSERT INTO app.policies (tenant_id, title, created_by, updated_by)
            VALUES (app.current_tenant(), ${p.title}, app.current_session_user(), app.current_session_user())
            RETURNING id`;
          policyId = created.id;
          await sql`
            INSERT INTO app.import_batch_items (tenant_id, batch_id, row_no, target_type, target_id)
            VALUES (app.current_tenant(), ${batch.id}::uuid, ${p.row}, 'policy', ${policyId}::uuid)`;
        }
        const [version] = await sql<{ id: string }[]>`
          INSERT INTO app.policy_versions (tenant_id, policy_id, version, body_md, diff_clause_count, created_by, updated_by)
          VALUES (app.current_tenant(), ${policyId}::uuid, ${target.nextVersion}, ${p.bodyMd}, 0,
                  app.current_session_user(), app.current_session_user())
          RETURNING id`;
        await sql`
          INSERT INTO app.import_batch_items (tenant_id, batch_id, row_no, target_type, target_id)
          VALUES (app.current_tenant(), ${batch.id}::uuid, ${p.row}, 'policy_version', ${version.id}::uuid)`;
      }
    } else {
      // Membership assignment writes only the department (not the role). Permission is member_manage, same as the DB's guard_org_membership
      // (role_manage for the top-management row; at check time this is already an error for imports by non-owners).
      await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'member_manage')`;
      for (const a of ex.assignments) {
        const deptId = ex.deptIds.get(a.departmentName)!;
        for (const m of ex.members.get(a.email) ?? []) {
          // Read the original department after locking the row (so undo does not restore to the wrong place even if it changed after the check).
          const [cur] = await sql<{ department_id: string | null }[]>`
            SELECT department_id FROM app.memberships
             WHERE tenant_id = app.current_tenant() AND id = ${m.id}::uuid AND revoked_at IS NULL FOR UPDATE`;
          if (!cur) throw new Error('membership changed during import');
          await sql`
            UPDATE app.memberships SET department_id = ${deptId}::uuid, updated_at = now(), updated_by = app.current_session_user()
             WHERE tenant_id = app.current_tenant() AND id = ${m.id}::uuid`;
          await sql`
            INSERT INTO app.import_batch_items
              (tenant_id, batch_id, row_no, target_type, target_id, prev_department_id, new_department_id)
            VALUES (app.current_tenant(), ${batch.id}::uuid, ${a.row}, 'membership', ${m.id}::uuid,
                    ${cur.department_id}::uuid, ${deptId}::uuid)`;
        }
      }
    }
    // On screen, counts for every kind are shown as CSV rows (the import record list also shows row counts; the detail count differs from the row count because for policies one row
    // becomes two, "create policy" and "add version", and for assignments it becomes one person's multiple memberships).
    return { issues: [] as RowIssue[], created: rowCount };
  });

  if (!result.ok) {
    return failed(kind, result.reason === 'invalid_session'
      ? '本人と役割を確かめられませんでした。ページを開き直してください'
      : '取り込めませんでした。何も書き込んでいません（同時に同じキーが登録された可能性があります。もう一度確かめてください）');
  }
  if (result.data.issues.length > 0) {
    return failed(kind, '確かめた後に内容が合わなくなりました。何も書き込んでいません。もう一度確かめてください', capIssues(result.data.issues));
  }
  revalidatePath('/risk-management');
  revalidatePath('/risk-management/import');
  revalidatePath('/iso27001');
  return {
    stage: 'imported', kind, csv: '', sha256, issues: [], plan: [], created: result.data.created,
    message: `${result.data.created} 件を取り込みました（取り込みの記録に残しました。間違えたときは下の一覧から取り消せます）`,
  };
}

/**
 * Undoes an import. Rows are retired, not deleted (evaluation, acceptance, and audit records are append-only, so deleting would break their links).
 * Rows edited after import or referenced by other records are user work, so they are not reverted and are counted as excluded.
 * "Not edited" means updated_at equals the import time (now() of the import transaction).
 * Comparing with "at or before" would misjudge rows edited after import by a transaction that started before the import (now() is the start time, so earlier than the import)
 * as not edited (Codex review 2026-09-12). Equality alone cannot distinguish edits from another transaction that started in the same microsecond
 * as the import, so also require that the last editor (updated_by) is the importer (import writes it at creation and assignment).
 * The only remaining misjudgment is when the importer themselves edited in another transaction started in the same microsecond.
 * Imports made before assets and risks wrote updated_by (before 6a89bd5) are excluded by this condition. That version never reached production,
 * and such imports exist only in verification DBs (no compatibility handling is kept).
 * Only once per import (the DB primary key also rejects it).
 */
export async function undoImport(form: FormData) {
  const batchId = String(form.get('batch_id') ?? '').trim();
  if (!UUID_RE.test(batchId)) redirect('/risk-management/import?error=invalid_input');
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_records_role('import')`;
    const [batch] = await sql<{ kind: string; undone: boolean }[]>`
      SELECT b.kind, EXISTS (SELECT 1 FROM app.import_undos u WHERE u.tenant_id = b.tenant_id AND u.batch_id = b.id) AS undone
        FROM app.import_batches b WHERE b.tenant_id = app.current_tenant() AND b.id = ${batchId}::uuid`;
    if (!batch) return 'not_found';
    if (batch.undone) return 'already_undone';
    if (batch.kind === 'departments') {
      await undoDepartments(sql, batchId);
      return `undone:${batch.kind}:${await recordUndo(sql, batchId)}`;
    }
    if (batch.kind === 'assignments') {
      await undoAssignments(sql, batchId);
      return `undone:${batch.kind}:${await recordUndo(sql, batchId)}`;
    }
    if (batch.kind === 'policies') {
      await undoPolicies(sql, batchId);
      return `undone:${batch.kind}:${await recordUndo(sql, batchId)}`;
    }
    // Retiring goes through the same permission check as the existing save.
    await sql`SELECT app.require_work_permission(${batch.kind === 'assets' ? 'asset' : 'risk'}, NULL::uuid, 'write')`;
    // Lock the rows to undo first with FOR UPDATE. Anything adding a reference (foreign-key check) takes a share lock on these rows, so
    // after the lock no references can be added concurrently. Check for references after locking (so nothing slips in between the check and retiring).
    if (batch.kind === 'assets') {
      await sql`
        SELECT a.id FROM app.assets a JOIN app.import_batch_items i ON i.tenant_id = a.tenant_id AND i.target_id = a.id
         WHERE i.tenant_id = app.current_tenant() AND i.batch_id = ${batchId}::uuid AND i.target_type = 'asset'
           FOR UPDATE OF a`;
    } else {
      await sql`
        SELECT r.id FROM app.risk_scenarios r JOIN app.import_batch_items i ON i.tenant_id = r.tenant_id AND i.target_id = r.id
         WHERE i.tenant_id = app.current_tenant() AND i.batch_id = ${batchId}::uuid AND i.target_type = 'risk'
           FOR UPDATE OF r`;
    }
    if (batch.kind === 'assets') {
      await sql`
          UPDATE app.assets a SET status = 'retired', updated_at = now()
            FROM app.import_batch_items i, app.import_batches b
           WHERE i.tenant_id = app.current_tenant() AND i.batch_id = ${batchId}::uuid AND i.target_type = 'asset'
             AND b.tenant_id = i.tenant_id AND b.id = i.batch_id
             AND a.tenant_id = i.tenant_id AND a.id = i.target_id AND a.status = 'active'
             AND a.updated_at = b.imported_at AND a.updated_by IS NOT DISTINCT FROM b.imported_by
             AND NOT EXISTS (SELECT 1 FROM app.risk_scenario_assets x WHERE x.tenant_id = a.tenant_id AND x.asset_id = a.id)
             AND NOT EXISTS (SELECT 1 FROM app.risk_scenarios x WHERE x.tenant_id = a.tenant_id AND x.asset_id = a.id)
             AND NOT EXISTS (SELECT 1 FROM app.vulnerabilities x WHERE x.tenant_id = a.tenant_id AND x.asset_id = a.id)
             AND NOT EXISTS (SELECT 1 FROM app.change_requests x WHERE x.tenant_id = a.tenant_id AND x.asset_id = a.id)
          RETURNING a.id`;
    } else {
      await sql`
          UPDATE app.risk_scenarios r SET status = 'retired', updated_at = now()
            FROM app.import_batch_items i, app.import_batches b
           WHERE i.tenant_id = app.current_tenant() AND i.batch_id = ${batchId}::uuid AND i.target_type = 'risk'
             AND b.tenant_id = i.tenant_id AND b.id = i.batch_id
             AND r.tenant_id = i.tenant_id AND r.id = i.target_id AND r.status = 'active'
             AND r.updated_at = b.imported_at AND r.updated_by IS NOT DISTINCT FROM b.imported_by
             AND NOT EXISTS (SELECT 1 FROM app.risk_assessments x WHERE x.tenant_id = r.tenant_id AND x.risk_scenario_id = r.id)
             AND NOT EXISTS (SELECT 1 FROM app.risk_acceptances x WHERE x.tenant_id = r.tenant_id AND x.risk_scenario_id = r.id)
             AND NOT EXISTS (SELECT 1 FROM app.risk_evaluation_snapshots x WHERE x.tenant_id = r.tenant_id AND x.risk_scenario_id = r.id)
             AND NOT EXISTS (SELECT 1 FROM app.risk_control_links x WHERE x.tenant_id = r.tenant_id AND x.risk_scenario_id = r.id)
             AND NOT EXISTS (SELECT 1 FROM app.finding_risk_scenarios x WHERE x.tenant_id = r.tenant_id AND x.risk_scenario_id = r.id)
             AND NOT EXISTS (SELECT 1 FROM app.incidents x WHERE x.tenant_id = r.tenant_id AND x.related_risk_id = r.id)
             AND NOT EXISTS (SELECT 1 FROM app.management_deviation_risks x WHERE x.tenant_id = r.tenant_id AND x.risk_scenario_id = r.id)
             -- 内部の受容の承認（internal_management_acceptance_approvals）は定義者だけが読める表なので見ない
             -- （app_rw から読むと権限エラーで取り消し全体が落ちる）。受容そのものは risk_acceptances で見ている。
          RETURNING r.id`;
    }
    return `undone:${batch.kind}:${await recordUndo(sql, batchId)}`;
  });
  if (!result.ok) redirect(`/risk-management/import?error=${result.reason}`);
  if (!String(result.data).startsWith('undone:')) redirect(`/risk-management/import?error=${result.data}`);
  const [, undoneKind, retiredCount, skippedCount] = String(result.data).split(':');
  revalidatePath('/risk-management');
  revalidatePath('/iso27001');
  revalidatePath('/organization');
  redirect(`/risk-management/import?kind=${undoneKind}&retired=${retiredCount}&skipped=${skippedCount}`);
}

/**
 * Records the undo and returns the counts computed by the DB (undone, excluded).
 * The counts are not the written values; the DB's INSERT trigger computes them (0072 / 0073).
 */
async function recordUndo(sql: TransactionSql, batchId: string): Promise<string> {
  await sql`
    INSERT INTO app.import_undos (tenant_id, batch_id, undone_by, retired_count, skipped_count)
    VALUES (app.current_tenant(), ${batchId}::uuid, app.current_session_user(), 0, 0)`;
  const [u] = await sql<{ retired_count: number; skipped_count: number }[]>`
    SELECT retired_count, skipped_count FROM app.import_undos
     WHERE tenant_id = app.current_tenant() AND batch_id = ${batchId}::uuid`;
  return `${u.retired_count}:${u.skipped_count}`;
}

/**
 * Undoes a department import. Deletes, from the bottom up, only departments not edited after import and not referenced anywhere.
 * department_systems is ON DELETE CASCADE, so deleting without checking would silently delete the department's system usage records too. Always check.
 */
async function undoDepartments(sql: TransactionSql, batchId: string): Promise<void> {
  await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'org_manage')`;
  // Lock the departments to undo first (makes foreign-key checks from referencing sides wait, so nothing slips in between the check and the delete).
  await sql`
    SELECT d.id FROM app.departments d
      JOIN app.import_batch_items i ON i.tenant_id = d.tenant_id AND i.target_id = d.id
     WHERE i.tenant_id = app.current_tenant() AND i.batch_id = ${batchId}::uuid AND i.target_type = 'department'
       FOR UPDATE OF d`;
  // Delete from the bottom up: repeat until no deletable departments remain (a parent becomes deletable on the pass after its children are gone).
  for (;;) {
    const deleted = await sql`
      DELETE FROM app.departments d
       USING app.import_batch_items i, app.import_batches b
       WHERE i.tenant_id = app.current_tenant() AND i.batch_id = ${batchId}::uuid AND i.target_type = 'department'
         AND b.tenant_id = i.tenant_id AND b.id = i.batch_id
         AND d.tenant_id = i.tenant_id AND d.id = i.target_id AND d.updated_at = b.imported_at
         AND d.updated_by IS NOT DISTINCT FROM b.imported_by
         AND NOT EXISTS (SELECT 1 FROM app.departments x WHERE x.tenant_id = d.tenant_id AND x.parent_id = d.id)
         AND NOT EXISTS (SELECT 1 FROM app.memberships x WHERE x.tenant_id = d.tenant_id AND x.department_id = d.id)
         AND NOT EXISTS (SELECT 1 FROM app.assets x WHERE x.tenant_id = d.tenant_id AND x.owner_department_id = d.id)
         AND NOT EXISTS (SELECT 1 FROM app.measures x WHERE x.tenant_id = d.tenant_id AND x.owner_department_id = d.id)
         AND NOT EXISTS (SELECT 1 FROM app.risk_scenarios x WHERE x.tenant_id = d.tenant_id AND x.department_id = d.id)
         AND NOT EXISTS (SELECT 1 FROM app.department_systems x WHERE x.tenant_id = d.tenant_id AND x.department_id = d.id)
      RETURNING d.id`;
    if (deleted.length === 0) break;
  }
}

/**
 * Undoes a policy import. Deletes only versions that are unapproved and not activated, not edited after import, have no acknowledgements, and are still
 * the latest version of that policy (deleting a middle version would break sequential version numbers). Policies created by the import are deleted only
 * when no versions remain (do not leave policies without versions). Policies that existed before the import (including standard policies) are not deleted.
 * Tables readable only by the definer (internal_management_*) reference only approved versions, so they are not checked here. If a reference exists anyway,
 * the foreign key rejects the delete and the whole undo fails without changing anything (erring on the side of not deleting silently).
 */
async function undoPolicies(sql: TransactionSql, batchId: string): Promise<void> {
  // Lock policies and versions first (adding a new version, approval, and acknowledgement each take a lock on the policy or version row,
  // so nothing slips in between the check and the delete).
  await sql`
    SELECT p.id FROM app.policies p
     WHERE p.tenant_id = app.current_tenant()
       AND p.id IN (SELECT v.policy_id FROM app.policy_versions v
                      JOIN app.import_batch_items i ON i.tenant_id = v.tenant_id AND i.target_id = v.id
                     WHERE i.tenant_id = app.current_tenant() AND i.batch_id = ${batchId}::uuid
                       AND i.target_type = 'policy_version')
     ORDER BY p.id
       FOR UPDATE OF p`;
  await sql`
    SELECT v.id FROM app.policy_versions v
      JOIN app.import_batch_items i ON i.tenant_id = v.tenant_id AND i.target_id = v.id
     WHERE i.tenant_id = app.current_tenant() AND i.batch_id = ${batchId}::uuid AND i.target_type = 'policy_version'
     ORDER BY v.id
       FOR UPDATE OF v`;
  await sql`
    DELETE FROM app.policy_versions v
     USING app.import_batch_items i, app.import_batches b
     WHERE i.tenant_id = app.current_tenant() AND i.batch_id = ${batchId}::uuid AND i.target_type = 'policy_version'
       AND b.tenant_id = i.tenant_id AND b.id = i.batch_id
       AND v.tenant_id = i.tenant_id AND v.id = i.target_id
       AND v.approved_at IS NULL AND v.effective_from IS NULL AND v.superseded_at IS NULL
       AND v.updated_at = b.imported_at AND v.updated_by IS NOT DISTINCT FROM b.imported_by
       AND NOT EXISTS (SELECT 1 FROM app.policy_versions x
                        WHERE x.tenant_id = v.tenant_id AND x.policy_id = v.policy_id AND x.version > v.version)
       AND NOT EXISTS (SELECT 1 FROM app.policy_acknowledgements x
                        WHERE x.tenant_id = v.tenant_id AND x.policy_version_id = v.id)`;
  await sql`
    DELETE FROM app.policies p
     USING app.import_batch_items i
     WHERE i.tenant_id = app.current_tenant() AND i.batch_id = ${batchId}::uuid AND i.target_type = 'policy'
       AND p.tenant_id = i.tenant_id AND p.id = i.target_id
       AND NOT EXISTS (SELECT 1 FROM app.policy_versions x WHERE x.tenant_id = p.tenant_id AND x.policy_id = p.id)`;
}

/**
 * Undoes membership assignments. Restores to the original department only rows still in the imported department, not edited since, and not revoked.
 * Rows whose original department is gone and (when undone by a non-owner) the top-management row are counted as excluded.
 */
async function undoAssignments(sql: TransactionSql, batchId: string): Promise<void> {
  await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'member_manage')`;
  const [{ role }] = await sql<{ role: string }[]>`SELECT app.current_management_role() AS role`;
  await sql`
    SELECT m.id FROM app.memberships m
      JOIN app.import_batch_items i ON i.tenant_id = m.tenant_id AND i.target_id = m.id
     WHERE i.tenant_id = app.current_tenant() AND i.batch_id = ${batchId}::uuid AND i.target_type = 'membership'
       FOR UPDATE OF m`;
  await sql`
    UPDATE app.memberships m
       SET department_id = i.prev_department_id, updated_at = now(), updated_by = app.current_session_user()
      FROM app.import_batch_items i, app.import_batches b
     WHERE i.tenant_id = app.current_tenant() AND i.batch_id = ${batchId}::uuid AND i.target_type = 'membership'
       AND b.tenant_id = i.tenant_id AND b.id = i.batch_id
       AND m.tenant_id = i.tenant_id AND m.id = i.target_id AND m.revoked_at IS NULL
       AND m.department_id IS NOT DISTINCT FROM i.new_department_id AND m.updated_at = b.imported_at
       AND m.updated_by IS NOT DISTINCT FROM b.imported_by
       AND (i.prev_department_id IS NULL
            OR EXISTS (SELECT 1 FROM app.departments d WHERE d.tenant_id = i.tenant_id AND d.id = i.prev_department_id))
       AND (m.role_key <> 'ciso' OR ${role === 'owner'}::boolean)`;
}
