'use client';

import { useEffect, useRef } from 'react';
import { useRouter } from 'next/navigation';

// カタログ関連グラフ（Obsidian / Kaname ライク）。
// - 線 = 実在する関係と分類から導出した関係（無向表示・重複/自己リンクは除外）
// - 色 = 区分（骨格 / 統制 / リスク / 未投入。サーバー側で bucket 済み）
// - 大きさ = 表示グラフ内での関連数（次数）
// 依存追加なしの素の Canvas + 簡易 force simulation。テーマ切替イベントで色を再取得して再描画する。

export type GraphNode = { id: string; title: string; deg: number; bucket: number };
export type GraphLink = { s: string; t: string };

const THEME_EVENT = 'isms-theme-change';

export function GraphCanvas({ nodes, links }: { nodes: GraphNode[]; links: GraphLink[] }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const router = useRouter();

  useEffect(() => {
    const canvasEl = canvasRef.current;
    if (!canvasEl) return;
    const wrapEl = canvasEl.parentElement;
    if (!wrapEl) return;
    const ctxEl = canvasEl.getContext('2d');
    if (!ctxEl) return;
    // クロージャ内でも非nullを保つため、ナローイング済みの値を新しい const に束ね直す。
    const canvas = canvasEl;
    const wrap = wrapEl;
    const ctx = ctxEl;

    const N = nodes.length;
    const idx = new Map<string, number>();
    nodes.forEach((n, i) => idx.set(n.id, i));

    // エッジをノード index 化し、自己リンク・重複（無向）を除去
    const seen = new Set<string>();
    const edges: [number, number][] = [];
    for (const l of links) {
      const a = idx.get(l.s);
      const b = idx.get(l.t);
      if (a === undefined || b === undefined || a === b) continue;
      const key = a < b ? `${a}-${b}` : `${b}-${a}`;
      if (seen.has(key)) continue;
      seen.add(key);
      edges.push([a, b]);
    }
    // 隣接集合（hover ハイライト用）
    const adj: Set<number>[] = nodes.map(() => new Set<number>());
    for (const [a, b] of edges) { adj[a].add(b); adj[b].add(a); }

    // シミュレーション状態（毎フレーム React state を触らないよう ref/ローカルで保持）
    const px = new Float64Array(N);
    const py = new Float64Array(N);
    const vx = new Float64Array(N);
    const vy = new Float64Array(N);
    let W = 0, H = 0, dpr = 1, inited = false;

    function initLayout() {
      // 円周上に並べると、929件では隣同士が2px間隔になり最初から重なる。
      // 黄金角のらせんで円盤全体へ均等に散らしてから始める。
      const spread = Math.min(W, H) * 0.48;
      const golden = Math.PI * (3 - Math.sqrt(5));
      for (let i = 0; i < N; i++) {
        const r = spread * Math.sqrt((i + 0.5) / Math.max(1, N));
        const ang = i * golden;
        px[i] = W / 2 + Math.cos(ang) * r;
        py[i] = H / 2 + Math.sin(ang) * r;
        vx[i] = 0; vy[i] = 0;
      }
    }

    // 次数が大きいノードでも上限を設ける。上限が無いと、配下の多いカテゴリが
    // 巨大な円になって、その下にいる子ノートを覆い隠してしまう。
    function baseRadius(i: number) { return Math.min(3.5 + Math.sqrt(nodes[i].deg) * 1.5, 13); }

    // 収める円盤の面積に対してノードが多すぎると、どう並べても物理的に入らず必ず重なる
    // （＝ノートが隠れる）。スマホ幅や件数の多い org でもそうならないよう、
    // 「全部が入る大きさ」まで一律に縮める。縮めても最低 1.6px は残して見えなくしない。
    const GAP = 3;              // ノード同士の最小すき間（px、縮小と同じ率で効かせる）
    const COLLIDE_PASSES = 8;   // 1フレームあたりの重なり解消の最大回数（解け切ったら早期終了）
    // 円盤に対する実効充填率。実データ929ノート・3095辺で、デスクトップ(1700x760)と
    // スマホ幅(390x620)の両方で「重なり0対」になることを確かめた値（0.62 では狭い画面で重なった）。
    const FILL = 0.45;
    let sizeScale = 1;

    function computeSizeScale() {
      const R = Math.min(W, H) / 2 - 16;
      if (N === 0 || R <= 0) { sizeScale = 1; return; }
      let need = 0;
      for (let i = 0; i < N; i++) {
        const r = baseRadius(i) + GAP / 2;
        need += Math.PI * r * r;
      }
      const usable = Math.PI * R * R * FILL;
      sizeScale = need > usable ? Math.max(0.12, Math.sqrt(usable / need)) : 1;
    }

    function radius(i: number) { return Math.max(1.6, baseRadius(i) * sizeScale); }
    function gap() { return GAP * sizeScale; }

    // テーマ依存色（CSS 変数から実色を読む。Canvas はクラスを解釈しないため getComputedStyle）
    type Palette = { bucket: string[]; line: string; lineHi: string; label: string; halo: string; ring: string };
    function readPalette(): Palette {
      const cs = getComputedStyle(document.documentElement);
      const v = (name: string) => cs.getPropertyValue(name).trim();
      return {
        // 0:〜30日=新鮮(緑) 1:〜90日=最近(インディゴ) 2:〜180日=やや古い(琥珀) 3:180日超=古い(赤)
        bucket: [v('--success'), v('--accent'), v('--warning'), v('--danger')],
        line: v('--border-strong'),
        lineHi: v('--accent'),
        label: v('--foreground'),
        halo: v('--surface'),
        ring: v('--accent'),
      };
    }
    let pal = readPalette();

    let hover = -1;
    let drag = -1;
    let downIdx = -1;
    let downX = 0, downY = 0, moved = false;
    let alpha = 1;
    let raf = 0;
    let running = false;
    const prefersReduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    function nodeAt(mx: number, my: number) {
      // 上に描かれる（後の）ノードを優先して当たり判定
      for (let i = N - 1; i >= 0; i--) {
        const dx = mx - px[i], dy = my - py[i];
        const rr = radius(i) + 4;
        if (dx * dx + dy * dy <= rr * rr) return i;
      }
      return -1;
    }

    // ---- 近傍探索用の一様格子 ----
    // 総当たり(O(N²))は929件で毎フレーム約86万回になる。格子に入れて近傍セルだけを見る。
    // セル幅は「ぶつかり得る最大距離」(半径13+13+3=29px)より大きく取る。
    const CELL = 48;
    let gw = 0, gh = 0;
    let gCount = new Int32Array(0);
    let gStart = new Int32Array(0);
    let gCursor = new Int32Array(0);
    const gItem = new Int32Array(N);

    function cellOf(i: number) {
      const a = Math.min(gw - 1, Math.max(0, (px[i] / CELL) | 0));
      const b = Math.min(gh - 1, Math.max(0, (py[i] / CELL) | 0));
      return b * gw + a;
    }

    function buildGrid() {
      const nw = Math.max(1, Math.ceil(W / CELL));
      const nh = Math.max(1, Math.ceil(H / CELL));
      if (nw !== gw || nh !== gh) {
        gw = nw; gh = nh;
        gCount = new Int32Array(gw * gh);
        gStart = new Int32Array(gw * gh + 1);
        gCursor = new Int32Array(gw * gh);
      } else {
        gCount.fill(0);
      }
      const cells = gw * gh;
      for (let i = 0; i < N; i++) gCount[cellOf(i)]++;
      gStart[0] = 0;
      for (let c = 0; c < cells; c++) gStart[c + 1] = gStart[c] + gCount[c];
      gCursor.set(gStart.subarray(0, cells));
      for (let i = 0; i < N; i++) gItem[gCursor[cellOf(i)]++] = i;
    }

    // 位置を収める先を「枠の矩形」ではなく**円**にする。矩形だと外側のノードが
    // 上下左右の縁に張り付き、全体が四角く見えて読みづらい。
    function clampToDisc(i: number) {
      const cx = W / 2, cy = H / 2;
      const lim = Math.min(W, H) / 2 - 16 - radius(i);
      const dx = px[i] - cx, dy = py[i] - cy;
      const d = Math.hypot(dx, dy);
      if (d > lim && d > 0) {
        px[i] = cx + (dx / d) * lim;
        py[i] = cy + (dy / d) * lim;
      }
    }

    // ばねの自然長は「その辺の先にいるハブの子の数」で決める。
    // 子が217件なら、半径96pxの円周には並び切らない。並べるだけの長さまで伸ばす。
    function restLen(a: number, b: number) {
      const deg = Math.max(nodes[a].deg, nodes[b].deg);
      return Math.min(46 + deg * 2.9, 620);
    }

    function step() {
      const cx = W / 2, cy = H / 2;
      const k = 2600;              // 近傍反発の係数（格子の範囲内にだけ効く）
      const grav = 0.010;          // 中心への引力
      const spring = 0.020;

      buildGrid();
      for (let i = 0; i < N; i++) {
        if (i === drag) continue;
        let fx = (cx - px[i]) * grav;
        let fy = (cy - py[i]) * grav;
        const ci = Math.min(gw - 1, Math.max(0, (px[i] / CELL) | 0));
        const cj = Math.min(gh - 1, Math.max(0, (py[i] / CELL) | 0));
        for (let oy = -1; oy <= 1; oy++) {
          const yy = cj + oy;
          if (yy < 0 || yy >= gh) continue;
          for (let ox = -1; ox <= 1; ox++) {
            const xx = ci + ox;
            if (xx < 0 || xx >= gw) continue;
            const c = yy * gw + xx;
            for (let p = gStart[c]; p < gStart[c + 1]; p++) {
              const j = gItem[p];
              if (i === j) continue;
              let dx = px[i] - px[j], dy = py[i] - py[j];
              let d2 = dx * dx + dy * dy;
              if (d2 < 0.01) { d2 = 0.01; dx = ((i - j) % 7) * 0.1 + 0.05; dy = 0.07; }
              const d = Math.sqrt(d2);
              const f = k / d2;
              fx += (dx / d) * f;
              fy += (dy / d) * f;
            }
          }
        }
        vx[i] = (vx[i] + fx) * 0.82;
        vy[i] = (vy[i] + fy) * 0.82;
      }

      for (const [a, b] of edges) {
        const dx = px[b] - px[a], dy = py[b] - py[a];
        const d = Math.hypot(dx, dy) || 0.01;
        const f = (d - restLen(a, b)) * spring;
        const ux = dx / d, uy = dy / d;
        // ハブほど1本あたりの引きを弱める。217本に引かれると中心が潰れて団子になる。
        const wa = 1 / (1 + Math.sqrt(nodes[a].deg));
        const wb = 1 / (1 + Math.sqrt(nodes[b].deg));
        if (a !== drag) { vx[a] += ux * f * wa; vy[a] += uy * f * wa; }
        if (b !== drag) { vx[b] -= ux * f * wb; vy[b] -= uy * f * wb; }
      }

      for (let i = 0; i < N; i++) {
        if (i === drag) continue;
        px[i] += vx[i] * alpha;
        py[i] += vy[i] * alpha;
        clampToDisc(i);
      }

      // 重なりは「力」ではなく位置で直す。力だと alpha が冷えた後に効かなくなり、
      // 重なったまま止まる＝ノートが隠れる。円が接するまで毎フレーム押し戻す。
      // 密なほど回数が要る（狭い画面では2回では解け切らないことを実測で確認）。
      // 押す相手が無くなったら即抜けるので、空いている時は1回で終わる。
      for (let pass = 0; pass < COLLIDE_PASSES; pass++) {
        let moved = false;
        buildGrid();
        for (let i = 0; i < N; i++) {
          const ci = Math.min(gw - 1, Math.max(0, (px[i] / CELL) | 0));
          const cj = Math.min(gh - 1, Math.max(0, (py[i] / CELL) | 0));
          for (let oy = -1; oy <= 1; oy++) {
            const yy = cj + oy;
            if (yy < 0 || yy >= gh) continue;
            for (let ox = -1; ox <= 1; ox++) {
              const xx = ci + ox;
              if (xx < 0 || xx >= gw) continue;
              const c = yy * gw + xx;
              for (let p = gStart[c]; p < gStart[c + 1]; p++) {
                const j = gItem[p];
                if (j <= i) continue;
                let dx = px[j] - px[i], dy = py[j] - py[i];
                let d = Math.hypot(dx, dy);
                const md = radius(i) + radius(j) + gap();
                if (d >= md) continue;
                if (d < 0.01) {
                  dx = ((i % 5) - 2) * 0.5 + 0.3;
                  dy = ((j % 5) - 2) * 0.5 + 0.3;
                  d = Math.hypot(dx, dy) || 0.01;
                }
                const push = (md - d) / 2;
                const ux = dx / d, uy = dy / d;
                if (i !== drag) { px[i] -= ux * push; py[i] -= uy * push; }
                if (j !== drag) { px[j] += ux * push; py[j] += uy * push; }
                moved = true;
              }
            }
          }
        }
        for (let i = 0; i < N; i++) clampToDisc(i);
        if (!moved) break;   // 重なりが無くなったら以降のパスは不要
      }

      alpha *= 0.992;   // 散り切る前に止まらないよう、冷え方を緩める
    }

    function draw() {
      ctx.clearRect(0, 0, W, H);
      // エッジ
      ctx.lineWidth = 1;
      for (const [a, b] of edges) {
        const hot = hover >= 0 && (a === hover || b === hover);
        ctx.strokeStyle = hot ? pal.lineHi : pal.line;
        ctx.globalAlpha = hover >= 0 ? (hot ? 0.9 : 0.18) : 0.5;
        ctx.beginPath();
        ctx.moveTo(px[a], py[a]);
        ctx.lineTo(px[b], py[b]);
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
      // ノード
      for (let i = 0; i < N; i++) {
        const isHover = i === hover;
        const isNeighbor = hover >= 0 && adj[hover].has(i);
        const dim = hover >= 0 && !isHover && !isNeighbor;
        ctx.globalAlpha = dim ? 0.35 : 1;
        ctx.beginPath();
        ctx.arc(px[i], py[i], radius(i), 0, Math.PI * 2);
        ctx.fillStyle = pal.bucket[nodes[i].bucket] || pal.bucket[3];
        ctx.fill();
        if (isHover || isNeighbor) {
          ctx.lineWidth = 2;
          ctx.strokeStyle = pal.ring;
          ctx.stroke();
        }
      }
      ctx.globalAlpha = 1;
      // ラベル（hover とその隣接のみ表示して混雑を避ける）
      if (hover >= 0) {
        ctx.font = '600 12px -apple-system, "Hiragino Kaku Gothic ProN", "Noto Sans JP", sans-serif';
        ctx.textBaseline = 'middle';
        const show = [hover, ...adj[hover]];
        for (const i of show) {
          const label = nodes[i].title;
          const tx = px[i] + radius(i) + 5;
          const ty = py[i];
          const w = ctx.measureText(label).width;
          ctx.globalAlpha = 0.82;
          ctx.fillStyle = pal.halo;
          ctx.fillRect(tx - 3, ty - 9, w + 6, 18);
          ctx.globalAlpha = i === hover ? 1 : 0.85;
          ctx.fillStyle = pal.label;
          ctx.fillText(label, tx, ty);
        }
        ctx.globalAlpha = 1;
      }
    }

    function frame() {
      step();
      draw();
      if (alpha > 0.004 && document.visibilityState === 'visible') {
        raf = requestAnimationFrame(frame);
      } else {
        running = false;
      }
    }
    // reduced-motion では requestAnimationFrame のループを回さない。
    // ただし「描くだけ」にすると重なり解消（step 内の位置補正）が一度も走らず、
    // ノードが重なったまま＝ノートが隠れる。アニメーションはせずに、
    // その場で有限回だけ整定させてから1度描く。
    function settleStatic(iters: number, startAlpha: number) {
      alpha = Math.max(alpha, startAlpha);
      for (let i = 0; i < iters; i++) step();
      draw();
    }

    function reheat(a = 0.6) {
      alpha = Math.max(alpha, a);
      // reduced-motion ではアニメせず、その場で整定させてから描く。
      if (prefersReduced) { settleStatic(150, a); return; }
      if (!running && document.visibilityState === 'visible') {
        running = true;
        raf = requestAnimationFrame(frame);
      }
    }

    function resize() {
      const rect = wrap.getBoundingClientRect();
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = Math.max(1, Math.floor(rect.width));
      H = Math.max(1, Math.floor(rect.height));
      canvas.width = Math.floor(W * dpr);
      canvas.height = Math.floor(H * dpr);
      canvas.style.width = `${W}px`;
      canvas.style.height = `${H}px`;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      computeSizeScale();   // 画面が変わったら「収まる大きさ」を取り直す
      const first = !inited;
      if (first) { initLayout(); inited = true; }
      // 可視状態やモーション設定に依らず、リサイズ毎に現在位置を必ず一度描画する
      // （canvas.width/height の再代入でバッファがクリアされるため、初回以外でも透明化を防ぐ）。
      draw();
      if (prefersReduced) {
        // アニメはしないが、重なりを解くところまでは必ずやる。初回は散らす分だけ多く回す。
        settleStatic(first ? 600 : 150, first ? 1 : 0.3);
      } else {
        reheat(0.3);
      }
    }

    // ---- events ----
    function pointerPos(e: PointerEvent) {
      const rect = canvas.getBoundingClientRect();
      return { x: e.clientX - rect.left, y: e.clientY - rect.top };
    }
    function onMove(e: PointerEvent) {
      const { x, y } = pointerPos(e);
      if (drag >= 0) {
        px[drag] = x; py[drag] = y; vx[drag] = 0; vy[drag] = 0;
        moved = true;
        reheat(0.5);
        return;
      }
      const h = nodeAt(x, y);
      if (h !== hover) {
        hover = h;
        canvas.style.cursor = h >= 0 ? 'pointer' : 'default';
        if (!running) draw();
      }
      if (downIdx >= 0 && (Math.abs(x - downX) > 3 || Math.abs(y - downY) > 3)) {
        drag = downIdx; moved = true;
      }
    }
    function onDown(e: PointerEvent) {
      const { x, y } = pointerPos(e);
      downIdx = nodeAt(x, y);
      downX = x; downY = y; moved = false;
      if (downIdx >= 0) canvas.setPointerCapture(e.pointerId);
    }
    function onUp() {
      if (downIdx >= 0 && !moved) {
        router.push(`/n/${nodes[downIdx].id}`);
      }
      drag = -1; downIdx = -1; moved = false;
    }
    // タッチ/ペンのジェスチャ中断やタブ切替で pointerup が来ない場合に状態が残らないようにする。
    function onCancel() {
      drag = -1; downIdx = -1; moved = false;
    }
    function onLeave() {
      if (hover !== -1) { hover = -1; canvas.style.cursor = 'default'; if (!running) draw(); }
    }
    function onTheme() { pal = readPalette(); draw(); }
    function onVisibility() { if (document.visibilityState === 'visible') reheat(0.05); }

    const ro = new ResizeObserver(resize);
    ro.observe(wrap);
    canvas.addEventListener('pointermove', onMove);
    canvas.addEventListener('pointerdown', onDown);
    canvas.addEventListener('pointerup', onUp);
    canvas.addEventListener('pointercancel', onCancel);
    canvas.addEventListener('lostpointercapture', onCancel);
    canvas.addEventListener('pointerleave', onLeave);
    window.addEventListener(THEME_EVENT, onTheme);
    document.addEventListener('visibilitychange', onVisibility);

    resize();

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
      canvas.removeEventListener('pointermove', onMove);
      canvas.removeEventListener('pointerdown', onDown);
      canvas.removeEventListener('pointerup', onUp);
      canvas.removeEventListener('pointercancel', onCancel);
      canvas.removeEventListener('lostpointercapture', onCancel);
      canvas.removeEventListener('pointerleave', onLeave);
      window.removeEventListener(THEME_EVENT, onTheme);
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, [nodes, links, router]);

  return (
    <div className="relative h-[calc(100vh-160px)] min-h-[420px] w-full overflow-hidden rounded-[var(--radius-lg)] border border-[var(--border)] bg-[var(--surface)] shadow-[var(--shadow-sm)]">
      <canvas ref={canvasRef} className="block h-full w-full touch-none" />
    </div>
  );
}
