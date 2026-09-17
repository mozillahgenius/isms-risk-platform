// 初期データの取り込み（設計書 2026-09-11 §8）の CSV の読み取りと検査。
// DB に触らない純粋な関数だけを置く（試験しやすくし、読み取りと書き込みを混ぜないため）。
//
// 安全設計（§8.3）のうち、ここで持つもの:
//   - 大きさの上限（ファイルの大きさ・行数）。値は仮置きで、実際の取り込みで測って見直す（§0.2「数値は実測で決める」）。
//   - CSV 数式インジェクション対策: 先頭が = + - @ タブ 改行 のセルは受け付けない
//     （取り込んだ値を後で表計算に書き出して開いたとき、式として動くため）。黙って書き換えず、行の誤りとして返す。
//   - 必須列・知らない列・型・値の範囲・長さ・ファイルの中の重複の検査。
// 既存データとの重複・参照の解決（資産キー → 資産）・書き込みはサーバーアクション側で行う（DB が要る）。

export const IMPORT_LIMITS = { maxBytes: 1_000_000, maxRows: 2_000, maxColumns: 50, maxIssues: 200 } as const;

/**
 * 誤りを見せる件数に上限を付ける（1 MB 以内でも誤りを大量に作れるので、処理と画面を膨らませない）。
 * 超えた分は件数だけを 1 行で伝える。
 */
export function capIssues(issues: RowIssue[]): RowIssue[] {
  if (issues.length <= IMPORT_LIMITS.maxIssues) return issues;
  return [
    ...issues.slice(0, IMPORT_LIMITS.maxIssues),
    { row: 0, message: `ほかに ${issues.length - IMPORT_LIMITS.maxIssues} 件の誤りがあります（最初の ${IMPORT_LIMITS.maxIssues} 件だけ表示）` },
  ];
}

export type ImportKind = 'assets' | 'risks' | 'departments' | 'assignments' | 'policies';

/** 行の誤り。row は見出しを除いたデータの行番号（1 始まり）。0 はファイル全体・見出しの誤り。 */
export type RowIssue = { row: number; column?: string; message: string };

export type CsvParseResult =
  | { ok: true; header: string[]; rows: { row: number; cells: string[] }[] }
  | { ok: false; error: string };

/**
 * RFC 4180 の CSV を読む（ダブルクォートで囲んだセル・セルの中の改行・"" のエスケープ）。
 * 先頭の BOM は外す（表計算ソフトの UTF-8 書き出しに付く）。中身が空の行は読み飛ばす。
 */
export function parseCsv(text: string): CsvParseResult {
  const src = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const records: string[][] = [];
  let record: string[] = [];
  let cell = '';
  let quoted = false;
  let started = false;
  // 引用符で囲んだセルを閉じた直後か。閉じた後に区切り（, 改行）以外が続く値は、黙って読み替えず誤りにする
  // （"顧客"台帳 を 顧客台帳 と読むと、利用者の値が知らないうちに変わる）。
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
      // セルの途中の引用符は、表計算ソフトと同じくただの文字として読む（=HYPERLINK("…") のような値を、
      // 読み取りの誤りではなく「式に見える値」として分かりやすく返すため）。
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
 * 表計算で開いたときに式として動く値か。先頭がタブ・改行か、先頭の空白を除いた最初の文字が = + - @。
 * 保存するときは前後の空白を除くので、「 =…」も除いた後の形で判定する（空白を前置きして判定をすり抜けさせない）。
 */
export function looksLikeFormula(value: string): boolean {
  return /^[\t\r\n]/.test(value) || /^\s*[=+\-@]/.test(value);
}

/** 「はい／いいえ」の列。空は「いいえ」。 */
function yesNo(value: string): boolean | null {
  const v = value.trim().toLowerCase();
  if (v === '' || v === 'no' || v === 'いいえ' || v === '0' || v === 'false') return false;
  if (v === 'yes' || v === 'はい' || v === '1' || v === 'true') return true;
  return null;
}

type ColumnSpec = { name: string; required: boolean; max: number };

/** 列の見出しと各行を共通の決まりで検査し、列名 → 値の対応にして返す。 */
function readRows(
  header: string[],
  rows: { row: number; cells: string[] }[],
  columns: readonly ColumnSpec[],
  issues: RowIssue[],
): { row: number; values: Record<string, string> }[] {
  // 列が多すぎるファイルは、列ごとの検査をせずに 1 件の誤りで返す（誤りを大量に作らせない）。
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

// ---- 資産 -------------------------------------------------------------------------
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

/** 資産の CSV を検査する。classifications は分類の既定値（catalog.asset_classes_default のキー）。 */
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

// ---- 部署 -------------------------------------------------------------------------
// 部署は名前で見分ける（名前に一意制約が無いので、既存と同じ名前は誤りにする。2026-09-12 goto-twin 決定）。
export const DEPARTMENT_COLUMNS = [
  { name: 'name', required: true, max: 200 },
  // 上位の部署の名前。登録済みの部署か、同じファイルの中の部署を指す。空は最上位。
  { name: 'parent_name', required: false, max: 200 },
  // 責任者のメールアドレス。在籍中の利用者に限る。空は未定。
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
  // ファイルの中で上位をたどって自分に戻る（循環する）行は誤りにする。
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

/** 上位を先にして並べる（同じファイルの上位の部署を先に作るため）。循環は validateDepartments が除いている前提。 */
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

// ---- 所属の割り当て ----------------------------------------------------------------
// 既にいる利用者の、失効していない所属の行すべてに同じ部署を入れる。役割は書かない。利用者は作らない。
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

// ---- 規程（下書きまで） -------------------------------------------------------------
// 1 行が 1 つの規程の下書きの版 1 つ（2026-09-12 goto-twin 決定）。catalog_key があれば標準規程に、無ければ題名で
// 既存の規程に版を足す（一致が無ければ規程を新しく作る）。版番号・承認・有効日は持たない（承認と有効化は画面の経路だけ）。
export const POLICY_COLUMNS = [
  { name: 'catalog_key', required: false, max: 80 },
  // catalog_key が空の行では必須（題名で既存の規程を探し、無ければその題名で作る）。
  { name: 'title', required: false, max: 200 },
  // 本文の上限は画面の下書き（createPolicyDraft）と同じ。
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
    // 同じ規程を 2 行で指さない（どちらの本文を下書きにするか決まらない）。題名での重なりは catalog_key の無い行どうしで見る
    // （catalog_key の行と題名の行が同じ規程に当たるかは、登録済みの規程と突き合わせて確かめる）。
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

// ---- リスク -----------------------------------------------------------------------
export const RISK_FRAMES = ['管理可能性', '精度', 'スピード'] as const;

export const RISK_COLUMNS = [
  { name: 'risk_key', required: true, max: 80 },
  { name: 'area', required: true, max: 200 },
  { name: 'phase', required: true, max: 2 },
  { name: 'theme', required: true, max: 400 },
  { name: 'measure', required: true, max: 400 },
  { name: 'frame', required: true, max: 30 },
  { name: 'summary', required: true, max: 4000 },
  // 関連する資産のキー。複数はセミコロン（;）か読点（、）で区切る。同じファイルの資産ではなく、登録済みの資産を指す。
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
