import { describe, expect, it } from 'vitest';
import {
  IMPORT_LIMITS, capIssues, looksLikeFormula, orderDepartments, parseCsv, validateAssets, validateAssignments,
  validateDepartments, validatePolicies, validateRisks,
} from '../src/lib/csvImport';

const CLASSES = ['public', 'internal', 'confidential', 'top_secret'];

function parsed(text: string) {
  const r = parseCsv(text);
  if (!r.ok) throw new Error(r.error);
  return r;
}

describe('parseCsv', () => {
  it('引用符・セル内の改行・"" のエスケープ・CRLF・BOM を読める', () => {
    const r = parsed('﻿a,b\r\n"x,1","line1\nline2"\r\n"say ""hi""",z\r\n');
    expect(r.header).toEqual(['a', 'b']);
    expect(r.rows).toEqual([
      { row: 1, cells: ['x,1', 'line1\nline2'] },
      { row: 2, cells: ['say "hi"', 'z'] },
    ]);
  });

  it('空の行は読み飛ばし、データの行番号は見出しを除いて 1 から数える', () => {
    const r = parsed('a\n\n1\n,\n2');
    expect(r.rows.map((x) => [x.row, x.cells[0]])).toEqual([[1, '1'], [2, '2']]);
  });

  it('閉じていない引用符は誤りにし、セルの途中の引用符はただの文字として読む', () => {
    expect(parseCsv('a\n"open').ok).toBe(false);
    expect(parsed('a\nx"y"').rows[0].cells).toEqual(['x"y"']);
  });

  it('引用符で囲んだ値の後に文字が続く行は、黙って読み替えず誤りにする', () => {
    expect(parseCsv('a,b\nA,"顧客"台帳').ok).toBe(false);
    expect(parsed('a,b\nA,"顧客台帳"').rows[0].cells).toEqual(['A', '顧客台帳']);
  });

  it('空のファイルは誤りにする', () => {
    expect(parseCsv('').ok).toBe(false);
    expect(parseCsv('\n\n').ok).toBe(false);
  });
});

describe('looksLikeFormula', () => {
  it('= + - @ タブ 改行で始まる値を式として扱い、先頭の空白ですり抜けさせない', () => {
    for (const v of ['=1+1', '+SUM(A1)', '-2', '@x', '\tx', '\rx', ' =HYPERLINK("x")', '  +1']) {
      expect(looksLikeFormula(v), v).toBe(true);
    }
    for (const v of ['ok', '1-2', 'a=b', '']) expect(looksLikeFormula(v), v).toBe(false);
  });
});

describe('validateAssets', () => {
  const header = 'asset_key,name,asset_type,classification,description,iso27001';

  it('正しい行を読み、iso27001 の はい／いいえ を真偽値にする', () => {
    const r = parsed(`${header}\nA-1,顧客台帳,情報,confidential,顧客の連絡先,はい\nA-2,社内規程,文書,internal,,`);
    const v = validateAssets(r.header, r.rows, CLASSES);
    expect(v.issues).toEqual([]);
    expect(v.rows.map((x) => [x.assetKey, x.iso])).toEqual([['A-1', true], ['A-2', false]]);
  });

  it('必須の列が無い・知らない列があるときは、行を読まずにファイルの誤りにする', () => {
    const r = parsed('asset_key,name,owner\nA-1,x,y');
    const v = validateAssets(r.header, r.rows, CLASSES);
    expect(v.rows).toEqual([]);
    expect(v.issues.every((i) => i.row === 0)).toBe(true);
    expect(v.issues.map((i) => i.column)).toEqual(expect.arrayContaining(['owner', 'asset_type', 'classification']));
  });

  it('数式に見える値・分類の誤り・必須の空・ファイルの中の重複を行ごとに返す', () => {
    const r = parsed(`${header}\nA-1,=HYPERLINK("x"),情報,internal,,\nA-2,名,情報,secret,,\nA-3,,情報,internal,,\nA-4,名,情報,internal,,\nA-4,名,情報,internal,,`);
    const v = validateAssets(r.header, r.rows, CLASSES);
    expect(v.rows.map((x) => x.assetKey)).toEqual(['A-4']);
    const byRow = (n: number) => v.issues.filter((i) => i.row === n).map((i) => i.column);
    expect(byRow(1)).toContain('name');
    expect(byRow(2)).toContain('classification');
    expect(byRow(3)).toContain('name');
    expect(byRow(5)).toContain('asset_key');
  });

  it('セルの数が見出しと合わない行は誤りにする', () => {
    const r = parsed(`${header}\nA-1,名,情報`);
    expect(validateAssets(r.header, r.rows, CLASSES).issues[0].message).toMatch(/セルの数/);
  });

  it('列が多すぎるときは、列ごとに誤りを作らず 1 件で返す', () => {
    const many = Array.from({ length: IMPORT_LIMITS.maxColumns + 1 }, (_, i) => `c${i}`).join(',');
    const r = parsed(`${many}\n${many}`);
    const v = validateAssets(r.header, r.rows, CLASSES);
    expect(v.issues).toHaveLength(1);
    expect(v.issues[0].message).toMatch(/列が多すぎます/);
  });

  it('誤りは上限までに切り、残りは件数だけを伝える', () => {
    const lines = Array.from({ length: IMPORT_LIMITS.maxIssues + 10 }, (_, i) => `K-${i},名,情報,secret,,`);
    const r = parsed(`${header}\n${lines.join('\n')}`);
    const capped = capIssues(validateAssets(r.header, r.rows, CLASSES).issues);
    expect(capped).toHaveLength(IMPORT_LIMITS.maxIssues + 1);
    expect(capped.at(-1)!.message).toMatch(/ほかに 10 件/);
  });

  it('行が多すぎるときはファイルの誤りにする', () => {
    const lines = Array.from({ length: IMPORT_LIMITS.maxRows + 1 }, (_, i) => `K-${i},名,情報,internal,,`);
    const r = parsed(`${header}\n${lines.join('\n')}`);
    const v = validateAssets(r.header, r.rows, CLASSES);
    expect(v.rows).toEqual([]);
    expect(v.issues[0]).toMatchObject({ row: 0 });
  });
});

describe('validateDepartments / orderDepartments', () => {
  const header = 'name,parent_name,owner_email';

  it('正しい行を読み、上位を先に並べる（同じファイルの上位を先に作れる）', () => {
    const r = parsed(`${header}\n第一課,営業部,\n営業部,,Boss@One.Test\n本社,,`);
    const v = validateDepartments(r.header, r.rows);
    expect(v.issues).toEqual([]);
    expect(v.rows.find((d) => d.name === '営業部')!.ownerEmail).toBe('boss@one.test');
    expect(orderDepartments(v.rows).map((d) => d.name)).toEqual(['営業部', '第一課', '本社']);
  });

  it('自分を上位にする行・ファイルの中の循環・名前の重複・メールの形の誤りを行ごとに返す', () => {
    const r = parsed(`${header}\n自己,自己,\nA,B,\nB,A,\n営業,,\n営業,,\n総務,,not-an-email`);
    const v = validateDepartments(r.header, r.rows);
    expect(v.rows).toEqual([expect.objectContaining({ name: '営業' })]);
    expect(v.issues.map((i) => [i.row, i.column]).sort()).toEqual(
      [[1, 'parent_name'], [2, 'parent_name'], [3, 'parent_name'], [5, 'name'], [6, 'owner_email']].sort(),
    );
  });
});

describe('validateAssignments', () => {
  const header = 'email,department_name';

  it('メールを小文字にそろえ、同じ利用者の重複とメールの形の誤りを返す', () => {
    const r = parsed(`${header}\nA@One.Test,営業部\na@one.test,総務部\nbad,営業部\nb@one.test,総務部`);
    const v = validateAssignments(r.header, r.rows);
    expect(v.rows.map((x) => [x.email, x.departmentName])).toEqual([['a@one.test', '営業部'], ['b@one.test', '総務部']]);
    expect(v.issues.map((i) => [i.row, i.column])).toEqual([[2, 'email'], [3, 'email']]);
  });
});

describe('validatePolicies', () => {
  it('catalog_key か題名で規程を指し、複数行の本文を読める', () => {
    const p = parsed('catalog_key,title,body_md\nPOL-01,,"# 方針\n\n本文"\n,自社の規程,"# 自社\n本文"\n');
    const v = validatePolicies(p.header, p.rows);
    expect(v.issues).toEqual([]);
    expect(v.rows).toEqual([
      { row: 1, catalogKey: 'POL-01', title: '', bodyMd: '# 方針\n\n本文' },
      { row: 2, catalogKey: '', title: '自社の規程', bodyMd: '# 自社\n本文' },
    ]);
  });

  it('catalog_key も題名も無い行・本文の無い行・同じ規程を 2 行で指す行は誤り', () => {
    const p = parsed('catalog_key,title,body_md\n,,本文\nPOL-01,,\nPOL-02,,本文\nPOL-02,,別の本文\n,甲,本文\n,甲,本文2\n');
    const v = validatePolicies(p.header, p.rows);
    expect(v.issues.map((i) => [i.row, i.column]).sort((a, b) => Number(a[0]) - Number(b[0]))).toEqual([
      [1, 'title'], [2, 'body_md'], [4, 'catalog_key'], [6, 'title'],
    ]);
    expect(v.rows.map((r) => r.row)).toEqual([3, 5]);
  });

  it('本文の先頭が式の形なら拒否し、上限を超える本文も拒否する', () => {
    const p = parsed(`catalog_key,title,body_md\n,甲,=HYPERLINK("x")\n,乙,${'あ'.repeat(200_001)}\n`);
    const v = validatePolicies(p.header, p.rows);
    expect(v.issues.map((i) => [i.row, i.column])).toEqual([[1, 'body_md'], [2, 'body_md']]);
    expect(v.rows).toEqual([]);
  });
});

describe('validateRisks', () => {
  const header = 'risk_key,area,phase,theme,measure,frame,summary,asset_keys,iso27001';

  it('正しい行を読み、関連資産のキーをセミコロン・読点で分ける', () => {
    const r = parsed(`${header}\nR-1,営業,2,漏えい,暗号化,精度,説明,A-1;A-2、A-1,yes`);
    const v = validateRisks(r.header, r.rows);
    expect(v.issues).toEqual([]);
    expect(v.rows[0]).toMatchObject({ riskKey: 'R-1', phase: 2, frame: '精度', assetKeys: ['A-1', 'A-2'], iso: true });
  });

  it('段階・観点の誤りと、ファイルの中の重複を行ごとに返す', () => {
    const r = parsed(`${header}\nR-1,営業,6,t,m,精度,s,,\nR-2,営業,2,t,m,速さ,s,,\nR-3,営業,1,t,m,精度,s,,\nR-3,営業,1,t,m,精度,s,,`);
    const v = validateRisks(r.header, r.rows);
    expect(v.rows.map((x) => x.riskKey)).toEqual(['R-3']);
    expect(v.issues.map((i) => [i.row, i.column])).toEqual([[1, 'phase'], [2, 'frame'], [4, 'risk_key']]);
  });
});
