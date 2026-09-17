'use client';

import { Component, useEffect, useState, type ReactNode } from 'react';
import dynamic from 'next/dynamic';
import { GraphCanvas, type GraphNode, type GraphLink } from './GraphCanvas';
import { PyramidCanvas, type PyramidNode, type PyramidLink } from './PyramidCanvas';

// 図の切替と凡例。描画そのものは Kaname の実装を移植して使う（座標計算 = lib/pyramidLayout.ts）。
//
// WebGL の初期化失敗・context lost で描画が落ちても、遠近(persp)表示へ確実に退避するための境界。
// render 例外を捕まえたら onFail で親にも通知する（親の webglFailed を立て、再選択で remount 復帰できるように）。
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

// WebGL 実3D を提供するノード/エッジ数の上限（多量の mesh/Html/線は R3F reconciler が重くなる）。
const WEBGL_NODE_CAP = 1500;
const WEBGL_EDGE_CAP = 4000;

// WebGL(実3D) は three.js を含むため、選択時のみ遅延ロードする（既定バンドルを軽く保つ）。
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
  realLinkCount: number; // うち DB に実在する関係（FK・列の値）の本数
};

// ピラミッドの表示モード。flat=正射影(2.5D) / persp=透視(遠近3D) / webgl=three.js 実3D。
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
  pyramidDepth?: number; // 階層の段数
  derivedNodeCount?: number; // 分類から導出したノード（DB の行ではない）の数
}) {
  const [view, setView] = useState<'graph' | 'pyramid'>('pyramid');
  const [pyramidMode, setPyramidMode] = useState<PyramidMode>('flat');
  const [webglOK, setWebglOK] = useState(true);
  const [webglFailed, setWebglFailed] = useState(false); // 実行時のcontext lost/生成失敗で立てる
  const [webglKey, setWebglKey] = useState(0);
  // WebGL を一度でも表示したか。true の間は Canvas を破棄せず CSS で表示/非表示だけ切り替える
  // （毎回 context を作り直すとブラウザの同時 context 上限に達して 3D が消える）。
  const [webglEverOn, setWebglEverOn] = useState(false);

  // WebGL 対応チェック（非対応環境では webgl ボタンを出さず、選択済みなら persp に退避）。
  useEffect(() => {
    let ok = false;
    try {
      const c = document.createElement('canvas');
      ok = !!(c.getContext('webgl2') || c.getContext('webgl'));
    } catch {
      ok = false;
    }
    // eslint-disable-next-line react-hooks/set-state-in-effect -- 一度きりの能力判定。カスケード更新ではない。
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

        {/* ピラミッドの表示モード選択（正射影 / 遠近 / WebGL） */}
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

      {/* 凡例。色が何を意味するかを図の外に必ず出す（色だけで意味を運ばない）。 */}
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

      {/* アクティブなビュー。WebGL 表示中はここは描かず、下の永続 WebGL レイヤに任せる。 */}
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

      {/* 永続 WebGL レイヤ: 一度表示したら unmount せず、非アクティブ時は hidden で隠すだけにする。 */}
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
