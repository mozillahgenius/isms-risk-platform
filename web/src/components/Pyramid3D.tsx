'use client';

// Real WebGL 3D view of the delegation pyramid (three.js / react-three-fiber).
// - Coordinates, levels and edges use the shared buildPyramidLayout, matching flat/persp (Canvas2D).
// - Node = sphere (color = bucket, size = number of connections); edges batched into a single LineSegments.
// - Rotate/zoom with OrbitControls. Accidental clicks after dragging are suppressed by movement distance. Hover highlights neighbors + clause labels.
// - three is lazy-loaded via next/dynamic only when WebGL is selected (in GraphViews).

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
const SECTION_LABEL_CAP = 16; // Cap to prevent an explosion of relation-label DOM nodes when hovering a hub node

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
  // Click detection: record pointerdown coordinates and navigate only when movement to pointerup is small
  // (so OrbitControls drag-rotation is not misdetected as a "click").
  const downPos = useRef<{ x: number; y: number } | null>(null);

  const sphere = useMemo(() => new THREE.SphereGeometry(1, 20, 20), []);
  // The radius uses the same definition as the layout's spacing calculation (keeping them separate causes overlap).
  const nodeRadius = (i: number) => nodeRadiusOf(nodes[i].deg);

  // Batch all edges into a single LineSegments (2 vertices per edge).
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

  // Draw only the delegation edges connected to the hovered node in a separate batch for highlighting (equivalent to the hot edge in the 2.5D version).
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

      {/* Hierarchy edges (parent -> child). Direction is expressed by Y height (parent is above). */}
      <lineSegments geometry={edgeGeom}>
        <lineBasicMaterial color={pal.edge} transparent opacity={hover >= 0 ? 0.16 : 0.4} />
      </lineSegments>
      {/* Highlight overlay for edges connected to the hover target */}
      {hotEdgeGeom && (
        <lineSegments geometry={hotEdgeGeom}>
          <lineBasicMaterial color={pal.hi} transparent opacity={0.9} />
        </lineSegments>
      )}

      {/* Node spheres */}
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
              // Do not navigate if the down->up movement exceeds the threshold (= drag rotation)
              if (d && Math.hypot(e.nativeEvent.clientX - d.x, e.nativeEvent.clientY - d.y) > 6) return;
              router.push(`/n/${n.id}`);
            }}
          >
            {/* Undelegated nodes are wireframe spheres so they are distinguishable at a glance from filled delegated nodes
                (same meaning as the hollow circles in the 2.5D/perspective views). */}
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

      {/* Title of the hovered node */}
      {hover >= 0 && hover < N && (
        <Html position={[bx[hover], by[hover] + nodeRadius(hover) + 6, bz[hover]]} center pointerEvents="none">
          <div className="pointer-events-none whitespace-nowrap rounded bg-[var(--surface)]/90 px-1.5 py-0.5 text-[11px] font-semibold text-[var(--foreground)]">
            {nodes[hover].title}
          </div>
        </Html>
      )}

      {/* Clause labels of delegations involving the hovered node (at edge midpoints) */}
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

      {/* damping is disabled because it does not play well with the demand frameloop (it keeps requesting frames after coming to rest). */}
      <OrbitControls makeDefault enablePan={false} enableDamping={false} />
    </>
  );
}

// Kicker that ensures the first frame is rendered on initial mount and when returning from hidden to visible.
// frameloop control alone can leave the canvas "blank until interacted with" when mounting before the initial size is settled or after a display toggle,
// so once active, explicitly gl.render for a few frames and also prompt a size re-measure via a resize notification.
function KickFirstFrame({ active }: { active: boolean }) {
  const gl = useThree((s) => s.gl);
  const scene = useThree((s) => s.scene);
  const camera = useThree((s) => s.camera);
  const invalidate = useThree((s) => s.invalidate);
  useEffect(() => {
    if (!active) return;
    let raf = 0;
    let n = 0;
    // Prompt the browser to re-measure size (prevents non-rendering caused by 0px when going from hidden to visible).
    window.dispatchEvent(new Event('resize'));
    const draw = () => {
      invalidate();
      gl.render(scene, camera);
      // Explicitly render only the first ~20 frames, then hand off to frameloop.
      if (n++ < 20) raf = requestAnimationFrame(draw);
    };
    draw();
    return () => cancelAnimationFrame(raf);
  }, [active, gl, scene, camera, invalidate]);
  return null;
}

// The Canvas itself. The caller adds key={maxR} to remount it entirely.
// By dropping aliveRef in this unmount cleanup, both "unmount due to mode/tab switch"
// and "remount due to maxR change" are handled by the same path. About 500ms after the Canvas is destroyed, R3F
// calls forceContextLoss() and fires webglcontextlost (normal cleanup), so if this is mistaken for a real
// GPU failure and we fall back via onError, the WebGL button disappears and never comes back. Loss from a dead Canvas
// is swallowed; only real GPU loss while alive is passed to onError.
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
    // In case Strict Mode re-runs effects, reset to true in setup (false in cleanup).
    aliveRef.current = true;
    return () => {
      aliveRef.current = false;
    };
  }, []);
  return (
    <Canvas
      // While active (visible), use 'always' to render every frame without fail. With 'demand', on initial mount or
      // when returning from hidden, no frame is requested, and it stays blank until interacted with = looks "gone".
      // While hidden, drop to 'demand' to reduce GPU/battery usage (it is hidden, so no rendering is needed).
      frameloop={active ? 'always' : 'demand'}
      camera={{ position: [0, maxR * 0.5, maxR * 2.8], fov: 45, near: 1, far: maxR * 12 }}
      style={{ width: '100%', height: '100%' }}
      gl={{ alpha: true, antialias: true }}
      onPointerMissed={() => undefined}
      onCreated={({ gl }) => {
        // WebGLErrorBoundary only catches render exceptions, so context lost is caught here and a fallback is signaled.
        gl.domElement.addEventListener(
          'webglcontextlost',
          (e) => {
            // Loss after unmount (from forceContextLoss) is normal cleanup, so do not fall back.
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
  onError?: () => void; // Called on WebGL context creation failure / context lost (the caller falls back to persp)
  active?: boolean; // Whether it is visible. While false (hidden), drop to demand to save power
}) {
  // Client-only via ssr:false, so getComputedStyle can be safely read in the initializer (no SSR).
  const [pal, setPal] = useState<Palette>(() => readPalette());
  useEffect(() => {
    // Only subscribes to theme changes (setState inside a subscription callback is an accepted pattern).
    const on = () => setPal(readPalette());
    window.addEventListener(THEME_EVENT, on);
    return () => window.removeEventListener(THEME_EVENT, on);
  }, []);

  // Compute the layout only once and share it between Scene and the camera (avoid double computation).
  const layout = useMemo(() => buildPyramidLayout(nodes, links), [nodes, links]);
  // When the data size changes, remount the Canvas with maxR as key to recreate the camera (position/far).
  return <PyramidCanvas3D key={layout.maxR} layout={layout} nodes={nodes} pal={pal} onError={onError} active={active} />;
}
