// 階層ピラミッドのレイアウト計算（純関数・DOM非依存）。
// flat(正射影) / persp(遠近) / webgl(three.js) の3表示で同一の座標・階層・エッジを共有し、
// 表示間で見た目がズレないための単一の真実源。座標は「回転前」の3D基準座標。

// derived=true は「分類から導出したまとまり（DB の行ではない）」。実体の行と区別できるよう白抜きで描く。
// 導出ノードは統制やリスクを束ねる中間の見出しであり、DB に対応する行は無い。
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
  // 回転前の基準座標（y は上向き正: 頂点=level0 が上）。長さ N。
  bx: Float64Array;
  by: Float64Array;
  bz: Float64Array;
  maxR: number;
  // 階層ごとに実際に使った同心リングの半径。溢れた階層は複数持つ。描画側のリング線はこれを使う。
  tierRings: number[][];
  LEVEL_GAP: number;
  R0: number;
  RSTEP: number;
};

const LEVEL_GAP = 74; // 階層間の高さ
const R0 = 34; // 頂点付近の半径
const RSTEP = 66; // 1階層深くなるごとに広がる量
// ノードの描画半径。接続本数が大きいほど大きい。レイアウトの間隔計算と各ビューの描画で
// 同じ値を使うため、ここを単一の定義とする（別々に持つと間隔と実寸がずれて重なる）。
export function nodeRadius(deg: number): number {
  return 4 + Math.sqrt(deg) * 2.1;
}

// 同一リング上で隣り合うノードの最小間隔（ワールド単位）の下限。
// 実際の間隔はその階層で最も大きいノードの直径から決める（次数の大きいノードは半径も大きく、
// 固定値だと直径が間隔を上回って重なるため）。
const MIN_ARC = 16;
// 1本のリングに収まらない階層を、外側へ増やしていく同心リングの間隔の下限。
const SUB_GAP = 24;

// 半径 R のリングに、隣り合う中心間距離 spacing を保って置けるノード数。
// 判定は弧長ではなく弦長で行う（n 個を等間隔に置いたときの中心間距離は 2R*sin(π/n)）。
// 弧長で数えると、半径が小さく間隔が大きいときに実距離が足りず重なる。
// 下限は 1（入らない分は外側のリングへ送る）。
function ringCapacity(R: number, spacing: number): number {
  const s = spacing / (2 * R);
  if (s >= 1) return 1; // 2個置いた時点（中心間 2R）で足りない＝1個しか置けない
  return Math.max(1, Math.floor(Math.PI / Math.asin(s)));
}

export function buildPyramidLayout(nodes: PyramidNode[], links: PyramidLink[]): PyramidLayout {
  const N = nodes.length;
  const idx = new Map<string, number>();
  nodes.forEach((n, i) => idx.set(n.id, i));

  // 階層エッジ（両端が集合内・自己ループ除外）。方向は parent(上位) → child(下位)。
  const edges: PyramidEdge[] = [];
  for (const l of links) {
    const p = idx.get(l.parent);
    const c = idx.get(l.child);
    if (p === undefined || c === undefined || p === c) continue;
    edges.push({ p, c, section: l.section });
  }
  // hover 用の隣接（親・子）と、子→親の逆引き（角度ソートで毎回 edges 全走査しないため事前 Map 化）。
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

  // 親の平均角度で子を並べ替え、上下でエッジ交差を減らす（上の階層から順に確定）。
  // 1本のリングに収まらない階層は、外側へ同心リングを足して溢れさせる。
  // （半径を level だけで決めると、子の多い階層でノードが重なり判別できなくなる。
  //   例: 半径232のリングは最小間隔16なら91件までで、それを超えると重なる）
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
        return cnt ? sum / cnt : Math.PI; // 親が無ければ中央付近
      };
      arr.sort((a, b) => keyOf(a) - keyOf(b));
    }
    const base = R0 + L * RSTEP;
    // 間隔はこの階層で最も大きいノードの直径に合わせる（階層ごとに見るので、
    // ハブが1つある階層のために全階層をむやみに広げない）。
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
        // 階層ごと・同心リングごとに少し回して、真下・内外の重なりを避ける
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
  // 溢れで外側に広がったリングも含めた最大半径（scale・カメラ距離の基準）。
  let maxR = R0;
  for (const rs of tierRings) for (const r of rs) maxR = Math.max(maxR, r);

  return { N, edges, adj, maxLevel, levelMid, bx, by, bz, maxR, tierRings, LEVEL_GAP, R0, RSTEP };
}
