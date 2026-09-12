import Link from 'next/link';
import { GraphViews } from '@/components/GraphViews';
import { buildGraphModel, type CatalogSnapshot } from '@/lib/graphModel';
import {
  getCounts,
  getCurrentDom,
  listAssetClasses,
  listCalendar,
  listControls,
  listFrameworks,
  listPolicies,
  listRisks,
  listRoles,
} from '@/lib/catalog';

export const dynamic = 'force-dynamic';

export const metadata = { title: '図で見る' };

export default async function GraphPage() {
  const [dom, counts, frameworks, controls, risks, policies, roles, assets, calendar] = await Promise.all([
    getCurrentDom(),
    getCounts(),
    listFrameworks(),
    listControls(),
    listRisks(),
    listPolicies(),
    listRoles(),
    listAssetClasses(),
    listCalendar(),
  ]);

  const snapshot: CatalogSnapshot = {
    dom: dom ? { version: dom.version } : null,
    frameworks: frameworks.map((f) => ({ key: f.key, name_ja: f.name_ja, control_count: f.control_count })),
    controls: controls.map((c) => ({
      id: c.id,
      code: c.code,
      title_ja: c.title_ja,
      theme: c.theme,
      framework_key: c.framework_key,
    })),
    risks: risks.map((r) => ({
      id: r.id,
      domain: r.domain,
      theme: r.theme,
      measure: r.measure,
      frame: r.frame,
      summary: r.summary,
    })),
    policies: policies.map((p) => ({ key: p.key, title_ja: p.title_ja })),
    roles: roles.map((r) => ({ key: r.key, name_ja: r.name_ja })),
    assets: assets.map((a) => ({ key: a.key, name_ja: a.name_ja })),
    calendar: calendar.map((e) => ({
      key: e.key,
      name_ja: e.name_ja,
      cadence: e.cadence,
      owner_role: e.owner_role,
    })),
    empties: {
      framework_mappings: counts.framework_mappings,
      risk_template_controls: counts.risk_template_controls,
      checks: counts.checks,
      connector_manifests: counts.connector_manifests,
    },
  };

  const model = buildGraphModel(snapshot);

  return (
    <div className="flex flex-col gap-4">
      <div>
        <h1 className="text-[20px] font-semibold tracking-tight">図で見る</h1>
        <p className="mt-1 max-w-[900px] text-[13px] text-[var(--muted)]">
          DOM を頂点に、区分 → フレームワーク／部門 → 分類 → 個々の統制・リスクまでを 1 枚に並べる。
          ノードをクリックすると、その項目のページへ移る。
          <b>実線の意味は 2 種類あり、hover でどちらか分かる</b>
          （「実関係」＝ DB の列にそのまま在る／「導出」＝ theme や domain の文字列を割って作った）。
        </p>
      </div>

      <GraphViews
        graphNodes={model.graphNodes}
        graphLinks={model.graphLinks}
        graphMeta={{
          shown: model.graphNodes.length,
          linkCount: model.linkCount,
          realLinkCount: model.realLinkCount,
        }}
        pyramidNodes={model.pyramidNodes}
        pyramidLinks={model.pyramidLinks}
        pyramidDepth={model.pyramidDepth}
        derivedNodeCount={model.derivedNodeCount}
      />

      {/* A Canvas cannot be navigated by keyboard or screen reader. Always provide a text path to the same content as well. */}
      <section className="card p-4">
        <h2 className="text-[14px] font-semibold">図を使わずに辿る</h2>
        <p className="mt-1 text-[12px] text-[var(--muted)]">
          図は Canvas で描いており、キーボード操作・読み上げでは辿れない。同じ中身は一覧からも行ける。
        </p>
        <ul className="mt-3 grid gap-2 text-[13px] sm:grid-cols-2 lg:grid-cols-3">
          <li>
            <Link className="underline" href="/catalog/controls">
              統制カタログ（{counts.controls} 件）
            </Link>
          </li>
          <li>
            <Link className="underline" href="/catalog/risks">
              リスクシナリオ雛形（{counts.risk_scenario_templates} 件）
            </Link>
          </li>
          <li>
            <Link className="underline" href="/catalog/policies">
              規程（{counts.policies} 件）
            </Link>
          </li>
          <li>
            <Link className="underline" href="/catalog/org">
              体制・資産分類（{counts.roles} / {counts.asset_classes} 件）
            </Link>
          </li>
          <li>
            <Link className="underline" href="/catalog/calendar">
              年間カレンダー（{counts.calendar_events} 件）
            </Link>
          </li>
          <li>
            <Link className="underline" href="/catalog/frameworks">
              フレームワーク（{counts.frameworks} 件）
            </Link>
          </li>
        </ul>
      </section>
    </div>
  );
}
