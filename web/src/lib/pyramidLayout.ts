// Layout computation for the hierarchy pyramid (pure functions, no DOM dependency).
// The three views flat (orthographic) / persp (perspective) / webgl (three.js) share the same coordinates, levels, and edges;
// this is the single source of truth so the views don't look different. Coordinates are 3D reference coordinates "before rotation".

// derived=true means "a grouping derived from a classification (not a DB row)". Drawn hollow so it can be told apart from real rows.
// Derived nodes are intermediate headings bundling controls or risks; there is no corresponding DB row.
export type PyramidNode = {
  id: string;
  title: string;
  level: number;
  deg: number;
  bucket: number;
  derived?: boolean;
};
export type PyramidLink = { parent: string; child: string; section: string | null };
export type PyramidEdge = { p: number; c: number; section: string | null };

export type PyramidLayout = {
  N: number;
  edges: PyramidEdge[];
  adj: Set<number>[];
  maxLevel: number;
  levelMid: number;
  // Reference coordinates before rotation (y is positive upward: the apex = level0 is at the top). Length N.
  bx: Float64Array;
  by: Float64Array;
  bz: Float64Array;
  maxR: number;
  // Radii of the concentric rings actually used per level. Overflowing levels have several. The renderer's ring lines use these.
  tierRings: number[][];
  LEVEL_GAP: number;
  R0: number;
  RSTEP: number;
};

const LEVEL_GAP = 74; // Height between levels
const R0 = 34; // Radius near the apex
const RSTEP = 66; // Amount the radius widens per level of depth
// Node draw radius. Larger for nodes with more connections. Both the layout spacing computation and each view's rendering
// use the same value, so this is the single definition (keeping separate copies makes spacing and actual size drift apart and nodes overlap).
export function nodeRadius(deg: number): number {
  return 4 + Math.sqrt(deg) * 2.1;
}

// Lower bound of the minimum spacing (world units) between adjacent nodes on the same ring.
// The actual spacing is derived from the diameter of the largest node in that level (high-degree nodes have larger radii,
// so with a fixed value the diameter exceeds the spacing and nodes overlap).
const MIN_ARC = 16;
// Lower bound of the spacing between concentric rings added outward for levels that don't fit on a single ring.
const SUB_GAP = 24;

// Number of nodes that fit on a ring of radius R while keeping center-to-center distance `spacing` between neighbors.
// Checked by chord length, not arc length (center-to-center distance for n evenly spaced nodes is 2R*sin(π/n)).
// Counting by arc length, when the radius is small and the spacing large, the actual distance falls short and nodes overlap.
// Minimum is 1 (what doesn't fit is sent to an outer ring).
function ringCapacity(R: number, spacing: number): number {
  const s = spacing / (2 * R);
  if (s >= 1) return 1; // Not enough room even with 2 nodes (center distance 2R) = only 1 node fits
  return Math.max(1, Math.floor(Math.PI / Math.asin(s)));
}

export function buildPyramidLayout(nodes: PyramidNode[], links: PyramidLink[]): PyramidLayout {
  const N = nodes.length;
  const idx = new Map<string, number>();
  nodes.forEach((n, i) => idx.set(n.id, i));

  // Hierarchy edges (both ends in the set, self-loops excluded). Direction is parent (upper) -> child (lower).
  const edges: PyramidEdge[] = [];
  for (const l of links) {
    const p = idx.get(l.parent);
    const c = idx.get(l.child);
    if (p === undefined || c === undefined || p === c) continue;
    edges.push({ p, c, section: l.section });
  }
  // Adjacency (parents, children) for hover, plus a child -> parent reverse lookup (precomputed into a Map so angle sorting doesn't scan all edges every time).
  const adj: Set<number>[] = nodes.map(() => new Set<number>());
  const parentsByChild: number[][] = nodes.map(() => []);
  for (const e of edges) {
    adj[e.p].add(e.c);
    adj[e.c].add(e.p);
    parentsByChild[e.c].push(e.p);
  }

  const maxLevel = nodes.reduce((mx, n) => Math.max(mx, n.level), 0);
  const levelMid = maxLevel / 2;
  const byLevel: number[][] = Array.from({ length: maxLevel + 1 }, () => []);
  nodes.forEach((n, i) => byLevel[n.level].push(i));

  // Reorder children by their parents' mean angle to reduce edge crossings between levels (finalized top level first).
  // Levels that don't fit on a single ring overflow onto additional concentric rings outward.
  // (If the radius were determined by level alone, nodes in levels with many children would overlap and become indistinguishable.
  //   e.g. a ring of radius 232 with minimum spacing 16 fits up to 91 nodes; beyond that they overlap)
  const angle = new Float64Array(N);
  const radiusOf = new Float64Array(N);
  const tierRings: number[][] = [];
  for (let L = 0; L <= maxLevel; L++) {
    const arr = byLevel[L];
    if (L > 0) {
      const keyOf = (i: number) => {
        let sum = 0,
          cnt = 0;
        for (const p of parentsByChild[i]) {
          if (nodes[p].level < L) {
            sum += angle[p];
            cnt++;
          }
        }
        return cnt ? sum / cnt : Math.PI; // Near the center if there is no parent
      };
      arr.sort((a, b) => keyOf(a) - keyOf(b));
    }
    const base = R0 + L * RSTEP;
    // Match the spacing to the diameter of the largest node in this level (it's evaluated per level, so
    // a single hub in one level doesn't needlessly widen every level).
    let tierMaxDeg = 0;
    for (const i of arr) tierMaxDeg = Math.max(tierMaxDeg, nodes[i].deg);
    const tierDiameter = 2 * nodeRadius(tierMaxDeg);
    const arc = Math.max(MIN_ARC, tierDiameter + 4);
    const gap = Math.max(SUB_GAP, tierDiameter + 6);
    const rings: number[] = [];
    let placed = 0;
    let ring = 0;
    do {
      const R = base + ring * gap;
      const take = Math.min(ringCapacity(R, arc), Math.max(1, arr.length - placed));
      rings.push(R);
      for (let k = 0; k < take && placed + k < arr.length; k++) {
        const i = arr[placed + k];
        // Rotate slightly per level and per concentric ring to avoid overlap directly below and between inner/outer rings
        angle[i] = (k / take) * Math.PI * 2 + L * 0.5 + ring * 0.31;
        radiusOf[i] = R;
      }
      placed += take;
      ring++;
    } while (placed < arr.length);
    tierRings.push(rings);
  }

  const bx = new Float64Array(N);
  const by = new Float64Array(N);
  const bz = new Float64Array(N);
  for (let i = 0; i < N; i++) {
    const L = nodes[i].level;
    const R = radiusOf[i];
    bx[i] = Math.cos(angle[i]) * R;
    bz[i] = Math.sin(angle[i]) * R;
    by[i] = (levelMid - L) * LEVEL_GAP;
  }
  // Maximum radius including rings that spread outward from overflow (the basis for scale and camera distance).
  let maxR = R0;
  for (const rs of tierRings) for (const r of rs) maxR = Math.max(maxR, r);

  return { N, edges, adj, maxLevel, levelMid, bx, by, bz, maxR, tierRings, LEVEL_GAP, R0, RSTEP };
}
