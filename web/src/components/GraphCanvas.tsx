'use client';

import { useEffect, useRef } from 'react';
import { useRouter } from 'next/navigation';

// Catalog relationship graph (Obsidian-like).
// - Edges = actual relationships plus relationships derived from classification (undirected; duplicate/self links excluded)
// - Color = category (skeleton / control / risk / not yet loaded; bucketed server-side)
// - Size = number of relations within the displayed graph (degree)
// Plain Canvas + a simple force simulation with no added dependencies. Re-reads colors and redraws on theme change events.

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
    // Rebind the narrowed values to new consts so they stay non-null inside closures.
    const canvas = canvasEl;
    const wrap = wrapEl;
    const ctx = ctxEl;

    const N = nodes.length;
    const idx = new Map<string, number>();
    nodes.forEach((n, i) => idx.set(n.id, i));

    // Convert edges to node indexes and remove self links and (undirected) duplicates
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
    // Adjacency sets (for hover highlighting)
    const adj: Set<number>[] = nodes.map(() => new Set<number>());
    for (const [a, b] of edges) { adj[a].add(b); adj[b].add(a); }

    // Simulation state (kept in refs/locals so React state is not touched every frame)
    const px = new Float64Array(N);
    const py = new Float64Array(N);
    const vx = new Float64Array(N);
    const vy = new Float64Array(N);
    let W = 0, H = 0, dpr = 1, inited = false;

    function initLayout() {
      // Placing nodes on a circle puts neighbors 2px apart at 929 items, overlapping from the start.
      // Start by scattering them evenly across the whole disk using a golden-angle spiral.
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

    // Cap the size even for high-degree nodes. Without a cap, categories with many children
    // become huge circles that hide the child notes beneath them.
    function baseRadius(i: number) { return Math.min(3.5 + Math.sqrt(nodes[i].deg) * 1.5, 13); }

    // If there are too many nodes for the disk area, they physically cannot fit and will always overlap
    // (= notes get hidden). To avoid that even at phone width or in orgs with many items,
    // shrink uniformly to "a size where everything fits". Even when shrunk, keep at least 1.6px so nothing disappears.
    const GAP = 3;              // Minimum gap between nodes (px, scaled by the same factor as the shrink)
    const COLLIDE_PASSES = 8;   // Max overlap-resolution passes per frame (exits early once fully resolved)
    // Effective packing ratio relative to the disk. With real data of 929 notes and 3095 edges, verified to give
    // "0 overlapping pairs" on both desktop (1700x760) and phone width (390x620) (0.62 overlapped on narrow screens).
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

    // Theme-dependent colors (read actual colors from CSS variables; getComputedStyle because Canvas does not interpret classes)
    type Palette = { bucket: string[]; line: string; lineHi: string; label: string; halo: string; ring: string };
    function readPalette(): Palette {
      const cs = getComputedStyle(document.documentElement);
      const v = (name: string) => cs.getPropertyValue(name).trim();
      return {
        // 0: up to 30 days = fresh (green) 1: up to 90 days = recent (indigo) 2: up to 180 days = somewhat old (amber) 3: over 180 days = old (red)
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
      // Hit-test preferring nodes drawn on top (later)
      for (let i = N - 1; i >= 0; i--) {
        const dx = mx - px[i], dy = my - py[i];
        const rr = radius(i) + 4;
        if (dx * dx + dy * dy <= rr * rr) return i;
      }
      return -1;
    }

    // ---- Uniform grid for neighbor search ----
    // Brute force (O(N²)) is about 860k checks per frame at 929 items. Bucket into a grid and only check neighboring cells.
    // Make the cell width larger than the "maximum possible collision distance" (radius 13+13+3=29px).
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

    // Constrain positions to a **circle** rather than the frame rectangle. With a rectangle, outer nodes
    // stick to the top/bottom/left/right edges, and the whole thing looks boxy and hard to read.
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

    // A spring's natural length is set by "the number of children of the hub at the far end of that edge".
    // 217 children won't fit on a circle of radius 96px. Stretch it to a length where they fit.
    function restLen(a: number, b: number) {
      const deg = Math.max(nodes[a].deg, nodes[b].deg);
      return Math.min(46 + deg * 2.9, 620);
    }

    function step() {
      const cx = W / 2, cy = H / 2;
      const k = 2600;              // Neighbor repulsion coefficient (only applies within grid range)
      const grav = 0.010;          // Attraction toward the center
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
        // Weaken per-edge pull for hubs. Being pulled by 217 edges crushes the center into a clump.
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

      // Fix overlaps by position, not "force". Forces stop working once alpha cools,
      // leaving nodes stuck overlapping = notes hidden. Push apart every frame until circles just touch.
      // Denser layouts need more passes (measured: 2 passes do not fully resolve on narrow screens).
      // Exits as soon as there is nothing left to push, so it finishes in 1 pass when sparse.
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
        if (!moved) break;   // No further passes needed once overlaps are gone
      }

      alpha *= 0.992;   // Slow the cooling so it doesn't stop before fully spreading out
    }

    function draw() {
      ctx.clearRect(0, 0, W, H);
      // Edges
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
      // Nodes
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
      // Labels (shown only for the hovered node and its neighbors to avoid clutter)
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
    // Under reduced-motion, don't run the requestAnimationFrame loop.
    // But "just drawing" would never run overlap resolution (the position correction inside step),
    // leaving nodes overlapping = notes hidden. Without animating,
    // settle it a finite number of times in place, then draw once.
    function settleStatic(iters: number, startAlpha: number) {
      alpha = Math.max(alpha, startAlpha);
      for (let i = 0; i < iters; i++) step();
      draw();
    }

    function reheat(a = 0.6) {
      alpha = Math.max(alpha, a);
      // Under reduced-motion, settle in place without animating, then draw.
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
      computeSizeScale();   // Recompute the "fitting size" when the screen changes
      const first = !inited;
      if (first) { initLayout(); inited = true; }
      // Always draw the current positions once per resize, regardless of visibility or motion settings
      // (reassigning canvas.width/height clears the buffer, so this prevents going blank after the first time too).
      draw();
      if (prefersReduced) {
        // No animation, but always go as far as resolving overlaps. Run more passes the first time to scatter.
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
    // Prevent lingering state when pointerup never arrives due to touch/pen gesture cancellation or tab switching.
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
