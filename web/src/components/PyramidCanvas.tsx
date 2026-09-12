'use client';

import { useEffect, useRef } from 'react';
import { useRouter } from 'next/navigation';
import { buildPyramidLayout, nodeRadius, type PyramidNode, type PyramidLink } from '@/lib/pyramidLayout';

// Pyramid of the classification hierarchy (3D).
// - Height (vertical position) = classification level (level 0 = top rule at the apex; deeper goes lower)
// - Each level is placed on a circle in the XZ plane, widening with depth = pyramid/cone shape
// - Directed arrows = direction from upper to lower (upper rule parent -> lower rule child)
// - Drag to rotate azimuth (left/right) and elevation (up/down) for a 3D view (orthographic projection with no library dependency)
// - Color = bucket, size = number of connections, fainter toward the back (painter's algorithm)
// Re-read colors and redraw on the theme change event.

export type { PyramidNode, PyramidLink };

const THEME_EVENT = 'isms-theme-change';

// projection: 'ortho' = orthographic (2.5D) / 'persp' = perspective (3D with depth). Coordinates and rotation are shared; only the projection switches.
export function PyramidCanvas({
  nodes,
  links,
  projection = 'ortho',
}: {
  nodes: PyramidNode[];
  links: PyramidLink[];
  projection?: 'ortho' | 'persp';
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const router = useRouter();

  useEffect(() => {
    const canvasEl = canvasRef.current;
    if (!canvasEl) return;
    const wrapEl = canvasEl.parentElement;
    if (!wrapEl) return;
    const ctxEl = canvasEl.getContext('2d');
    if (!ctxEl) return;
    const canvas = canvasEl;
    const wrap = wrapEl;
    const ctx = ctxEl;

    // Layout computation lives in a shared pure function (single source of truth that keeps coordinates identical across flat/persp/webgl).
    const { N, edges, adj, maxLevel, levelMid, bx, by, bz, maxR, tierRings, LEVEL_GAP } = buildPyramidLayout(nodes, links);

    // ---- Camera (azimuth theta, elevation phi) and projection ----
    let theta = 0.7;           // left/right rotation
    let phi = 0.42;            // look-down angle (0 = side view; larger = more from above)
    let W = 0, H = 0, dpr = 1, scale = 1, inited = false;

    const sx = new Float64Array(N);
    const sy = new Float64Array(N);
    const sd = new Float64Array(N); // depth (larger = closer)
    const order = new Int32Array(N);
    const pf = new Float64Array(N).fill(1); // perspective scale factor (persp only: >1 near / <1 far; 1 for ortho)

    // Focal length for perspective projection (relative to scene size). Always clamp the denominator and factor to prevent breakdown near z2 -> FOCAL.
    const persp = projection === 'persp';
    const FOCAL = (maxR + LEVEL_GAP) * 3;
    const perspK = (z2: number) =>
      persp ? Math.max(0.5, Math.min(1.9, FOCAL / Math.max(FOCAL * 0.35, FOCAL - z2))) : 1;

    function project() {
      const ct = Math.cos(theta), st = Math.sin(theta);
      const cp = Math.cos(phi), sp = Math.sin(phi);
      const cx = W / 2, cy = H / 2;
      for (let i = 0; i < N; i++) {
        // rotate by theta around the Y axis
        const x1 = bx[i] * ct + bz[i] * st;
        const z1 = -bx[i] * st + bz[i] * ct;
        // tilt by phi around the X axis (look down)
        const y2 = by[i] * cp - z1 * sp;
        const z2 = by[i] * sp + z1 * cp; // closer is larger
        const k = perspK(z2);
        sx[i] = cx + x1 * scale * k;
        sy[i] = cy - y2 * scale * k;
        sd[i] = z2;
        pf[i] = k;
        order[i] = i;
      }
      // draw back to front (painter's algorithm)
      order.sort((a, b) => sd[a] - sd[b]);
    }

    // Point list for projecting and drawing level rings (circles in the XZ plane).
    // Overflowing levels have multiple concentric rings, so the radius is passed in by the caller.
    function tierPath(L: number, R: number): [number, number][] | null {
      const y = (levelMid - L) * LEVEL_GAP;
      const ct = Math.cos(theta), st = Math.sin(theta);
      const cp = Math.cos(phi), sp = Math.sin(phi);
      const cx = W / 2, cy = H / 2;
      const pts: [number, number][] = [];
      const SEG = 48;
      for (let k = 0; k <= SEG; k++) {
        const a = (k / SEG) * Math.PI * 2;
        const x = Math.cos(a) * R, z = Math.sin(a) * R;
        const x1 = x * ct + z * st;
        const z1 = -x * st + z * ct;
        const y2 = y * cp - z1 * sp;
        const z2 = y * sp + z1 * cp;
        const pk = perspK(z2);
        pts.push([cx + x1 * scale * pk, cy - y2 * scale * pk]);
      }
      return pts;
    }

    // The radius uses the same definition as the layout spacing computation (keeping them separate causes overlap).
    // Coordinates are mapped to the screen multiplied by scale, so the radius is multiplied by the same scale. A lower bound would
    // shrink only the spacing and cause overlap, so the drawn radius has no lower bound (clickability is
    // covered by a hit radius MIN_HIT_R separate from drawing).
    const MIN_HIT_R = 7;
    function radius(i: number) { return nodeRadius(nodes[i].deg) * scale; }
    // Apparent on-screen radius (larger when closer in perspective). Used for hit testing, node drawing, arrows, and label positions.
    function screenRadius(i: number) { return radius(i) * pf[i]; }

    type Palette = { bucket: string[]; line: string; lineHi: string; label: string; halo: string; ring: string; tier: string };
    function readPalette(): Palette {
      const cs = getComputedStyle(document.documentElement);
      const v = (name: string) => cs.getPropertyValue(name).trim();
      return {
        bucket: [v('--success'), v('--accent'), v('--warning'), v('--danger')],
        line: v('--border-strong'),
        lineHi: v('--accent'),
        label: v('--foreground'),
        halo: v('--surface'),
        ring: v('--accent'),
        tier: v('--border'),
      };
    }
    let pal = readPalette();

    let hover = -1;
    let raf = 0;
    let downX = 0, downY = 0, downIdx = -1, dragging = false, moved = false;
    const prefersReduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    function nodeAt(mx: number, my: number) {
      // prefer the front (end of order)
      for (let k = N - 1; k >= 0; k--) {
        const i = order[k];
        const dx = mx - sx[i], dy = my - sy[i];
        // Guarantee a minimum size for hit testing only, so nodes can be grabbed even with a small drawn radius.
        const rr = Math.max(MIN_HIT_R, screenRadius(i) + 5);
        if (dx * dx + dy * dy <= rr * rr) return i;
      }
      return -1;
    }

    // Opacity by depth (fainter toward the back). sd is normalized roughly to [-maxDepth, maxDepth].
    function depthAlpha(i: number) {
      const norm = sd[i] / (maxR + 1); // roughly -1.5..1.5
      return Math.max(0.35, Math.min(1, 0.72 + norm * 0.28));
    }

    function draw() {
      ctx.clearRect(0, 0, W, H);

      // Level rings (faint ellipses that suggest depth), top to bottom
      ctx.lineWidth = 1;
      ctx.strokeStyle = pal.tier;
      for (let L = 0; L <= maxLevel; L++) {
        for (const R of tierRings[L] ?? []) {
          const pts = tierPath(L, R);
          if (!pts) continue;
          ctx.globalAlpha = 0.5;
          ctx.beginPath();
          pts.forEach(([x, y], k) => (k === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)));
          ctx.stroke();
        }
      }
      ctx.globalAlpha = 1;

      // Merge edges and nodes into one depth list and draw back to front.
      // (Drawing all edges first would sink front edges beneath back nodes, which is false as a 3D display)
      const drawEdge = (e: { p: number; c: number; section: string | null }) => {
        const hot = hover >= 0 && (e.p === hover || e.c === hover);
        const a = depthAlpha(e.p) * depthAlpha(e.c);
        ctx.strokeStyle = hot ? pal.lineHi : pal.line;
        ctx.globalAlpha = hover >= 0 ? (hot ? 0.95 : 0.12) : 0.45 * a + 0.1;
        ctx.lineWidth = hot ? 1.8 : 1;
        const x1 = sx[e.p], y1 = sy[e.p], x2 = sx[e.c], y2 = sy[e.c];
        ctx.beginPath();
        ctx.moveTo(x1, y1);
        ctx.lineTo(x2, y2);
        ctx.stroke();
        // Arrow (on the child side, just before it, outside the node radius)
        const dx = x2 - x1, dy = y2 - y1;
        const len = Math.hypot(dx, dy) || 1;
        const ux = dx / len, uy = dy / len;
        const tipX = x2 - ux * (screenRadius(e.c) + 2);
        const tipY = y2 - uy * (screenRadius(e.c) + 2);
        const ah = hot ? 8 : 6;
        const perpX = -uy, perpY = ux;
        ctx.fillStyle = hot ? pal.lineHi : pal.line;
        ctx.beginPath();
        ctx.moveTo(tipX, tipY);
        ctx.lineTo(tipX - ux * ah + perpX * ah * 0.5, tipY - uy * ah + perpY * ah * 0.5);
        ctx.lineTo(tipX - ux * ah - perpX * ah * 0.5, tipY - uy * ah - perpY * ah * 0.5);
        ctx.closePath();
        ctx.fill();
      };
      const drawNode = (i: number) => {
        const isHover = i === hover;
        const isNeighbor = hover >= 0 && adj[hover].has(i);
        const dim = hover >= 0 && !isHover && !isNeighbor;
        const color = pal.bucket[nodes[i].bucket] || pal.bucket[3];
        ctx.globalAlpha = dim ? 0.28 : depthAlpha(i);
        ctx.beginPath();
        ctx.arc(sx[i], sy[i], screenRadius(i), 0, Math.PI * 2);
        if (nodes[i].derived) {
          // Derived nodes are hollow (fill is the background color, outline only). Distinguishes them at a glance from the filled real entities (DB rows).
          // Removing the fill lets you see on the ring that it is "a heading, not a DB row".
          ctx.fillStyle = pal.halo;
          ctx.fill();
          ctx.lineWidth = 1.5;
          ctx.strokeStyle = color;
          ctx.stroke();
        } else {
          ctx.fillStyle = color;
          ctx.fill();
        }
        if (isHover || isNeighbor) {
          ctx.globalAlpha = 1;
          ctx.lineWidth = 2;
          ctx.strokeStyle = pal.ring;
          ctx.stroke();
        }
      };
      // kind: 1 = node, 0 = edge. Edge depth is the midpoint of both ends.
      const items: { depth: number; kind: 0 | 1; ref: number }[] = [];
      for (let i = 0; i < N; i++) items.push({ depth: sd[i], kind: 1, ref: i });
      edges.forEach((e, ei) => items.push({ depth: (sd[e.p] + sd[e.c]) / 2, kind: 0, ref: ei }));
      items.sort((a, b) => a.depth - b.depth);
      for (const it of items) {
        if (it.kind === 1) drawNode(it.ref);
        else drawEdge(edges[it.ref]);
      }
      ctx.globalAlpha = 1;

      // Labels (only the hovered node and its neighbors)
      if (hover >= 0) {
        ctx.font = '600 12px -apple-system, "Hiragino Kaku Gothic ProN", "Noto Sans JP", sans-serif';
        ctx.textBaseline = 'middle';
        const show = [hover, ...adj[hover]];
        for (const i of show) {
          const label = nodes[i].title;
          const tx = sx[i] + screenRadius(i) + 5;
          const ty = sy[i];
          const w = ctx.measureText(label).width;
          ctx.globalAlpha = 0.85;
          ctx.fillStyle = pal.halo;
          ctx.fillRect(tx - 3, ty - 9, w + 6, 18);
          ctx.globalAlpha = i === hover ? 1 : 0.85;
          ctx.fillStyle = pal.label;
          ctx.fillText(label, tx, ty);
        }
        // Show the delegation clauses involving the hovered node at edge midpoints
        ctx.globalAlpha = 1;
        for (const e of edges) {
          if ((e.p === hover || e.c === hover) && e.section) {
            const mx = (sx[e.p] + sx[e.c]) / 2;
            const my = (sy[e.p] + sy[e.c]) / 2;
            const text = `# ${e.section}`;
            ctx.font = '500 11px -apple-system, "Hiragino Kaku Gothic ProN", "Noto Sans JP", sans-serif';
            const w = ctx.measureText(text).width;
            ctx.globalAlpha = 0.9;
            ctx.fillStyle = pal.halo;
            ctx.fillRect(mx - w / 2 - 3, my - 8, w + 6, 16);
            ctx.fillStyle = pal.lineHi;
            ctx.fillText(text, mx - w / 2, my);
          }
        }
        ctx.globalAlpha = 1;
      }
    }

    function computeScale() {
      // Choose scale so the max radius plus margin fits in the frame
      const margin = persp ? 150 : 90; // In perspective the front bulges, so use a thicker margin to prevent clipping
      const usable = Math.min(W, H) - margin;
      scale = Math.max(0.2, Math.min(1.4, usable / (maxR * 2 + LEVEL_GAP)));
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
      computeScale();
      inited = true;
      project();
      draw();
    }

    function scheduleDraw() {
      if (raf) return;
      raf = requestAnimationFrame(() => {
        raf = 0;
        project();
        draw();
      });
    }

    // ---- events ----
    function pointerPos(e: PointerEvent) {
      const rect = canvas.getBoundingClientRect();
      return { x: e.clientX - rect.left, y: e.clientY - rect.top };
    }
    function onDown(e: PointerEvent) {
      const { x, y } = pointerPos(e);
      downX = x; downY = y; moved = false;
      downIdx = nodeAt(x, y);
      dragging = true;
      canvas.setPointerCapture(e.pointerId);
    }
    function onMove(e: PointerEvent) {
      const { x, y } = pointerPos(e);
      if (dragging) {
        const dx = x - downX, dy = y - downY;
        if (Math.abs(dx) > 3 || Math.abs(dy) > 3) moved = true;
        if (moved) {
          theta += dx * 0.01;
          // Allowing the lower bound of the depression angle near 0 flattens level rings sideways into lines, so nodes on the same ring
          // overlap completely in projection. Stop at an angle where rings still look like ellipses.
          phi = Math.max(0.12, Math.min(1.25, phi + dy * 0.006));
          downX = x; downY = y;
          scheduleDraw();
        }
        return;
      }
      const h = nodeAt(x, y);
      if (h !== hover) {
        hover = h;
        canvas.style.cursor = h >= 0 ? 'pointer' : 'grab';
        scheduleDraw();
      }
    }
    function onUp(e: PointerEvent) {
      if (dragging && !moved && downIdx >= 0) {
        router.push(`/n/${nodes[downIdx].id}`);
      }
      dragging = false; downIdx = -1;
      try { canvas.releasePointerCapture(e.pointerId); } catch { /* ignore if not captured */ }
      canvas.style.cursor = hover >= 0 ? 'pointer' : 'grab';
    }
    function onLeave() {
      if (hover !== -1) { hover = -1; canvas.style.cursor = 'grab'; scheduleDraw(); }
    }
    function onTheme() { pal = readPalette(); draw(); }

    const ro = new ResizeObserver(resize);
    ro.observe(wrap);
    canvas.addEventListener('pointerdown', onDown);
    canvas.addEventListener('pointermove', onMove);
    canvas.addEventListener('pointerup', onUp);
    canvas.addEventListener('pointercancel', onUp);
    canvas.addEventListener('pointerleave', onLeave);
    window.addEventListener(THEME_EVENT, onTheme);

    canvas.style.cursor = 'grab';
    if (!inited) resize();
    // Even with reduced-motion, the initial render is a still image (rotation only on user interaction).
    void prefersReduced;

    return () => {
      if (raf) cancelAnimationFrame(raf);
      ro.disconnect();
      canvas.removeEventListener('pointerdown', onDown);
      canvas.removeEventListener('pointermove', onMove);
      canvas.removeEventListener('pointerup', onUp);
      canvas.removeEventListener('pointercancel', onUp);
      canvas.removeEventListener('pointerleave', onLeave);
      window.removeEventListener(THEME_EVENT, onTheme);
    };
  }, [nodes, links, router, projection]);

  return (
    <div className="relative h-[calc(100vh-160px)] min-h-[420px] w-full overflow-hidden rounded-[var(--radius-lg)] border border-[var(--border)] bg-[var(--surface)] shadow-[var(--shadow-sm)]">
      <canvas ref={canvasRef} className="block h-full w-full touch-none" />
      <div className="pointer-events-none absolute bottom-2 right-3 text-[11px] text-[var(--faint)]">
        ドラッグで回転・傾け／クリックで対象を開く
      </div>
    </div>
  );
}
