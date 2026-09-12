// Builds the nodes and edges shown in the diagram from the catalog (= a projection of the rules). Pure function. Touches neither the DB nor the DOM.
//
// Rules to keep here:
//   1. **Do not mix relations that actually exist with relations derived from classification.** Every edge has a kind,
//      so you can tell whether it is 'real' (present as-is in a DB column/FK) or 'derived' (built by splitting text).
//      Drawing derived ones the same way as real ones would make nonexistent relations look like they exist.
//   2. **Do not drop things with zero contents.** Frameworks with zero controls, and checks or mappings not yet loaded,
//      stay in the diagram as nodes colored "not loaded". Dropping them makes them look "never anticipated" rather than "absent".
//   3. Derived nodes (intermediate headings that are not DB rows) have derived: true. The renderer draws them hollow.

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

// bucket = the color in the diagram. Keep it one-to-one with the legend (BUCKET_LEGEND in GraphViews).
export const BUCKET_STRUCTURE = 0; // Skeleton (DOM, categories, frameworks, policies, organization, calendar)
export const BUCKET_CONTROL = 1; // Controls
export const BUCKET_RISK = 2; // Risk scenarios
export const BUCKET_EMPTY = 3; // Not loaded (zero contents)

export type CatalogSnapshot = {
  dom: { version: string } | null;
  frameworks: { key: string; name_ja: string; control_count: number }[];
  // theme may be NULL (nullable in the DB). Controls without a classification attach directly under the framework.
  controls: { id: string; code: string; title_ja: string; theme: string | null; framework_key: string }[];
  risks: { id: string; domain: string; theme: string; measure: string; frame: string; summary: string }[];
  policies: { key: string; title_ja: string }[];
  roles: { key: string; name_ja: string }[];
  assets: { key: string; name_ja: string }[];
  calendar: { key: string; name_ja: string; cadence: string; owner_role: string }[];
  // Counts in related tables. Those with 0 are shown in the diagram as "not loaded" nodes.
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
// A risk's domain has the form "department name (Phase1)". Split it into department and Phase.
const DOMAIN_RE = /^(.*)（(Phase\d+)）$/;

/**
 * Split a control's theme into levels. Three levels are expected, but a different count is not dropped; use whatever is there.
 *
 * theme may be NULL in the DB, so NULL or whitespace-only is treated as "no classification" = an empty array.
 * Controls returning an empty array attach directly under the framework (the row itself is not removed from the diagram).
 */
export function splitTheme(theme: string | null | undefined): string[] {
  if (theme == null) return [];
  return theme
    .split(THEME_SEP)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

/** Split a risk's domain into department and Phase. If the shape differs, return only the department (Phase is null). */
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
  // Marker to avoid placing the same edge twice. Classification edges get added once per row belonging to that classification
  // (if 20 controls share the same theme, the same edge arrives 20 times). Stacking them inflates the edge count,
  // and node size (number of connections) also drifts from reality.
  seenLinks: Set<string>;
};

function addNode(b: Builder, n: PyramidNodeOut): string {
  const cur = b.nodes.get(n.id);
  if (cur) {
    // If the same node arrives via another path, take the shallower level (level = "the highest position it appears at").
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

  // --- L0: DOM version --------------------------------------------------------
  const domId = encodeNodeId('dom', s.dom?.version ?? 'unknown');
  addNode(b, {
    id: domId,
    title: s.dom ? `DOM ${s.dom.version}` : 'DOM（未投入）',
    level: 0,
    deg: 0,
    bucket: s.dom ? BUCKET_STRUCTURE : BUCKET_EMPTY,
  });

  // --- L1: Categories --------------------------------------------------------
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

  // --- Controls: framework -> 3 theme levels -> control ------------------------
  for (const f of s.frameworks) {
    const fid = encodeNodeId('framework', f.key);
    addNode(b, {
      id: fid,
      title: `${f.name_ja}（${f.control_count}件）`,
      level: 2,
      deg: 0,
      // Frameworks with no controls at all get a different color as "not loaded". Do not drop them.
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
    // Control -> framework is a real relation present as-is in a column. In the pyramid the paths overlap, so
    // add it only on the relation-graph side (do not give the pyramid multiple parents).
    b.extraGraphLinks.push({ s: cid, t: encodeNodeId('framework', c.framework_key), kind: 'real' });
  }

  // Related items not yet loaded (mappings, checks) are kept as "not loaded" nodes rather than dropped.
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

  // --- Risks: department -> Phase -> theme -> measure -> scenario --------------
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

    // Perspectives (manageability / accuracy / speed) are real relations present as-is in columns. Add them on the relation-graph side.
    const frameId = encodeNodeId('frame', r.frame);
    addNode(b, { id: frameId, title: `観点: ${r.frame}`, level: 2, deg: 0, bucket: BUCKET_STRUCTURE });
    b.extraGraphLinks.push({ s: rid, t: frameId, kind: 'real' });
  }

  if (s.empties.risk_template_controls === 0) {
    const id = group('empty', ['risk_template_controls']);
    addNode(b, { id, title: 'リスク↔統制の紐付け（0件・未投入）', level: 2, deg: 0, bucket: BUCKET_EMPTY, derived: true });
    addLink(b, sectionId.risks, id, '未投入', 'derived');
  }

  // --- Policies ---------------------------------------------------------------
  for (const p of s.policies) {
    const id = encodeNodeId('policy', p.key);
    addNode(b, { id, title: p.title_ja, level: 2, deg: 0, bucket: BUCKET_STRUCTURE });
    addLink(b, sectionId.policies, id, '実関係: policies_default', 'real');
  }

  // --- Organization and classifications ---------------------------------------
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

  // --- Annual calendar: cycle -> event (edges to responsible roles are real relations; added on the graph side) -----
  for (const e of s.calendar) {
    const cadId = group('cadence', [e.cadence]);
    addNode(b, { id: cadId, title: e.cadence, level: 2, deg: 0, bucket: BUCKET_STRUCTURE, derived: true });
    addLink(b, sectionId.calendar, cadId, '導出: cadence', 'derived');
    const id = encodeNodeId('calendar', e.key);
    addNode(b, { id, title: e.name_ja, level: 3, deg: 0, bucket: BUCKET_STRUCTURE });
    addLink(b, cadId, id, '導出: cadence', 'derived');
    b.extraGraphLinks.push({ s: id, t: encodeNodeId('role', e.owner_role), kind: 'real' });
  }

  // --- Output -----------------------------------------------------------------
  const nodes = [...b.nodes.values()];
  const known = new Set(nodes.map((n) => n.id));

  // Degree (number of connections). Used for rendered size. Counts both pyramid edges and additional real-relation edges.
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
