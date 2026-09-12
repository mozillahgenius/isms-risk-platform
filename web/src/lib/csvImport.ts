// Reading and validating CSV for initial data import (design doc 2026-09-11 §8).
// Only pure functions that do not touch the DB live here (to make them easy to test and to keep reading and writing separate).
//
// Of the safety design (§8.3), the parts handled here:
//   - Size limits (file size and row count). The values are provisional and will be revisited by measuring real imports (§0.2 "decide numbers by measurement").
//   - CSV formula injection protection: cells starting with = + - @ tab or newline are rejected
//     (because they would act as formulas if the imported values were later exported to and opened in a spreadsheet). Do not silently rewrite; return a row error.
//   - Checks for required columns, unknown columns, types, value ranges, lengths, and duplicates within the file.
// Duplicates against existing data, reference resolution (asset key -> asset), and writes are done in the server actions (they need the DB).

export const IMPORT_LIMITS = { maxBytes: 1_000_000, maxRows: 2_000, maxColumns: 50, maxIssues: 200 } as const;

/**
 * Cap the number of errors shown (even within 1 MB a file can produce a huge number of errors, so do not let processing and the screen balloon).
 * Anything beyond the cap is reported only as a count on one line.
 */
export function capIssues(issues: RowIssue[]): RowIssue[] {
  if (issues.length <= IMPORT_LIMITS.maxIssues) return issues;
  return [
    ...issues.slice(0, IMPORT_LIMITS.maxIssues),
    { row: 0, message: `ほかに ${issues.length - IMPORT_LIMITS.maxIssues} 件の誤りがあります（最初の ${IMPORT_LIMITS.maxIssues} 件だけ表示）` },
  ];
}

export type ImportKind = 'assets' | 'risks' | 'departments' | 'assignments' | 'policies';

/** A row error. row is the data row number excluding the header (1-based). 0 means an error in the whole file or the header. */
export type RowIssue = { row: number; column?: string; message: string };

export type CsvParseResult =
  | { ok: true; header: string[]; rows: { row: number; cells: string[] }[] }
  | { ok: false; error: string };

/**
 * Read RFC 4180 CSV (double-quoted cells, newlines inside cells, "" escapes).
 * Strip a leading BOM (added by spreadsheet apps' UTF-8 export). Skip rows with no content.
 */
export function parseCsv(text: string): CsvParseResult {
  const src = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const records: string[][] = [];
  let record: string[] = [];
  let cell = '';
  let quoted = false;
  let started = false;
  // Whether we just closed a quoted cell. A value where something other than a delimiter (, or newline) follows the closing quote is an error rather than silently reinterpreted
  // (reading "abc"def as abcdef would change the user's value without them knowing).
  let justClosed = false;
  for (let i = 0; i < src.length; i += 1) {
    const ch = src[i];
    if (quoted) {
      if (ch === '"') {
        if (src[i + 1] === '"') { cell += '"'; i += 1; } else { quoted = false; justClosed = true; }
      } else {
        cell += ch;
      }
      continue;
    }
    if (justClosed && ch !== ',' && ch !== '\r' && ch !== '\n') {
      return { ok: false, error: `${records.length + 1} 行目: 引用符（"）で囲んだ値の後に文字が続いています` };
    }
    justClosed = false;
    if (ch === '"') {
      // A quote in the middle of a cell is read as a plain character, as spreadsheet apps do (so that a value like =HYPERLINK("...") is
      // reported clearly as "a value that looks like a formula" rather than as a read error).
      if (cell !== '') { cell += ch; started = true; continue; }
      quoted = true;
      started = true;
      continue;
    }
    if (ch === ',') { record.push(cell); cell = ''; started = true; continue; }
    if (ch === '\r' || ch === '\n') {
      record.push(cell);
      records.push(record);
      record = []; cell = ''; started = false;
      if (ch === '\r' && src[i + 1] === '\n') i += 1;
      continue;
    }
    cell += ch;
    started = true;
  }
  if (quoted) return { ok: false, error: '引用符（"）が閉じられていません' };
  if (started || cell !== '') { record.push(cell); records.push(record); }

  const isBlank = (r: string[]) => r.every((c) => c.trim() === '');
  const firstIndex = records.findIndex((r) => !isBlank(r));
  if (firstIndex < 0) return { ok: false, error: '空のファイルです' };
  const header = records[firstIndex].map((h) => h.trim());
  const rows: { row: number; cells: string[] }[] = [];
  let dataRow = 0;
  for (const r of records.slice(firstIndex + 1)) {
    if (isBlank(r)) continue;
    dataRow += 1;
    rows.push({ row: dataRow, cells: r });
  }
  return { ok: true, header, rows };
}

/**
 * Whether the value would act as a formula when opened in a spreadsheet: it starts with a tab or newline, or its first character after leading whitespace is = + - @.
 * Values are trimmed on save, so " =..." is also judged in its trimmed form (so prefixing whitespace cannot slip past the check).
 */
export function looksLikeFormula(value: string): boolean {
  return /^[\t\r\n]/.test(value) || /^\s*[=+\-@]/.test(value);
}

/** A yes/no column. Empty means no. */
function yesNo(value: string): boolean | null {
  const v = value.trim().toLowerCase();
  if (v === '' || v === 'no' || v === 'いいえ' || v === '0' || v === 'false') return false;
  if (v === 'yes' || v === 'はい' || v === '1' || v === 'true') return true;
  return null;
}

type ColumnSpec = { name: string; required: boolean; max: number };

/** Validate the header and each row with common rules, and return them as column name -> value maps. */
function readRows(
  header: string[],
  rows: { row: number; cells: string[] }[],
  columns: readonly ColumnSpec[],
  issues: RowIssue[],
): { row: number; values: Record<string, string> }[] {
  // A file with too many columns is returned as a single error without per-column checks (so it cannot generate a huge number of errors).
  if (header.length > IMPORT_LIMITS.maxColumns) {
    issues.push({ row: 0, message: `列が多すぎます（${IMPORT_LIMITS.maxColumns} 列まで）` });
    return [];
  }
  const known = new Set(columns.map((c) => c.name));
  const seen = new Set<string>();
  for (const h of header) {
    if (!known.has(h)) issues.push({ row: 0, column: h, message: `知らない列です（使える列: ${columns.map((c) => c.name).join(', ')}）` });
    if (seen.has(h)) issues.push({ row: 0, column: h, message: '同じ列が 2 回あります' });
    seen.add(h);
  }
  for (const c of columns) {
    if (c.required && !header.includes(c.name)) issues.push({ row: 0, column: c.name, message: '必須の列がありません' });
  }
  if (rows.length > IMPORT_LIMITS.maxRows) {
    issues.push({ row: 0, message: `行が多すぎます（${IMPORT_LIMITS.maxRows} 行まで）。分けて取り込んでください` });
  }
  if (issues.some((i) => i.row === 0)) return [];

  const out: { row: number; values: Record<string, string> }[] = [];
  for (const { row, cells } of rows) {
    if (cells.length !== header.length) {
      issues.push({ row, message: `セルの数（${cells.length}）が見出しの列の数（${header.length}）と合いません` });
      continue;
    }
    const values: Record<string, string> = {};
    let bad = false;
    header.forEach((h, idx) => {
      const raw = cells[idx];
      if (looksLikeFormula(raw)) {
        issues.push({ row, column: h, message: '先頭が = + - @ などの値は、表計算で式として動くため受け付けません' });
        bad = true;
      }
      values[h] = raw.trim();
    });
    for (const c of columns) {
      const v = values[c.name] ?? '';
      if (c.required && v === '') { issues.push({ row, column: c.name, message: '必須です' }); bad = true; }
      if (v.length > c.max) { issues.push({ row, column: c.name, message: `${c.max} 文字までです` }); bad = true; }
    }
    if (!bad) out.push({ row, values });
  }
  return out;
}

// ---- Assets ------------------------------------------------------------------------
export const ASSET_COLUMNS = [
  { name: 'asset_key', required: true, max: 80 },
  { name: 'name', required: true, max: 200 },
  { name: 'asset_type', required: true, max: 80 },
  { name: 'classification', required: true, max: 80 },
  { name: 'description', required: false, max: 4000 },
  { name: 'iso27001', required: false, max: 10 },
] as const satisfies readonly ColumnSpec[];

export type AssetImportRow = {
  row: number; assetKey: string; name: string; assetType: string; classification: string;
  description: string; iso: boolean;
};

/** Validate the assets CSV. classifications are the default classifications (keys of catalog.asset_classes_default). */
export function validateAssets(
  header: string[], rows: { row: number; cells: string[] }[], classifications: readonly string[],
): { rows: AssetImportRow[]; issues: RowIssue[] } {
  const issues: RowIssue[] = [];
  const read = readRows(header, rows, ASSET_COLUMNS, issues);
  const out: AssetImportRow[] = [];
  const keys = new Map<string, number>();
  for (const { row, values } of read) {
    let bad = false;
    if (!classifications.includes(values.classification)) {
      issues.push({ row, column: 'classification', message: `分類は ${classifications.join(' / ')} のどれかです` });
      bad = true;
    }
    const iso = yesNo(values.iso27001 ?? '');
    if (iso === null) { issues.push({ row, column: 'iso27001', message: 'はい／いいえ（yes / no）で書いてください' }); bad = true; }
    const first = keys.get(values.asset_key);
    if (first !== undefined) {
      issues.push({ row, column: 'asset_key', message: `同じ資産キーが ${first} 行目にもあります` });
      bad = true;
    } else {
      keys.set(values.asset_key, row);
    }
    if (!bad) {
      out.push({
        row, assetKey: values.asset_key, name: values.name, assetType: values.asset_type,
        classification: values.classification, description: values.description ?? '', iso: iso === true,
      });
    }
  }
  return { rows: out, issues };
}

// ---- Departments -------------------------------------------------------------------
// Departments are identified by name (names have no unique constraint, so a name matching an existing one is an error; design decision 2026-09-12).
export const DEPARTMENT_COLUMNS = [
  { name: 'name', required: true, max: 200 },
  // Name of the parent department. Refers to a registered department or a department in the same file. Empty means top level.
  { name: 'parent_name', required: false, max: 200 },
  // Email address of the manager. Limited to active users. Empty means undecided.
  { name: 'owner_email', required: false, max: 320 },
] as const satisfies readonly ColumnSpec[];

export type DepartmentImportRow = { row: number; name: string; parentName: string; ownerEmail: string };

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function validateDepartments(
  header: string[], rows: { row: number; cells: string[] }[],
): { rows: DepartmentImportRow[]; issues: RowIssue[] } {
  const issues: RowIssue[] = [];
  const read = readRows(header, rows, DEPARTMENT_COLUMNS, issues);
  const out: DepartmentImportRow[] = [];
  const names = new Map<string, number>();
  for (const { row, values } of read) {
    let bad = false;
    const parentName = values.parent_name ?? '';
    const ownerEmail = (values.owner_email ?? '').toLowerCase();
    if (parentName === values.name) {
      issues.push({ row, column: 'parent_name', message: '自分自身を上位の部署にはできません' });
      bad = true;
    }
    if (ownerEmail && !EMAIL_RE.test(ownerEmail)) {
      issues.push({ row, column: 'owner_email', message: 'メールアドレスの形ではありません' });
      bad = true;
    }
    const first = names.get(values.name);
    if (first !== undefined) {
      issues.push({ row, column: 'name', message: `同じ名前の部署が ${first} 行目にもあります` });
      bad = true;
    } else {
      names.set(values.name, row);
    }
    if (!bad) out.push({ row, name: values.name, parentName, ownerEmail });
  }
  // Rows whose parent chain within the file leads back to themselves (cycles) are errors.
  const byName = new Map(out.map((d) => [d.name, d]));
  const cyclic = new Set<number>();
  for (const d of out) {
    const seen = new Set<string>([d.name]);
    let parent = d.parentName;
    while (parent && byName.has(parent)) {
      if (seen.has(parent)) { cyclic.add(d.row); break; }
      seen.add(parent);
      parent = byName.get(parent)!.parentName;
    }
  }
  for (const row of cyclic) issues.push({ row, column: 'parent_name', message: '上位の部署をたどると自分に戻ります（循環）' });
  return { rows: out.filter((d) => !cyclic.has(d.row)), issues };
}

/** Order parents first (so that parent departments in the same file are created first). Assumes validateDepartments has already removed cycles. */
export function orderDepartments(rows: DepartmentImportRow[]): DepartmentImportRow[] {
  const byName = new Map(rows.map((d) => [d.name, d]));
  const done = new Set<string>();
  const out: DepartmentImportRow[] = [];
  const visit = (d: DepartmentImportRow) => {
    if (done.has(d.name)) return;
    done.add(d.name);
    const parent = byName.get(d.parentName);
    if (parent) visit(parent);
    out.push(d);
  };
  for (const d of rows) visit(d);
  return out;
}

// ---- Membership assignment ---------------------------------------------------------
// Set the same department on all non-revoked membership rows of an existing user. Roles are not written. Users are not created.
export const ASSIGNMENT_COLUMNS = [
  { name: 'email', required: true, max: 320 },
  { name: 'department_name', required: true, max: 200 },
] as const satisfies readonly ColumnSpec[];

export type AssignmentImportRow = { row: number; email: string; departmentName: string };

export function validateAssignments(
  header: string[], rows: { row: number; cells: string[] }[],
): { rows: AssignmentImportRow[]; issues: RowIssue[] } {
  const issues: RowIssue[] = [];
  const read = readRows(header, rows, ASSIGNMENT_COLUMNS, issues);
  const out: AssignmentImportRow[] = [];
  const emails = new Map<string, number>();
  for (const { row, values } of read) {
    let bad = false;
    const email = values.email.toLowerCase();
    if (!EMAIL_RE.test(email)) {
      issues.push({ row, column: 'email', message: 'メールアドレスの形ではありません' });
      bad = true;
    }
    const first = emails.get(email);
    if (first !== undefined) {
      issues.push({ row, column: 'email', message: `同じ利用者が ${first} 行目にもあります（1 人に 1 つの部署）` });
      bad = true;
    } else {
      emails.set(email, row);
    }
    if (!bad) out.push({ row, email, departmentName: values.department_name });
  }
  return { rows: out, issues };
}

// ---- Policies (up to draft) --------------------------------------------------------
// One row is one draft version of one policy (design decision 2026-09-12). With catalog_key it goes to the standard policy; without it, by title
// a version is added to an existing policy (a new policy is created if none matches). No version number, approval, or effective date (approval and activation only via the screen).
export const POLICY_COLUMNS = [
  { name: 'catalog_key', required: false, max: 80 },
  // Required on rows with an empty catalog_key (look up an existing policy by title, and create one with that title if none exists).
  { name: 'title', required: false, max: 200 },
  // The body limit is the same as the screen's draft (createPolicyDraft).
  { name: 'body_md', required: true, max: 200_000 },
] as const satisfies readonly ColumnSpec[];

export type PolicyImportRow = { row: number; catalogKey: string; title: string; bodyMd: string };

export function validatePolicies(
  header: string[], rows: { row: number; cells: string[] }[],
): { rows: PolicyImportRow[]; issues: RowIssue[] } {
  const issues: RowIssue[] = [];
  const read = readRows(header, rows, POLICY_COLUMNS, issues);
  const out: PolicyImportRow[] = [];
  const keys = new Map<string, number>();
  const titles = new Map<string, number>();
  for (const { row, values } of read) {
    const catalogKey = values.catalog_key ?? '';
    const title = values.title ?? '';
    if (!catalogKey && !title) {
      issues.push({ row, column: 'title', message: 'catalog_key が空の行は、題名が必須です' });
      continue;
    }
    // Two rows must not point to the same policy (it would be undecided which body becomes the draft). Title overlaps are checked among rows without catalog_key
    // (whether a catalog_key row and a title row hit the same policy is checked against the registered policies).
    const seen = catalogKey ? keys : titles;
    const id = catalogKey || title;
    const first = seen.get(id);
    if (first !== undefined) {
      issues.push({ row, column: catalogKey ? 'catalog_key' : 'title', message: `同じ規程が ${first} 行目にもあります（1 つの規程に 1 行）` });
      continue;
    }
    seen.set(id, row);
    out.push({ row, catalogKey, title, bodyMd: values.body_md });
  }
  return { rows: out, issues };
}

// ---- Risks -------------------------------------------------------------------------
export const RISK_FRAMES = ['管理可能性', '精度', 'スピード'] as const;

export const RISK_COLUMNS = [
  { name: 'risk_key', required: true, max: 80 },
  { name: 'area', required: true, max: 200 },
  { name: 'phase', required: true, max: 2 },
  { name: 'theme', required: true, max: 400 },
  { name: 'measure', required: true, max: 400 },
  { name: 'frame', required: true, max: 30 },
  { name: 'summary', required: true, max: 4000 },
  // Keys of related assets. Separate multiple keys with a semicolon (;) or an ideographic comma. Refers to registered assets, not assets in the same file.
  { name: 'asset_keys', required: false, max: 4000 },
  { name: 'iso27001', required: false, max: 10 },
] as const satisfies readonly ColumnSpec[];

export type RiskImportRow = {
  row: number; riskKey: string; area: string; phase: number; theme: string; measure: string;
  frame: (typeof RISK_FRAMES)[number]; summary: string; assetKeys: string[]; iso: boolean;
};

export function validateRisks(
  header: string[], rows: { row: number; cells: string[] }[],
): { rows: RiskImportRow[]; issues: RowIssue[] } {
  const issues: RowIssue[] = [];
  const read = readRows(header, rows, RISK_COLUMNS, issues);
  const out: RiskImportRow[] = [];
  const keys = new Map<string, number>();
  for (const { row, values } of read) {
    let bad = false;
    const phase = Number(values.phase);
    if (!/^[1-5]$/.test(values.phase) || !Number.isInteger(phase)) {
      issues.push({ row, column: 'phase', message: '段階は 1〜5 の数です' });
      bad = true;
    }
    if (!(RISK_FRAMES as readonly string[]).includes(values.frame)) {
      issues.push({ row, column: 'frame', message: `観点は ${RISK_FRAMES.join(' / ')} のどれかです` });
      bad = true;
    }
    const iso = yesNo(values.iso27001 ?? '');
    if (iso === null) { issues.push({ row, column: 'iso27001', message: 'はい／いいえ（yes / no）で書いてください' }); bad = true; }
    const assetKeys = [...new Set((values.asset_keys ?? '').split(/[;、]/).map((k) => k.trim()).filter(Boolean))];
    const first = keys.get(values.risk_key);
    if (first !== undefined) {
      issues.push({ row, column: 'risk_key', message: `同じリスクキーが ${first} 行目にもあります` });
      bad = true;
    } else {
      keys.set(values.risk_key, row);
    }
    if (!bad) {
      out.push({
        row, riskKey: values.risk_key, area: values.area, phase, theme: values.theme, measure: values.measure,
        frame: values.frame as RiskImportRow['frame'], summary: values.summary, assetKeys, iso: iso === true,
      });
    }
  }
  return { rows: out, issues };
}
