'use client';

import { Component, useEffect, useState, type ReactNode } from 'react';
import dynamic from 'next/dynamic';
import { GraphCanvas, type GraphNode, type GraphLink } from './GraphCanvas';
import { PyramidCanvas, type PyramidNode, type PyramidLink } from './PyramidCanvas';

// View switching and legend. The drawing itself reuses a ported existing graph rendering implementation (coordinate calculation = lib/pyramidLayout.ts).
//
// Boundary that reliably falls back to the perspective (persp) view even if rendering fails due to WebGL init failure or context lost.
// When a render exception is caught, also notify the parent via onFail (set the parent's webglFailed so reselecting can recover via remount).
class WebGLErrorBoundary extends Component<
  { fallback: ReactNode; children: ReactNode; onFail?: () => void },
  { failed: boolean }
> {
  state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  componentDidCatch() {
    this.props.onFail?.();
  }
  render() {
    return this.state.failed ? this.props.fallback : this.props.children;
  }
}

// Upper limit of nodes/edges for which WebGL real 3D is offered (lots of mesh/Html/lines make the R3F reconciler heavy).
const WEBGL_NODE_CAP = 1500;
const WEBGL_EDGE_CAP = 4000;

// WebGL (real 3D) includes three.js, so it is lazy-loaded only when selected (keeps the default bundle light).
const Pyramid3D = dynamic(() => import('./Pyramid3D'), {
  ssr: false,
  loading: () => (
    <div className="flex h-full w-full items-center justify-center text-[13px] text-[var(--muted)]">
      3Dビューを読み込み中…
    </div>
  ),
});

export type GraphMeta = {
  shown: number;
  linkCount: number;
  realLinkCount: number; // Of these, the number of relations that actually exist in the DB (FKs, column values)
};

// Pyramid display mode. flat = orthographic (2.5D) / persp = perspective (3D with depth) / webgl = three.js real 3D.
type PyramidMode = 'flat' | 'persp' | 'webgl';

const PYRAMID_BOX =
  'relative h-[calc(100vh-260px)] min-h-[420px] w-full overflow-hidden rounded-[var(--radius-lg)] border border-[var(--border)] bg-[var(--surface)] shadow-[var(--shadow-sm)]';

const BUCKET_LEGEND: { color: string; label: string }[] = [
  { color: 'var(--success)', label: '骨格（DOM・フレームワーク・区分）' },
  { color: 'var(--accent)', label: '統制' },
  { color: 'var(--warning)', label: 'リスクシナリオ' },
  { color: 'var(--danger)', label: '未投入（中身が 0 件）' },
];

export function GraphViews({
  graphNodes,
  graphLinks,
  graphMeta,
  pyramidNodes,
  pyramidLinks,
  pyramidDepth = 0,
  derivedNodeCount = 0,
}: {
  graphNodes: GraphNode[];
  graphLinks: GraphLink[];
  graphMeta: GraphMeta;
  pyramidNodes: PyramidNode[];
  pyramidLinks: PyramidLink[];
  pyramidDepth?: number; // Number of hierarchy levels
  derivedNodeCount?: number; // Number of nodes derived from classifications (not DB rows)
}) {
  const [view, setView] = useState<'graph' | 'pyramid'>('pyramid');
  const [pyramidMode, setPyramidMode] = useState<PyramidMode>('flat');
  const [webglOK, setWebglOK] = useState(true);
  const [webglFailed, setWebglFailed] = useState(false); // Set on runtime context lost / creation failure
  const [webglKey, setWebglKey] = useState(0);
  // Whether WebGL has been shown at least once. While true, the Canvas is not destroyed; only its visibility is toggled via CSS
  // (recreating the context every time hits the browser's limit on simultaneous contexts and the 3D disappears).
  const [webglEverOn, setWebglEverOn] = useState(false);

  // WebGL support check (in unsupported environments, do not show the webgl button, and fall back to persp if it was selected).
  useEffect(() => {
    let ok = false;
    try {
      const c = document.createElement('canvas');
      ok = !!(c.getContext('webgl2') || c.getContext('webgl'));
    } catch {
      ok = false;
    }
    // eslint-disable-next-line react-hooks/set-state-in-effect -- One-time capability check. Not a cascading update.
    setWebglOK(ok);
  }, []);

  const webglOffered = webglOK && pyramidNodes.length <= WEBGL_NODE_CAP && pyramidLinks.length <= WEBGL_EDGE_CAP;
  const effectiveMode: PyramidMode =
    pyramidMode === 'webgl' && (!webglOffered || webglFailed) ? 'persp' : pyramidMode;

  const selectMode = (key: PyramidMode) => {
    if (key === 'webgl') {
      setWebglEverOn(true);
      if (webglFailed) {
        setWebglFailed(false);
        setWebglKey((k) => k + 1);
      }
    }
    setPyramidMode(key);
  };

  const webglActive = view === 'pyramid' && effectiveMode === 'webgl';

  const tab = (active: boolean) =>
    `rounded-[calc(var(--radius)-3px)] px-3 py-1 transition-colors ${
      active
        ? 'bg-[var(--accent)] font-semibold text-[var(--accent-fg)]'
        : 'text-[var(--fg-2)] hover:bg-[var(--surface-2)]'
    }`;
  const seg = (active: boolean) =>
    `rounded-[calc(var(--radius)-3px)] px-2.5 py-1 transition-colors ${
      active
        ? 'bg-[var(--surface-2)] font-semibold text-[var(--foreground)]'
        : 'text-[var(--muted)] hover:text-[var(--fg-2)]'
    }`;

  const modes: { key: PyramidMode; label: string }[] = [
    { key: 'flat', label: '2.5D（正射影）' },
    { key: 'persp', label: '3D（遠近）' },
    ...(webglOffered ? [{ key: 'webgl' as PyramidMode, label: 'WebGL（実3D）' }] : []),
  ];

  const derivedLinkCount = graphMeta.linkCount - graphMeta.realLinkCount;

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
        <div className="inline-flex rounded-[var(--radius)] border border-[var(--border)] p-0.5 text-[13px]">
          <button type="button" onClick={() => setView('pyramid')} className={tab(view === 'pyramid')}>
            階層ピラミッド
          </button>
          <button type="button" onClick={() => setView('graph')} className={tab(view === 'graph')}>
            関連グラフ
          </button>
        </div>

        {/* Pyramid display mode selector (orthographic / perspective / WebGL) */}
        {view === 'pyramid' && pyramidNodes.length > 0 && (
          <div className="inline-flex rounded-[var(--radius)] border border-[var(--border)] p-0.5 text-[12px]">
            {modes.map((m) => (
              <button key={m.key} type="button" onClick={() => selectMode(m.key)} className={seg(effectiveMode === m.key)}>
                {m.label}
              </button>
            ))}
          </div>
        )}

        <span className="text-[12px] text-[var(--muted)]">
          {view === 'graph' ? (
            <>
              項目 <b className="font-semibold text-[var(--fg-2)]">{graphMeta.shown}</b> · 関係{' '}
              <b className="font-semibold text-[var(--fg-2)]">{graphMeta.linkCount}</b>
              （実在 {graphMeta.realLinkCount} / 導出 {derivedLinkCount}）
            </>
          ) : pyramidNodes.length ? (
            <>
              階層 <b className="font-semibold text-[var(--fg-2)]">{pyramidDepth}</b>段 · 辺{' '}
              <b className="font-semibold text-[var(--fg-2)]">{pyramidLinks.length}</b>本 · 白抜き（導出）{' '}
              <b className="font-semibold text-[var(--fg-2)]">{derivedNodeCount}</b>件
            </>
          ) : (
            <>表示できる項目がありません</>
          )}
        </span>
      </div>

      {/* Legend. Always show outside the diagram what the colors mean (do not convey meaning by color alone). */}
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] text-[var(--muted)]">
        {BUCKET_LEGEND.map((b) => (
          <span key={b.label} className="inline-flex items-center gap-1.5">
            <span className="inline-block h-2.5 w-2.5 rounded-full" style={{ background: b.color }} />
            {b.label}
          </span>
        ))}
        <span className="inline-flex items-center gap-1.5">
          <span
            className="inline-block h-2.5 w-2.5 rounded-full border-[1.5px]"
            style={{ borderColor: 'var(--muted)', background: 'var(--surface)' }}
          />
          白抜き＝分類から導出したまとまり（DB の行ではない）
        </span>
        <span>hover で関係の種別ラベルを表示</span>
      </div>

      {/* The active view. Not drawn here while WebGL is shown; left to the persistent WebGL layer below. */}
      {view === 'graph' ? (
        <GraphCanvas nodes={graphNodes} links={graphLinks} />
      ) : pyramidNodes.length ? (
        effectiveMode === 'webgl' ? null : (
          <PyramidCanvas nodes={pyramidNodes} links={pyramidLinks} projection={effectiveMode === 'persp' ? 'persp' : 'ortho'} />
        )
      ) : (
        <div className="card flex h-[420px] flex-col items-center justify-center gap-2 text-center">
          <div className="text-3xl opacity-60">🔺</div>
          <p className="max-w-[420px] text-sm text-[var(--muted)]">
            表示できる項目がありません。DOM の投入（make seed）が済んでいるか確認してください。
          </p>
        </div>
      )}

      {/* Persistent WebGL layer: once shown, never unmount it; when inactive, just hide it with hidden. */}
      {webglEverOn && pyramidNodes.length > 0 && (
        <div className={webglActive ? PYRAMID_BOX : 'hidden'} aria-hidden={!webglActive}>
          <WebGLErrorBoundary
            key={webglKey}
            onFail={() => setWebglFailed(true)}
            fallback={<PyramidCanvas nodes={pyramidNodes} links={pyramidLinks} projection="persp" />}
          >
            <Pyramid3D nodes={pyramidNodes} links={pyramidLinks} active={webglActive} onError={() => setWebglFailed(true)} />
            <div className="pointer-events-none absolute bottom-2 right-3 text-[11px] text-[var(--faint)]">
              ドラッグで回転／スクロールでズーム／クリックで対象を開く
            </div>
          </WebGLErrorBoundary>
        </div>
      )}
    </div>
  );
}
