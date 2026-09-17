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

// 初期データの取り込み（設計書 2026-09-11 §8）。資産とリスクから（2026-09-12 goto-twin 決定）。
//
// 流れ: ファイルを選んで「内容を確かめる」（何も書かない）→ 誤りが無ければ「取り込む」
//       （全件を 1 トランザクションで書く。1 行でも失敗したら何も残らない）→ 必要なら「取り消す」
//       （行を消さずに退役させる。取り込み後に直された行・他の記録が参照している行は対象外にして数える）。
// 既存と同じキーは上書きせず誤りにする（同じファイルをもう一度流しても何も作られない＝冪等。直すのは既存の画面で）。
// 書く経路は既存の保存と同じ（require_work_permission・set_management_frameworks_for_work）。
// ファイル本体は保存しない（ハッシュ・件数・行の結果だけを取り込みの記録 0071 に残す）。
// 取り込めるのは owner / admin（DB の records_role_allows('import') が最終判断）。
// 規程は下書きの版を足すだけ（承認・有効化は規程の画面の approve_policy_version / activate_policy_version だけ）。
// 標準規程は全テナントに必ずあるので、規程だけは「既存と重なったら誤り」にせず、その規程に版を足す（2026-09-12 goto-twin 決定）。

export type PlanRow = { row: number; key: string; label: string };

export type ImportState = {
  stage: 'idle' | 'checked' | 'imported' | 'failed';
  kind: ImportKind;
  /** 確かめた中身。取り込むときに同じものを送り返す（サーバーはもう一度すべて確かめる）。 */
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
// 改行を LF にそろえてからハッシュにする。確かめた中身をフォームで送り返すと、ブラウザが改行を CRLF に変えるため
// （そろえないと、同じ中身なのに確かめた時と取り込んだ時でハッシュが変わる）。
const sha256Hex = (text: string): string =>
  createHash('sha256').update(text.replace(/\r\n?/g, '\n'), 'utf8').digest('hex');
const failed = (kind: ImportKind, message: string, issues: RowIssue[] = []): ImportState => ({
  stage: 'failed', kind, csv: '', sha256: '', issues, plan: [], message,
});
const byRow = (a: RowIssue, b: RowIssue) => a.row - b.row;

/** 選ばれたファイルを UTF-8 の文字列として読む。大きさと文字コードをここで確かめる。 */
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
  /** リスクの関連資産のキー → 資産 ID（有効な資産だけ）。 */
  assetIds: Map<string, string>;
  departments: DepartmentImportRow[];
  /** 登録済みの上位部署の名前 → 部署 ID（同じ名前が 1 つだけのもの）。 */
  parentIds: Map<string, string>;
  /** 責任者のメール → 利用者 ID（在籍中だけ）。 */
  ownerIds: Map<string, string>;
  assignments: AssignmentImportRow[];
  /** 割り当て先の部署の名前 → 部署 ID（同じ名前が 1 つだけのもの）。 */
  deptIds: Map<string, string>;
  /** 利用者のメール → 失効していない所属の行。 */
  members: Map<string, { id: string; roleKey: string }[]>;
  policies: PolicyImportRow[];
  /** 規程の行番号 → 版を足す既存の規程（null は新しく作る）と、足す版の番号。 */
  policyTargets: Map<number, { policyId: string | null; nextVersion: number }>;
};

type NamedDepartment = { name: string; id: string; n: number };

/** 部署を名前で引く（名前に一意制約が無いので、同じ名前が何件あるかも返す）。 */
async function departmentsByName(sql: TransactionSql, names: string[]): Promise<Map<string, NamedDepartment>> {
  const rows = await sql<NamedDepartment[]>`
    SELECT name, min(id::text) AS id, count(*)::int AS n FROM app.departments
     WHERE tenant_id = app.current_tenant() AND name = ANY(${names}::text[]) GROUP BY name`;
  return new Map(rows.map((r) => [r.name, r]));
}

/**
 * 中身を確かめる（形・値に加え、既存との重複と参照を DB で確かめる）。書き込みはしない。
 * lock: 取り込む直前の確かめでは、指した利用者の行を共有ロックする（確かめた後に停止されて、停止した人を責任者にしたり
 * その人の所属を直したりしない。停止の更新はこのトランザクションが終わるまで待つ）。読み取り専用の確かめでは付けない。
 */
async function examine(sql: TransactionSql, kind: ImportKind, text: string, lock = false): Promise<Examined> {
  const empty: Examined = {
    issues: [], plan: [], assets: [], risks: [], assetIds: new Map(), departments: [], parentIds: new Map(),
    ownerIds: new Map(), assignments: [], deptIds: new Map(), members: new Map(), policies: [], policyTargets: new Map(),
  };
  // 改行を LF にそろえてから読む。確かめた中身をフォームで送り返すとブラウザが CRLF に変えるので、そろえないと
  // 引用符の中の改行（規程の本文など）が確かめた時と取り込んだ時で変わり、取り込んだ本文に CR が残る。
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
        // DB も最高責任者の行は role_manage（オーナー）でしか書かせない。書く段階で落ちると理由を出せないので、ここで止める。
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
    // 取り込む直前は規程の行をロックする（版の番号を決めた後に、同じ規程へ別の版が足されないように。
    // 版の追加は規程の行へ外部キーの共有ロックを取るので、ここで待たされる）。
    // 読む → 読んだ規程を id の順にロック → 読み直す、の順にする（Codex レビュー 2026-09-12）。
    //   ロックを待った文は待つ前のスナップショットのまま最新の版を読むので、ロックと読み取りは別の文にする。
    //   ロックは id の順（取り消しと同じ順。逆順に取り合うとデッドロックになる）。
    //   読み直しで、ロックしていない規程（確かめている間に作られた規程）が出たら、取り込まずに確かめ直してもらう。
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
        // 最新の版と同じ本文は足さない（同じファイルを流し直しても何も作られない。標準本文をそのまま入れた場合も同じ）。
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

/** 内容を確かめる（何も書かない）。 */
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

/** 確かめた中身を取り込む。サーバーでもう一度すべて確かめ、全件を 1 トランザクションで書く。 */
export async function applyImport(_prev: ImportState, form: FormData): Promise<ImportState> {
  const kind = readKind(form);
  const text = String(form.get('csv') ?? '');
  if (!text) return failed(kind, '確かめた中身がありません。ファイルを選んで、もう一度確かめてください');
  if (new TextEncoder().encode(text).length > IMPORT_LIMITS.maxBytes) return failed(kind, 'ファイルが大きすぎます');
  const sha256 = sha256Hex(text);
  // 確かめた中身と同じものだけを取り込む（画面が送り返したハッシュと、受け取った中身のハッシュを突き合わせる）。
  // 中身は取り込む前にサーバーでもう一度すべて確かめるので、ここは「確かめた結果と取り込む中身の食い違い」を防ぐ役。
  if (String(form.get('checked_sha256') ?? '') !== sha256) {
    return failed(kind, '確かめた中身と取り込む中身が違います。ファイルを選んで、もう一度確かめてください');
  }
  const source = `CSV 取り込み（${new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10)}）`;

  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_records_role('import')`;
    // 同じテナントの取り込みは 1 つずつ（部署の名前には一意制約が無いので、同時に同じ名前を取り込むと、
    // どちらも「未登録」と確かめて重複を作る）。ロックを取ってから確かめる（先に終わった取り込みの結果を見る）。
    await sql`SELECT pg_advisory_xact_lock(hashtextextended('app.import:' || app.current_tenant()::text, 0))`;
    const ex = await examine(sql, kind, text, true);
    // 確かめた後に誰かが同じキーを登録していたら、ここで誤りになる（書く前なので何も残らない）。
    if (ex.issues.length > 0) return { issues: ex.issues, created: 0 };
    // 行数は CSV の行、件数は作った（割り当てでは直した所属の）行。割り当ては 1 人が複数の所属の行を持てる。
    const rowCount = kind === 'assets' ? ex.assets.length : kind === 'risks' ? ex.risks.length
      : kind === 'departments' ? ex.departments.length : kind === 'policies' ? ex.policies.length : ex.assignments.length;
    // 規程は、足す版の数に、新しく作る規程の数を足した明細になる。
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
        // 関連資産は、最初の 1 つを主、残りを従にする（初期投入スクリプトと同じ並び）。
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
      // 部署の書き込みは既存の保存と同じ権限（DB の guard_org_department も org_manage を確かめる）。
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
      // 下書きの版を足すだけ。既存の版には触れない（superseded_at も打たない。失効は有効化の役目）。
      // 明細は、行を作る文とは別の文で入れる（どの種類も同じ）。DB の明細の守り（0077）は、作った行の記録
      // （AFTER INSERT のトリガが文の終わりに書く）を見るので、作成と明細を 1 つの文（WITH ... INSERT）にすると拒否される。
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
      // 所属の割り当ては部署だけを書く（役割は書かない）。権限は DB の guard_org_membership と同じ member_manage
      // （最高責任者の行は role_manage。確かめる段階で、オーナー以外の取り込みでは誤りにしてある）。
      await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'member_manage')`;
      for (const a of ex.assignments) {
        const deptId = ex.deptIds.get(a.departmentName)!;
        for (const m of ex.members.get(a.email) ?? []) {
          // 元の部署は行をロックしてから読む（確かめた後に変わっていても、取り消しで戻す先を取り違えない）。
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
    // 画面の件数はどの種類も CSV の行で見せる（取り込みの記録の一覧も行数を出す。明細の数は、規程では 1 行が
    // 「規程を作る」と「版を足す」の 2 つに、割り当てでは 1 人の複数の所属になり、行数と食い違うため）。
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
 * 取り込みを取り消す。行は消さず、退役させる（評価・受容・監査の記録は追記だけなので、消すと結び付きが切れる）。
 * 取り込み後に直された行・他の記録が参照している行は、利用者の成果物なので戻さず、対象外として数える。
 * 「直されていない」は updated_at が取り込みの時刻（取り込みのトランザクションの now()）と等しいことで見る。
 * 「以前」で比べると、取り込みより前に始まったトランザクションが取り込み後に直した行（now() は開始時刻なので取り込みより前）を
 * 直されていないと取り違える（Codex レビュー 2026-09-12）。等しさだけだと、取り込みと同じマイクロ秒に始まった別のトランザクションの
 * 編集を見分けられないので、最後に直した人（updated_by）が取り込んだ人であることも見る（取り込みは作成・割り当ての時に書く）。
 * 残る取り違えは「取り込んだ本人が、同じマイクロ秒に始めた別のトランザクションで直した」場合だけ。
 * 資産・リスクの updated_by を書く前（6a89bd5 より前）の取り込みは、この条件では対象外になる。その版は本番に出ておらず、
 * 該当する取り込みは検証用の DB にしか無い（互換の処理は置かない）。
 * 1 回の取り込みに 1 回だけ（DB の主キーでも拒否する）。
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
    // 退役は既存の保存と同じ権限の確かめを通す。
    await sql`SELECT app.require_work_permission(${batch.kind === 'assets' ? 'asset' : 'risk'}, NULL::uuid, 'write')`;
    // 取り消す行を先に FOR UPDATE でロックする。参照を足す側（外部キーの確かめ）はこの行に共有ロックを取るので、
    // ロックの後は同時に参照が足されない。参照が無いかの確かめはロックの後に行う（確かめと退役の間に割り込ませない）。
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
 * 取り消しの記録を残し、DB が数えた件数（取り消した・対象外）を返す。
 * 件数は書いた値ではなく DB の INSERT トリガが数える（0072 / 0073）。
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
 * 部署の取り込みを取り消す。取り込み後に直されておらず、どこからも参照されていない部署だけを、下位から消す。
 * department_systems は ON DELETE CASCADE なので、確かめずに消すと部署の利用システムの記録が黙って一緒に消える。必ず見る。
 */
async function undoDepartments(sql: TransactionSql, batchId: string): Promise<void> {
  await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'org_manage')`;
  // 取り消す部署を先にロックする（参照を足す側の外部キーの確かめを待たせ、確かめと削除の間に割り込ませない）。
  await sql`
    SELECT d.id FROM app.departments d
      JOIN app.import_batch_items i ON i.tenant_id = d.tenant_id AND i.target_id = d.id
     WHERE i.tenant_id = app.current_tenant() AND i.batch_id = ${batchId}::uuid AND i.target_type = 'department'
       FOR UPDATE OF d`;
  // 下位から消す: 消せる部署が無くなるまで繰り返す（上位は、下位が消えた次の回に消せるようになる）。
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
 * 規程の取り込みを取り消す。版は、未承認・未有効化で、取り込み後に直されておらず、周知確認が付いておらず、まだその規程の
 * 最新の版であるものだけを消す（途中の版を消すと版の番号の連番が崩れる）。取り込みで作った規程は、版が残っていないときだけ消す
 * （版の無い規程を残さない）。取り込み前からあった規程（標準規程を含む）は消さない。
 * 定義者だけが読める表（internal_management_*）が参照するのは承認済みの版なので、ここでは見ない。万一参照があれば
 * 外部キーが削除を拒否し、取り消し全体が何も変えずに失敗する（黙って消さない側に倒れる）。
 */
async function undoPolicies(sql: TransactionSql, batchId: string): Promise<void> {
  // 先に規程と版をロックする（新しい版の追加・承認・周知確認は、それぞれ規程か版の行にロックを取るので、
  // 確かめと削除の間に割り込ませない）。
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
 * 所属の割り当てを取り消す。今も取り込んだ部署のままで、その後に直されておらず、失効していない行だけを元の部署へ戻す。
 * 元の部署が消えている行・（オーナー以外が取り消すときの）最高責任者の行は対象外として数える。
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
