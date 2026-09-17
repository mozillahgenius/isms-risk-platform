'use client';

import { useEffect, useRef } from 'react';
import { useRouter } from 'next/navigation';
import { buildPyramidLayout, nodeRadius, type PyramidNode, type PyramidLink } from '@/lib/pyramidLayout';

// 分類階層のピラミッド（3D）。
// - 高さ（縦位置） = 分類の階層（level 0 = 頂点の上位ルール、深いほど下）
// - 各階層は XZ 平面の円周上に配置し、深いほど広がる = ピラミッド/円錐状
// - 有向の矢印 = 上位から下位への向き（上位ルール parent → 下位ルール child）
// - ドラッグで方位角(左右)・仰角(上下)を回して立体的に見る（依存ライブラリなしの正射影）
// - 色 = 区分（bucket）、大きさ = 接続本数、奥ほど淡く（painter's algorithm）
// テーマ切替イベントで色を再取得して再描画する。

export type { PyramidNode, PyramidLink };

const THEME_EVENT = 'isms-theme-change';

// projection: 'ortho'=正射影(2.5D) / 'persp'=透視投影(遠近3D)。座標・回転は共通で、投影のみ切替。
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

    // レイアウト計算は共有の純関数へ（flat/persp/webgl で座標を一致させる単一の真実源）。
    const { N, edges, adj, maxLevel, levelMid, bx, by, bz, maxR, tierRings, LEVEL_GAP } = buildPyramidLayout(nodes, links);

    // ---- カメラ（方位角 theta・仰角 phi）と投影 ----
    let theta = 0.7;           // 左右回転
    let phi = 0.42;            // 見下ろし角（0=真横, 大きいほど上から）
    let W = 0, H = 0, dpr = 1, scale = 1, inited = false;

    const sx = new Float64Array(N);
    const sy = new Float64Array(N);
    const sd = new Float64Array(N); // 深度（大きいほど手前）
    const order = new Int32Array(N);
    const pf = new Float64Array(N).fill(1); // 透視スケール係数（persp時のみ手前>1/奥<1、ortho時は1）

    // 透視投影の焦点距離（シーンサイズ基準）。分母・係数を必ずクランプして z2→FOCAL 付近の破綻を防ぐ。
    const persp = projection === 'persp';
    const FOCAL = (maxR + LEVEL_GAP) * 3;
    const perspK = (z2: number) =>
      persp ? Math.max(0.5, Math.min(1.9, FOCAL / Math.max(FOCAL * 0.35, FOCAL - z2))) : 1;

    function project() {
      const ct = Math.cos(theta), st = Math.sin(theta);
      const cp = Math.cos(phi), sp = Math.sin(phi);
      const cx = W / 2, cy = H / 2;
      for (let i = 0; i < N; i++) {
        // Y 軸まわりに theta 回転
        const x1 = bx[i] * ct + bz[i] * st;
        const z1 = -bx[i] * st + bz[i] * ct;
        // X 軸まわりに phi 傾ける（見下ろし）
        const y2 = by[i] * cp - z1 * sp;
        const z2 = by[i] * sp + z1 * cp; // 手前ほど大きい
        const k = perspK(z2);
        sx[i] = cx + x1 * scale * k;
        sy[i] = cy - y2 * scale * k;
        sd[i] = z2;
        pf[i] = k;
        order[i] = i;
      }
      // 奥→手前に描く（画家のアルゴリズム）
      order.sort((a, b) => sd[a] - sd[b]);
    }

    // 階層リング（XZ 平面の円）を投影して描くための点列。
    // 溢れた階層は同心リングを複数持つため、半径は呼び出し側から渡す。
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

    // 半径はレイアウトの間隔計算と同じ定義を使う（別々に持つと重なる）。
    // 座標は scale 倍して画面へ写すので、半径も同じ scale を掛ける。下限を置くと
    // 間隔だけ縮んで重なるため、描画半径には下限を置かない（クリックしやすさは
    // 描画とは別のヒット半径 MIN_HIT_R で補う）。
    const MIN_HIT_R = 7;
    function radius(i: number) { return nodeRadius(nodes[i].deg) * scale; }
    // 画面上の見かけ半径（透視時は手前ほど大きく）。ヒット判定・ノード描画・矢印・ラベル位置に使う。
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
      // 手前（order 末尾）を優先
      for (let k = N - 1; k >= 0; k--) {
        const i = order[k];
        const dx = mx - sx[i], dy = my - sy[i];
        // 描画半径が小さくてもつかめるよう、ヒット判定だけ最小サイズを保証する。
        const rr = Math.max(MIN_HIT_R, screenRadius(i) + 5);
        if (dx * dx + dy * dy <= rr * rr) return i;
      }
      return -1;
    }

    // 深度に応じた不透明度（奥ほど淡い）。sd を [-maxDepth, maxDepth] 概算で正規化。
    function depthAlpha(i: number) {
      const norm = sd[i] / (maxR + 1); // おおよそ -1.5..1.5
      return Math.max(0.35, Math.min(1, 0.72 + norm * 0.28));
    }

    function draw() {
      ctx.clearRect(0, 0, W, H);

      // 階層リング（奥行きを感じさせる薄い楕円）を上から下へ
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

      // エッジとノードを1つの深度リストにまとめ、奥→手前で描く。
      // （エッジをまとめて先に描くと前面エッジが背面ノードの下に沈み、3D 表示として嘘になるため）
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
        // 矢印（child 側の手前・ノード半径の外）
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
          // 導出ノードは白抜き（塗りは背景色・輪郭のみ）。実体（DB の行）の塗りつぶしと一目で区別する。
          // 塗りを消すとリングの上で「DB の行ではない見出し」だと見て取れる。
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
      // kind: 1=ノード, 0=エッジ。エッジ深度は両端の中点。
      const items: { depth: number; kind: 0 | 1; ref: number }[] = [];
      for (let i = 0; i < N; i++) items.push({ depth: sd[i], kind: 1, ref: i });
      edges.forEach((e, ei) => items.push({ depth: (sd[e.p] + sd[e.c]) / 2, kind: 0, ref: ei }));
      items.sort((a, b) => a.depth - b.depth);
      for (const it of items) {
        if (it.kind === 1) drawNode(it.ref);
        else drawEdge(edges[it.ref]);
      }
      ctx.globalAlpha = 1;

      // ラベル（hover とその隣接のみ）
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
        // hover ノードに関わる委任の条項をエッジ中点に表示
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
      // 最大半径＋余白が枠に収まるよう scale を決める
      const margin = persp ? 150 : 90; // 透視時は手前が膨らむため余白を厚めに取りクリッピングを防ぐ
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
          // 俯角の下限を 0 付近まで許すと、階層リングが真横＝線に潰れて同一リングの
          // ノードが投影上で完全に重なる。リングが楕円として見える角度までに留める。
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
      try { canvas.releasePointerCapture(e.pointerId); } catch { /* capture 済みでない場合は無視 */ }
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
    // reduced-motion でも初期は静止画で描かれる（回転はユーザー操作時のみ）。
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
