// カタログ（＝ルールの投影）から、図に出すノードと辺を組み立てる。純関数。DB にも DOM にも触らない。
//
// ここで守ること:
//   1. **実在する関係と、分類から導出した関係を混ぜない。** 辺は必ず kind を持ち、
//      'real'（DB の列・FK にそのまま在る）か 'derived'（テキストを割って作った）かが分かる。
//      導出したものを実在と同じ顔で描くと、無い関係を有るように見せることになる。
//   2. **中身が 0 件のものを消さない。** 統制が 0 件のフレームワーク、未投入のチェックや対応表は
//      「未投入」という色のノードとして図に残す。消すと「無い」ではなく「元から想定が無い」に見える。
//   3. 導出ノード（DB の行ではない中間の見出し）は derived: true。描画側は白抜きにする。

import { encodeNodeId, groupKey } from './nodeid';

export type GraphNodeOut = { id: string; title: string; deg: number; bucket: number };
export type GraphLinkOut = { s: string; t: string };
export type PyramidNodeOut = {
  id: string;
  title: string;
  level: number;
  deg: number;
  bucket: number;
  derived?: boolean;
};
export type PyramidLinkOut = { parent: string; child: string; section: string | null };

export type EdgeKind = 'real' | 'derived';

// bucket = 図の色。凡例（GraphViews の BUCKET_LEGEND）と 1 対 1 で対応させる。
export const BUCKET_STRUCTURE = 0; // 骨格（DOM・区分・フレームワーク・規程・体制・カレンダー）
export const BUCKET_CONTROL = 1; // 統制
export const BUCKET_RISK = 2; // リスクシナリオ
export const BUCKET_EMPTY = 3; // 未投入（中身が 0 件）

export type CatalogSnapshot = {
  dom: { version: string } | null;
  frameworks: { key: string; name_ja: string; control_count: number }[];
  // theme は NULL 可（DB が nullable）。分類の無い統制はフレームワーク直下に付く。
  controls: { id: string; code: string; title_ja: string; theme: string | null; framework_key: string }[];
  risks: { id: string; domain: string; theme: string; measure: string; frame: string; summary: string }[];
  policies: { key: string; title_ja: string }[];
  roles: { key: string; name_ja: string }[];
  assets: { key: string; name_ja: string }[];
  calendar: { key: string; name_ja: string; cadence: string; owner_role: string }[];
  // 関連テーブルの件数。0 のものは「未投入」ノードとして図に出す。
  empties: {
    framework_mappings: number;
    risk_template_controls: number;
    checks: number;
    connector_manifests: number;
  };
};

export type GraphModel = {
  pyramidNodes: PyramidNodeOut[];
  pyramidLinks: PyramidLinkOut[];
  graphNodes: GraphNodeOut[];
  graphLinks: GraphLinkOut[];
  pyramidDepth: number;
  derivedNodeCount: number;
  realLinkCount: number;
  linkCount: number;
};

const THEME_SEP = ' / ';
// リスクの domain は「経理・税務（Phase1）」の形。部門と Phase に割る。
const DOMAIN_RE = /^(.*)（(Phase\d+)）$/;

/**
 * 統制の theme を段に割る。想定は 3 段だが、段数が違っても落とさず在るだけ使う。
 *
 * theme は DB で NULL 可なので、NULL・空白のみは「分類なし」＝ 空配列として扱う。
 * 空配列を返した統制はフレームワーク直下に付く（行そのものは図から消さない）。
 */
export function splitTheme(theme: string | null | undefined): string[] {
  if (theme == null) return [];
  return theme
    .split(THEME_SEP)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

/** リスクの domain を部門と Phase に割る。形が違えば部門だけ返す（Phase は null）。 */
export function splitDomain(domain: string): { dept: string; phase: string | null } {
  const m = DOMAIN_RE.exec(domain);
  if (!m) return { dept: domain, phase: null };
  return { dept: m[1], phase: m[2] };
}

type Builder = {
  nodes: Map<string, PyramidNodeOut>;
  links: PyramidLinkOut[];
  extraGraphLinks: { s: string; t: string; kind: EdgeKind }[];
  linkKinds: EdgeKind[];
  // 同じ辺を二度置かないための印。分類の辺は、その分類に属する行の数だけ足そうとする
  // （同じ theme を持つ統制が 20 件あれば、同じ辺が 20 回来る）。重ねると本数が水増しされ、
  // ノードの大きさ（接続本数）も実態とずれる。
  seenLinks: Set<string>;
};

function addNode(b: Builder, n: PyramidNodeOut): string {
  const cur = b.nodes.get(n.id);
  if (cur) {
    // 同じノードが別経路から来たら、浅い方の階層を採る（階層は「最も上に現れる位置」）。
    if (n.level < cur.level) cur.level = n.level;
    return n.id;
  }
  b.nodes.set(n.id, n);
  return n.id;
}

function addLink(b: Builder, parent: string, child: string, section: string, kind: EdgeKind) {
  const seen = [parent, child, section].join('\u001F');
  if (b.seenLinks.has(seen)) return;
  b.seenLinks.add(seen);
  b.links.push({ parent, child, section });
  b.linkKinds.push(kind);
}

function group(kind: string, path: string[]): string {
  return encodeNodeId('group', groupKey(kind, path));
}

export function buildGraphModel(s: CatalogSnapshot): GraphModel {
  const b: Builder = {
    nodes: new Map(),
    links: [],
    extraGraphLinks: [],
    linkKinds: [],
    seenLinks: new Set(),
  };

  // --- L0: DOM 版 ------------------------------------------------------------
  const domId = encodeNodeId('dom', s.dom?.version ?? 'unknown');
  addNode(b, {
    id: domId,
    title: s.dom ? `DOM ${s.dom.version}` : 'DOM（未投入）',
    level: 0,
    deg: 0,
    bucket: s.dom ? BUCKET_STRUCTURE : BUCKET_EMPTY,
  });

  // --- L1: 区分 --------------------------------------------------------------
  const sections: { key: string; title: string }[] = [
    { key: 'controls', title: '統制カタログ' },
    { key: 'risks', title: 'リスクシナリオ' },
    { key: 'policies', title: '規程' },
    { key: 'org', title: '体制と分類' },
    { key: 'calendar', title: '年間カレンダー' },
  ];
  const sectionId: Record<string, string> = {};
  for (const sec of sections) {
    const id = group('section', [sec.key]);
    sectionId[sec.key] = id;
    addNode(b, { id, title: sec.title, level: 1, deg: 0, bucket: BUCKET_STRUCTURE, derived: true });
    addLink(b, domId, id, '構成', 'derived');
  }

  // --- 統制: フレームワーク → theme 3 段 → 統制 -------------------------------
  for (const f of s.frameworks) {
    const fid = encodeNodeId('framework', f.key);
    addNode(b, {
      id: fid,
      title: `${f.name_ja}（${f.control_count}件）`,
      level: 2,
      deg: 0,
      // 統制が 1 件も入っていないフレームワークは「未投入」として色を変える。消さない。
      bucket: f.control_count > 0 ? BUCKET_STRUCTURE : BUCKET_EMPTY,
    });
    addLink(b, sectionId.controls, fid, '実関係: controls.framework_key', 'real');
  }

  for (const c of s.controls) {
    const parts = splitTheme(c.theme);
    let parentId = encodeNodeId('framework', c.framework_key);
    let level = 2;
    for (let i = 0; i < parts.length; i++) {
      level += 1;
      const gid = group('theme', [c.framework_key, ...parts.slice(0, i + 1)]);
      addNode(b, { id: gid, title: parts[i], level, deg: 0, bucket: BUCKET_STRUCTURE, derived: true });
      addLink(b, parentId, gid, '導出: controls.theme', 'derived');
      parentId = gid;
    }
    const cid = encodeNodeId('control', c.id);
    addNode(b, { id: cid, title: `${c.code} ${c.title_ja}`, level: level + 1, deg: 0, bucket: BUCKET_CONTROL });
    addLink(b, parentId, cid, '導出: controls.theme', 'derived');
    // 統制→フレームワークは列にそのまま在る実関係。ピラミッドでは経路が重なるので、
    // 関連グラフの側にだけ足す（ピラミッドを多重親にしない）。
    b.extraGraphLinks.push({ s: cid, t: encodeNodeId('framework', c.framework_key), kind: 'real' });
  }

  // 未投入の関連（対応表・チェック）は、消さずに「未投入」ノードとして残す。
  if (s.empties.framework_mappings === 0) {
    const id = group('empty', ['framework_mappings']);
    addNode(b, { id, title: 'フレームワーク対応表（0件・未投入）', level: 2, deg: 0, bucket: BUCKET_EMPTY, derived: true });
    addLink(b, sectionId.controls, id, '未投入', 'derived');
  }
  if (s.empties.checks === 0) {
    const id = group('empty', ['checks']);
    addNode(b, { id, title: '標準チェック（0件・未投入）', level: 2, deg: 0, bucket: BUCKET_EMPTY, derived: true });
    addLink(b, sectionId.controls, id, '未投入', 'derived');
  }

  // --- リスク: 部門 → Phase → theme → measure → シナリオ ----------------------
  for (const r of s.risks) {
    const { dept, phase } = splitDomain(r.domain);
    const deptId = group('dept', [dept]);
    addNode(b, { id: deptId, title: dept, level: 2, deg: 0, bucket: BUCKET_STRUCTURE, derived: true });
    addLink(b, sectionId.risks, deptId, '導出: domain', 'derived');

    let parentId = deptId;
    let level = 2;
    if (phase) {
      level = 3;
      const phaseId = group('phase', [dept, phase]);
      addNode(b, { id: phaseId, title: phase, level, deg: 0, bucket: BUCKET_STRUCTURE, derived: true });
      addLink(b, deptId, phaseId, '導出: domain', 'derived');
      parentId = phaseId;
    }

    level += 1;
    const themeId = group('rtheme', [r.domain, r.theme]);
    addNode(b, { id: themeId, title: r.theme, level, deg: 0, bucket: BUCKET_STRUCTURE, derived: true });
    addLink(b, parentId, themeId, '導出: theme', 'derived');

    level += 1;
    const measureId = group('measure', [r.domain, r.theme, r.measure]);
    addNode(b, { id: measureId, title: r.measure, level, deg: 0, bucket: BUCKET_STRUCTURE, derived: true });
    addLink(b, themeId, measureId, '導出: measure', 'derived');

    const rid = encodeNodeId('risk', r.id);
    addNode(b, { id: rid, title: r.summary, level: level + 1, deg: 0, bucket: BUCKET_RISK });
    addLink(b, measureId, rid, '導出: measure', 'derived');

    // 観点（管理可能性 / 精度 / スピード）は列にそのまま在る実関係。関連グラフ側に足す。
    const frameId = encodeNodeId('frame', r.frame);
    addNode(b, { id: frameId, title: `観点: ${r.frame}`, level: 2, deg: 0, bucket: BUCKET_STRUCTURE });
    b.extraGraphLinks.push({ s: rid, t: frameId, kind: 'real' });
  }

  if (s.empties.risk_template_controls === 0) {
    const id = group('empty', ['risk_template_controls']);
    addNode(b, { id, title: 'リスク↔統制の紐付け（0件・未投入）', level: 2, deg: 0, bucket: BUCKET_EMPTY, derived: true });
    addLink(b, sectionId.risks, id, '未投入', 'derived');
  }

  // --- 規程 ------------------------------------------------------------------
  for (const p of s.policies) {
    const id = encodeNodeId('policy', p.key);
    addNode(b, { id, title: p.title_ja, level: 2, deg: 0, bucket: BUCKET_STRUCTURE });
    addLink(b, sectionId.policies, id, '実関係: policies_default', 'real');
  }

  // --- 体制と分類 ------------------------------------------------------------
  const rolesGid = group('org', ['roles']);
  addNode(b, { id: rolesGid, title: '標準ロール', level: 2, deg: 0, bucket: BUCKET_STRUCTURE, derived: true });
  addLink(b, sectionId.org, rolesGid, '構成', 'derived');
  for (const r of s.roles) {
    const id = encodeNodeId('role', r.key);
    addNode(b, { id, title: r.name_ja, level: 3, deg: 0, bucket: BUCKET_STRUCTURE });
    addLink(b, rolesGid, id, '実関係: roles_default', 'real');
  }

  const assetsGid = group('org', ['assets']);
  addNode(b, { id: assetsGid, title: '資産分類', level: 2, deg: 0, bucket: BUCKET_STRUCTURE, derived: true });
  addLink(b, sectionId.org, assetsGid, '構成', 'derived');
  for (const a of s.assets) {
    const id = encodeNodeId('asset', a.key);
    addNode(b, { id, title: a.name_ja, level: 3, deg: 0, bucket: BUCKET_STRUCTURE });
    addLink(b, assetsGid, id, '実関係: asset_classes_default', 'real');
  }

  // --- 年間カレンダー: 周期 → 行事（担当ロールへの辺は実関係。グラフ側に足す）-----
  for (const e of s.calendar) {
    const cadId = group('cadence', [e.cadence]);
    addNode(b, { id: cadId, title: e.cadence, level: 2, deg: 0, bucket: BUCKET_STRUCTURE, derived: true });
    addLink(b, sectionId.calendar, cadId, '導出: cadence', 'derived');
    const id = encodeNodeId('calendar', e.key);
    addNode(b, { id, title: e.name_ja, level: 3, deg: 0, bucket: BUCKET_STRUCTURE });
    addLink(b, cadId, id, '導出: cadence', 'derived');
    b.extraGraphLinks.push({ s: id, t: encodeNodeId('role', e.owner_role), kind: 'real' });
  }

  // --- 出力 ------------------------------------------------------------------
  const nodes = [...b.nodes.values()];
  const known = new Set(nodes.map((n) => n.id));

  // 次数（接続本数）。描画の大きさに使う。ピラミッド辺と追加の実関係辺の両方を数える。
  const deg = new Map<string, number>();
  const bump = (id: string) => deg.set(id, (deg.get(id) ?? 0) + 1);
  for (const l of b.links) {
    bump(l.parent);
    bump(l.child);
  }
  const extra = b.extraGraphLinks.filter((l) => known.has(l.s) && known.has(l.t));
  for (const l of extra) {
    bump(l.s);
    bump(l.t);
  }
  for (const n of nodes) n.deg = deg.get(n.id) ?? 0;

  const pyramidDepth = nodes.reduce((mx, n) => Math.max(mx, n.level), 0) + 1;

  const graphLinks: GraphLinkOut[] = [
    ...b.links.map((l) => ({ s: l.parent, t: l.child })),
    ...extra.map((l) => ({ s: l.s, t: l.t })),
  ];
  const realLinkCount =
    b.linkKinds.filter((k) => k === 'real').length + extra.filter((l) => l.kind === 'real').length;

  return {
    pyramidNodes: nodes,
    pyramidLinks: b.links,
    graphNodes: nodes.map((n) => ({ id: n.id, title: n.title, deg: n.deg, bucket: n.bucket })),
    graphLinks,
    pyramidDepth,
    derivedNodeCount: nodes.filter((n) => n.derived).length,
    realLinkCount,
    linkCount: graphLinks.length,
  };
}
