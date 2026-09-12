import { describe, expect, it } from 'vitest';
import {
  BUCKET_CONTROL,
  BUCKET_EMPTY,
  BUCKET_RISK,
  buildGraphModel,
  splitDomain,
  splitTheme,
  type CatalogSnapshot,
} from '../src/lib/graphModel';
import { decodeNodeId } from '../src/lib/nodeid';

function snapshot(over: Partial<CatalogSnapshot> = {}): CatalogSnapshot {
  return {
    dom: { version: '2026.1' },
    frameworks: [
      { key: 'IPO-KARTE', name_ja: 'サンプル統制チェックカルテ（架空）', control_count: 2 },
      { key: 'ISO27001:2022', name_ja: 'ISO/IEC 27001:2022', control_count: 0 },
    ],
    controls: [
      { id: 'c1', code: 'A-10-10-10(1)', title_ja: '統制1', theme: 'サンプル大項目 / サンプル中項目 / サンプル小項目', framework_key: 'IPO-KARTE' },
      { id: 'c2', code: 'A-10-10-10(2)', title_ja: '統制2', theme: 'サンプル大項目 / サンプル中項目 / サンプル小項目', framework_key: 'IPO-KARTE' },
    ],
    risks: [
      {
        id: 'r1',
        domain: 'サンプル部門A（Phase1）',
        theme: 'サンプルテーマ',
        measure: 'サンプル施策',
        frame: 'スピード',
        summary: 'サンプルのリスク要約',
      },
    ],
    policies: [{ key: 'p01_basic', title_ja: '情報セキュリティ基本方針' }],
    roles: [{ key: 'ciso', name_ja: '経営責任者' }],
    assets: [{ key: 'top_secret', name_ja: '極秘' }],
    calendar: [{ key: 'daily_checks', name_ja: '自動チェック', cadence: 'daily', owner_role: 'ciso' }],
    empties: { framework_mappings: 0, risk_template_controls: 0, checks: 0, connector_manifests: 0 },
    ...over,
  };
}

describe('分類の割り方', () => {
  it('統制の theme を段に割る', () => {
    expect(splitTheme('サンプル大項目 / サンプル中項目 / サンプル小項目')).toEqual(['サンプル大項目', 'サンプル中項目', 'サンプル小項目']);
    expect(splitTheme('単一')).toEqual(['単一']);
    expect(splitTheme('')).toEqual([]);
  });

  // catalog.controls.theme is nullable in the DB. If this breaks, /graph and control details return 500.
  it('theme が NULL・空白のみでも落ちず、分類なし（空配列）として扱う', () => {
    expect(splitTheme(null)).toEqual([]);
    expect(splitTheme(undefined)).toEqual([]);
    expect(splitTheme('   ')).toEqual([]);
    expect(splitTheme(' / ')).toEqual([]);
  });

  it('リスクの domain を部門と Phase に割る。形が違えば部門だけ', () => {
    expect(splitDomain('サンプル部門A（Phase1）')).toEqual({ dept: 'サンプル部門A', phase: 'Phase1' });
    expect(splitDomain('サンプル部門B（Phase1）')).toEqual({ dept: 'サンプル部門B', phase: 'Phase1' });
    expect(splitDomain('形が違う')).toEqual({ dept: '形が違う', phase: null });
  });
});

describe('図のモデル', () => {
  it('同じ分類を共有する統制は、同じ中間ノードにぶら下がる', () => {
    const m = buildGraphModel(snapshot());
    const themeNodes = m.pyramidNodes.filter((n) => decodeNodeId(n.id)?.key.startsWith('theme'));
    // The 2 controls share the same theme, so one per level = 3 nodes is enough
    expect(themeNodes).toHaveLength(3);
  });

  it('分類の無い統制も図から消さず、フレームワーク直下に付ける', () => {
    const m = buildGraphModel(
      snapshot({
        frameworks: [{ key: 'IPO-KARTE', name_ja: 'サンプル統制チェックカルテ（架空）', control_count: 2 }],
        controls: [
          { id: 'c1', code: 'A-1', title_ja: '分類あり', theme: 'サンプル大項目 / サンプル中項目', framework_key: 'IPO-KARTE' },
          { id: 'c2', code: 'A-2', title_ja: '分類なし', theme: null, framework_key: 'IPO-KARTE' },
        ],
      }),
    );
    // No rows have disappeared (dropping them would make the screen's counts disagree with the DB)
    const controls = m.pyramidNodes.filter((n) => decodeNodeId(n.id)?.type === 'control');
    expect(controls).toHaveLength(2);
    expect(controls.map((n) => n.title)).toContain('A-2 分類なし');

    // A control without a classification attaches directly under the framework, without a theme intermediate node
    const fid = m.pyramidNodes.find((n) => decodeNodeId(n.id)?.type === 'framework')!.id;
    const cid = controls.find((n) => n.title === 'A-2 分類なし')!.id;
    expect(m.pyramidLinks.some((l) => l.parent === fid && l.child === cid)).toBe(true);

    // Do not invent an intermediate node representing "no classification" (do not add a nonexistent classification to the diagram)
    const themeNodes = m.pyramidNodes.filter((n) => decodeNodeId(n.id)?.key.startsWith('theme'));
    expect(themeNodes).toHaveLength(2);
  });

  it('実在する関係と導出した関係を数え分ける', () => {
    const m = buildGraphModel(snapshot());
    expect(m.realLinkCount).toBeGreaterThan(0);
    expect(m.linkCount).toBeGreaterThan(m.realLinkCount);
    // Derived edges always carry a label showing they are "derived"
    const derivedEdges = m.pyramidLinks.filter((l) => l.section?.startsWith('導出'));
    expect(derivedEdges.length).toBeGreaterThan(0);
    const realEdges = m.pyramidLinks.filter((l) => l.section?.startsWith('実関係'));
    expect(realEdges.length).toBeGreaterThan(0);
  });

  it('中身が 0 件のフレームワークを消さず、未投入の色で残す', () => {
    const m = buildGraphModel(snapshot());
    const iso = m.pyramidNodes.find((n) => decodeNodeId(n.id)?.key === 'ISO27001:2022');
    expect(iso).toBeDefined();
    expect(iso!.bucket).toBe(BUCKET_EMPTY);
    expect(iso!.title).toContain('0件');
  });

  it('未投入の関連テーブルを、未投入ノードとして図に出す', () => {
    const m = buildGraphModel(snapshot());
    const titles = m.pyramidNodes.map((n) => n.title);
    expect(titles).toContain('標準チェック（0件・未投入）');
    expect(titles).toContain('フレームワーク対応表（0件・未投入）');
    expect(titles).toContain('リスク↔統制の紐付け（0件・未投入）');
  });

  it('関連が投入されたら、未投入ノードは出さない', () => {
    const m = buildGraphModel(
      snapshot({ empties: { framework_mappings: 3, risk_template_controls: 5, checks: 66, connector_manifests: 2 } }),
    );
    const titles = m.pyramidNodes.map((n) => n.title);
    expect(titles.some((t) => t.includes('未投入'))).toBe(false);
  });

  it('導出ノードには derived が立ち、実体の行には立たない', () => {
    const m = buildGraphModel(snapshot());
    const control = m.pyramidNodes.find((n) => decodeNodeId(n.id)?.type === 'control');
    expect(control!.derived).toBeUndefined();
    expect(control!.bucket).toBe(BUCKET_CONTROL);
    const risk = m.pyramidNodes.find((n) => decodeNodeId(n.id)?.type === 'risk');
    expect(risk!.bucket).toBe(BUCKET_RISK);
    const section = m.pyramidNodes.find((n) => n.title === '統制カタログ');
    expect(section!.derived).toBe(true);
    expect(m.derivedNodeCount).toBeGreaterThan(0);
  });

  it('同じ辺を重ねない（分類の辺が、その分類に属する行の数だけ増えない）', () => {
    // Two controls share the same theme. There should be only one classification edge for each.
    const m = buildGraphModel(snapshot());
    const keys = m.pyramidLinks.map((l) => `${l.parent}|${l.child}|${l.section}`);
    expect(new Set(keys).size).toBe(keys.length);

    // Adding more rows does not add classification edges (only leaf edges increase).
    const base = snapshot();
    const more = buildGraphModel({
      ...base,
      controls: [
        ...base.controls,
        { id: 'c3', code: 'A-10-10-10(3)', title_ja: '統制3', theme: 'サンプル大項目 / サンプル中項目 / サンプル小項目', framework_key: 'IPO-KARTE' },
      ],
      frameworks: base.frameworks.map((f) => (f.key === 'IPO-KARTE' ? { ...f, control_count: 3 } : f)),
    });
    expect(more.pyramidLinks.length).toBe(m.pyramidLinks.length + 1);
  });

  it('すべての辺の両端が、ノード集合に実在する', () => {
    const m = buildGraphModel(snapshot());
    const ids = new Set(m.pyramidNodes.map((n) => n.id));
    for (const l of m.pyramidLinks) {
      expect(ids.has(l.parent)).toBe(true);
      expect(ids.has(l.child)).toBe(true);
    }
    for (const l of m.graphLinks) {
      expect(ids.has(l.s)).toBe(true);
      expect(ids.has(l.t)).toBe(true);
    }
  });

  it('DOM が無ければ、頂点を未投入として出す（黙って消さない）', () => {
    const m = buildGraphModel(snapshot({ dom: null }));
    const top = m.pyramidNodes.find((n) => n.level === 0);
    expect(top!.title).toBe('DOM（未投入）');
    expect(top!.bucket).toBe(BUCKET_EMPTY);
  });

  it('カタログが空でも落ちない', () => {
    const m = buildGraphModel({
      dom: null,
      frameworks: [],
      controls: [],
      risks: [],
      policies: [],
      roles: [],
      assets: [],
      calendar: [],
      empties: { framework_mappings: 0, risk_template_controls: 0, checks: 0, connector_manifests: 0 },
    });
    expect(m.pyramidNodes.length).toBeGreaterThan(0); // The DOM and the sections remain
    expect(m.graphLinks.length).toBeGreaterThan(0);
  });
});
