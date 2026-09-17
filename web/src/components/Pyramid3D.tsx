'use client';

// 委任ピラミッドの WebGL 実3D 表示（three.js / react-three-fiber）。
// - 座標・階層・エッジは共有の buildPyramidLayout を使い、flat/persp(Canvas2D) と一致させる。
// - ノード=球（色=区分 bucket、大きさ=接続本数）、エッジ=1本の LineSegments に batch。
// - OrbitControls で回転/ズーム。ドラッグ後の誤クリックは移動量で抑制。ホバーで隣接強調＋条項ラベル。
// - three は WebGL 選択時のみ next/dynamic で遅延ロードされる（GraphViews 側）。

import { useEffect, useMemo, useRef, useState } from 'react';
import { Canvas, useThree, type ThreeEvent } from '@react-three/fiber';
import { OrbitControls, Html } from '@react-three/drei';
import * as THREE from 'three';
import { useRouter } from 'next/navigation';
import {
  buildPyramidLayout,
  nodeRadius as nodeRadiusOf,
  type PyramidNode,
  type PyramidLink,
  type PyramidLayout,
} from '@/lib/pyramidLayout';

const THEME_EVENT = 'isms-theme-change';
const SECTION_LABEL_CAP = 16; // ハブノード hover 時の関係ラベル DOM 爆発を防ぐ上限

type Palette = { bucket: string[]; edge: string; hi: string };
function readPalette(): Palette {
  const cs = getComputedStyle(document.documentElement);
  const v = (n: string) => cs.getPropertyValue(n).trim() || '#888888';
  return {
    bucket: [v('--success'), v('--accent'), v('--warning'), v('--danger')],
    edge: v('--border-strong'),
    hi: v('--accent'),
  };
}

function Scene({ layout, nodes, pal }: { layout: PyramidLayout; nodes: PyramidNode[]; pal: Palette }) {
  const router = useRouter();
  const { bx, by, bz, edges, adj, N } = layout;

  const [hover, setHover] = useState(-1);
  // クリック判定: pointerdown 座標を記録し、up との移動量が小さい時だけナビゲート
  // （OrbitControls のドラッグ回転を「クリック」と誤検出しないため）。
  const downPos = useRef<{ x: number; y: number } | null>(null);

  const sphere = useMemo(() => new THREE.SphereGeometry(1, 20, 20), []);
  // 半径はレイアウトの間隔計算と同じ定義を使う（別々に持つと重なる）。
  const nodeRadius = (i: number) => nodeRadiusOf(nodes[i].deg);

  // 全エッジを1本の LineSegments に batch（各エッジ 2 頂点）。
  const edgeGeom = useMemo(() => {
    const pos = new Float32Array(edges.length * 6);
    edges.forEach((e, k) => {
      pos.set([bx[e.p], by[e.p], bz[e.p], bx[e.c], by[e.c], bz[e.c]], k * 6);
    });
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    return g;
  }, [edges, bx, by, bz]);
  useEffect(() => () => edgeGeom.dispose(), [edgeGeom]);
  useEffect(() => () => sphere.dispose(), [sphere]);

  // ホバー中のノードに接続する委任辺だけを強調用に別 batch で描く（2.5D 版の hot edge 相当）。
  const hotEdgeGeom = useMemo(() => {
    if (hover < 0) return null;
    const es = edges.filter((e) => e.p === hover || e.c === hover);
    if (!es.length) return null;
    const pos = new Float32Array(es.length * 6);
    es.forEach((e, k) => pos.set([bx[e.p], by[e.p], bz[e.p], bx[e.c], by[e.c], bz[e.c]], k * 6));
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    return g;
  }, [hover, edges, bx, by, bz]);
  useEffect(() => () => hotEdgeGeom?.dispose(), [hotEdgeGeom]);

  return (
    <>
      <ambientLight intensity={0.85} />
      <directionalLight position={[60, 180, 120]} intensity={0.55} />

      {/* 階層エッジ（親→子）。方向は Y 高さ（親が上）で表現。 */}
      <lineSegments geometry={edgeGeom}>
        <lineBasicMaterial color={pal.edge} transparent opacity={hover >= 0 ? 0.16 : 0.4} />
      </lineSegments>
      {/* ホバー対象に接続する辺の強調オーバーレイ */}
      {hotEdgeGeom && (
        <lineSegments geometry={hotEdgeGeom}>
          <lineBasicMaterial color={pal.hi} transparent opacity={0.9} />
        </lineSegments>
      )}

      {/* ノード球 */}
      {nodes.map((n, i) => {
        const isHover = i === hover;
        const isNeighbor = hover >= 0 && adj[i]?.has(hover);
        const dim = hover >= 0 && !isHover && !isNeighbor;
        return (
          <mesh
            key={n.id}
            geometry={sphere}
            position={[bx[i], by[i], bz[i]]}
            scale={nodeRadius(i)}
            onPointerOver={(e: ThreeEvent<PointerEvent>) => {
              e.stopPropagation();
              setHover(i);
            }}
            onPointerOut={() => setHover((h) => (h === i ? -1 : h))}
            onPointerDown={(e: ThreeEvent<PointerEvent>) => {
              downPos.current = { x: e.nativeEvent.clientX, y: e.nativeEvent.clientY };
            }}
            onClick={(e: ThreeEvent<MouseEvent>) => {
              e.stopPropagation();
              const d = downPos.current;
              // down→up の移動が閾値超（=ドラッグ回転）ならナビゲートしない
              if (d && Math.hypot(e.nativeEvent.clientX - d.x, e.nativeEvent.clientY - d.y) > 6) return;
              router.push(`/n/${n.id}`);
            }}
          >
            {/* 未委任は wireframe の球にして、塗りつぶしの委任済みノードと一目で区別する
                （2.5D/遠近ビューの白抜き円と同じ意味）。 */}
            <meshStandardMaterial
              color={pal.bucket[n.bucket] || pal.bucket[3]}
              emissive={isHover ? pal.hi : '#000000'}
              emissiveIntensity={isHover ? 0.6 : 0}
              wireframe={n.derived === true}
              transparent
              opacity={dim ? 0.28 : 1}
            />
          </mesh>
        );
      })}

      {/* ホバーノードのタイトル */}
      {hover >= 0 && hover < N && (
        <Html position={[bx[hover], by[hover] + nodeRadius(hover) + 6, bz[hover]]} center pointerEvents="none">
          <div className="pointer-events-none whitespace-nowrap rounded bg-[var(--surface)]/90 px-1.5 py-0.5 text-[11px] font-semibold text-[var(--foreground)]">
            {nodes[hover].title}
          </div>
        </Html>
      )}

      {/* ホバーノードに関わる委任の条項ラベル（エッジ中点） */}
      {hover >= 0 &&
        edges
          .filter((e) => (e.p === hover || e.c === hover) && e.section)
          .slice(0, SECTION_LABEL_CAP)
          .map((e, k) => (
            <Html
              key={`sec-${k}`}
              position={[(bx[e.p] + bx[e.c]) / 2, (by[e.p] + by[e.c]) / 2, (bz[e.p] + bz[e.c]) / 2]}
              center
              pointerEvents="none"
            >
              <div className="pointer-events-none whitespace-nowrap rounded bg-[var(--surface)]/90 px-1 py-0.5 text-[10px] text-[var(--accent)]">
                # {e.section}
              </div>
            </Html>
          ))}

      {/* damping は demand frameloop と相性が悪い（静止後もフレームを要求する）ため無効化。 */}
      <OrbitControls makeDefault enablePan={false} enableDamping={false} />
    </>
  );
}

// 初回マウント時・非表示(hidden)からの表示復帰時に、最初のフレームを確実に描画させるためのキッカー。
// frameloop 制御だけでは、初期サイズ確定前のマウントや display 切替後に「操作するまで真っ白」になる
// ことがあるため、active になったら数フレーム明示的に gl.render し、resize 通知でサイズ再計測も促す。
function KickFirstFrame({ active }: { active: boolean }) {
  const gl = useThree((s) => s.gl);
  const scene = useThree((s) => s.scene);
  const camera = useThree((s) => s.camera);
  const invalidate = useThree((s) => s.invalidate);
  useEffect(() => {
    if (!active) return;
    let raf = 0;
    let n = 0;
    // ブラウザにサイズ再計測を促す（hidden→表示で 0px 起因の未描画を防ぐ）。
    window.dispatchEvent(new Event('resize'));
    const draw = () => {
      invalidate();
      gl.render(scene, camera);
      // 最初の ~20 フレームだけ明示描画してから frameloop に委ねる。
      if (n++ < 20) raf = requestAnimationFrame(draw);
    };
    draw();
    return () => cancelAnimationFrame(raf);
  }, [active, gl, scene, camera, invalidate]);
  return null;
}

// Canvas 本体。呼び出し側で key={maxR} を付けて丸ごと remount させる。
// この unmount cleanup で aliveRef を落とすことで、「モード/タブ切替による unmount」も
// 「maxR 変化による remount」も同一経路で扱える。R3F は Canvas 破棄の約500ms後に
// forceContextLoss() を呼び webglcontextlost を発火させる（正常な後始末）ため、これを本物の
// GPU 障害と誤認して onError 退避すると WebGL ボタンが消えたまま戻らない。死んだ Canvas の
// loss は握り潰し、生存中の本物の GPU ロストだけ onError に通す。
function PyramidCanvas3D({
  layout,
  nodes,
  pal,
  onError,
  active = true,
}: {
  layout: PyramidLayout;
  nodes: PyramidNode[];
  pal: Palette;
  onError?: () => void;
  active?: boolean;
}) {
  const maxR = layout.maxR;
  const aliveRef = useRef(true);
  useEffect(() => {
    // Strict Mode の effect 再実行に備え、setup で true に戻す（cleanup で false）。
    aliveRef.current = true;
    return () => {
      aliveRef.current = false;
    };
  }, []);
  return (
    <Canvas
      // active(表示中)は 'always' で必ず毎フレーム描画する。'demand' だと初回マウントや
      // 非表示(hidden)からの復帰でフレームが要求されず、操作するまで真っ白＝「消えた」に見える。
      // 非表示中は 'demand' に落として GPU/バッテリー消費を抑える（隠れているので描画不要）。
      frameloop={active ? 'always' : 'demand'}
      camera={{ position: [0, maxR * 0.5, maxR * 2.8], fov: 45, near: 1, far: maxR * 12 }}
      style={{ width: '100%', height: '100%' }}
      gl={{ alpha: true, antialias: true }}
      onPointerMissed={() => undefined}
      onCreated={({ gl }) => {
        // WebGLErrorBoundary は render 例外しか拾えないため、context lost はここで拾って退避通知する。
        gl.domElement.addEventListener(
          'webglcontextlost',
          (e) => {
            // アンマウント後（forceContextLoss 由来）の loss は正常な後始末なので退避しない。
            if (!aliveRef.current) return;
            e.preventDefault();
            onError?.();
          },
          { once: true },
        );
      }}
    >
      <Scene layout={layout} nodes={nodes} pal={pal} />
      <KickFirstFrame active={active} />
    </Canvas>
  );
}

export default function Pyramid3D({
  nodes,
  links,
  onError,
  active = true,
}: {
  nodes: PyramidNode[];
  links: PyramidLink[];
  onError?: () => void; // WebGL context 生成失敗 / context lost 時に呼ぶ（呼び出し側で persp 退避）
  active?: boolean; // 表示中か。false(hidden)の間は demand に落として省電力にする
}) {
  // ssr:false で client 専用のため、初期化子で getComputedStyle を安全に読める（SSRなし）。
  const [pal, setPal] = useState<Palette>(() => readPalette());
  useEffect(() => {
    // テーマ変更の購読のみ（購読コールバック内の setState は許容パターン）。
    const on = () => setPal(readPalette());
    window.addEventListener(THEME_EVENT, on);
    return () => window.removeEventListener(THEME_EVENT, on);
  }, []);

  // レイアウトは1回だけ計算し Scene とカメラで共有（二重計算を避ける）。
  const layout = useMemo(() => buildPyramidLayout(nodes, links), [nodes, links]);
  // データ規模が変わったらカメラ(position/far)を作り直すため maxR を key に Canvas を remount。
  return <PyramidCanvas3D key={layout.maxR} layout={layout} nodes={nodes} pal={pal} onError={onError} active={active} />;
}
