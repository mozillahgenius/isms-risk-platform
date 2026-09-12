import Link from 'next/link';
import { Warning } from '@phosphor-icons/react/dist/ssr';
import {
  getAnnexAShape,
  getCounts,
  getCurrentDom,
  getProvenance,
  getTenantDataStatus,
  listFrameworks,
} from '@/lib/catalog';
import { ProvenanceTable } from '@/components/Provenance';

export const dynamic = 'force-dynamic';

export const metadata = { title: 'カタログ' };

// The contents and provenance of the rules (catalog). This used to be on the top page, but
// the top page became "how to run the ISMS", so it moved here. The contents are unchanged.

function Stat({
  label,
  value,
  href,
  empty,
}: {
  label: string;
  value: number;
  href?: string;
  empty?: boolean;
}) {
  const body = (
    <div className={`card card-hover p-4 ${empty ? 'border-[var(--danger)]' : ''}`}>
      <div className="text-[12px] text-[var(--muted)]">{label}</div>
      <div className={`mt-1 text-[26px] font-semibold tabular-nums ${empty ? 'text-[var(--danger)]' : ''}`}>
        {value}
      </div>
      {empty && <div className="mt-1 text-[11px] text-[var(--danger)]">未投入</div>}
    </div>
  );
  return href ? <Link href={href}>{body}</Link> : body;
}

export default async function CatalogHome() {
  const [dom, counts, prov, tenant, frameworks, annexA] = await Promise.all([
    getCurrentDom(),
    getCounts(),
    getProvenance(),
    getTenantDataStatus(),
    listFrameworks(),
    getAnnexAShape(),
  ]);

  return (
    <div className="flex flex-col gap-8">
      <section>
        <h1 className="text-[22px] font-semibold tracking-tight">
          {dom ? `カタログ（標準運用モデル DOM ${dom.version}）` : 'DOM が投入されていません'}
        </h1>
        {dom && (
          <p className="mt-1 max-w-[860px] text-[13px] text-[var(--muted)]">
            {dom.changelog}（発行{' '}
            {new Date(dom.released_at).toLocaleDateString('ja-JP', { timeZone: 'Asia/Tokyo' })}）
          </p>
        )}
        <p className="mt-2 max-w-[860px] text-[13px] text-[var(--fg-2)]">
          ここに並ぶのは<b>ルールの下敷き</b>。自社が ISMS を回した記録ではない。
          どの段階でどれを使うかは
          <Link className="mx-1 underline" href="/">
            ISMS の進め方
          </Link>
          から辿れる。
        </p>
      </section>

      <section>
        <h2 className="mb-3 text-[15px] font-semibold">入っているルール</h2>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
          <Stat label="統制" value={counts.controls} href="/catalog/controls" />
          <Stat
            label="リスクシナリオ雛形"
            value={counts.risk_scenario_templates}
            href="/catalog/risks"
          />
          <Stat label="規程" value={counts.policies} href="/catalog/policies" />
          <Stat label="標準ロール" value={counts.roles} href="/catalog/org" />
          <Stat label="資産分類" value={counts.asset_classes} href="/catalog/org" />
          <Stat label="年間カレンダー" value={counts.calendar_events} href="/catalog/calendar" />
          <Stat label="フレームワーク" value={counts.frameworks} href="/catalog/frameworks" />
          <Stat label="リスク基準" value={counts.risk_criteria} href="/catalog/criteria" />
          <Stat label="DOM 版" value={counts.dom_versions} />
        </div>
      </section>

      {/* Showing only the total number of controls reads as if Annex A is included. Also show which criteria the controls come from. */}
      <section>
        <h2 className="mb-1 text-[15px] font-semibold">統制はどの基準のものか</h2>
        <p className="mb-3 max-w-[860px] text-[12px] text-[var(--muted)]">
          統制の合計だけでは、どの基準のものか分からない。フレームワークごとに分けて出す。
        </p>
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[560px] border-collapse text-[13px]">
            <caption className="sr-only">フレームワークごとの統制の件数</caption>
            <thead>
              <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                <th scope="col" className="px-4 py-2 font-medium">
                  フレームワーク
                </th>
                <th scope="col" className="px-4 py-2 font-medium">
                  版
                </th>
                <th scope="col" className="px-4 py-2 text-right font-medium">
                  統制
                </th>
              </tr>
            </thead>
            <tbody>
              {frameworks.map((f) => (
                <tr key={f.key} className="border-b border-[var(--border)]">
                  <td className="px-4 py-2">
                    {f.name_ja}
                    <div className="font-[family-name:var(--font-geist-mono)] text-[11px] text-[var(--muted)]">
                      {f.key}
                    </div>
                  </td>
                  <td className="px-4 py-2 text-[12px] text-[var(--muted)]">{f.version}</td>
                  <td
                    className={`px-4 py-2 text-right tabular-nums ${
                      f.control_count === 0 ? 'text-[var(--danger)]' : ''
                    }`}
                  >
                    {f.control_count}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {annexA.total === 0 && (
          <p className="mt-2 flex items-start gap-1.5 text-[12px] text-[var(--fg-2)]">
            <Warning
              size={14}
              weight="bold"
              className="mt-[2px] shrink-0 text-[var(--warning)]"
              aria-hidden
            />
            <span>
              <b>ISO/IEC 27001:2022 の附属書 A はまだ 1 件も入っていない。</b>
              いま入っている統制は上場準備の統制チェックカルテで、ISO 27001 の統制ではない。
              適用宣言書をつくる段階は、これがそろうまで先へ進めない。
            </span>
          </p>
        )}
        {annexA.total > 0 && annexA.wellFormed !== annexA.total && (
          <p className="mt-2 text-[12px] text-[var(--danger)]">
            ISO/IEC 27001:2022 に紐付いた {annexA.total} 件のうち、
            附属書 A のコード形式（A.x.y）になっていないものが {annexA.total - annexA.wellFormed} 件ある。
          </p>
        )}
      </section>

      <section>
        <h2 className="mb-1 text-[15px] font-semibold">まだ入っていないもの</h2>
        <p className="mb-3 text-[12px] text-[var(--muted)]">
          件数を丸めない。0 のものは 0 と出す（表から消すと「そもそも無い」ように見えるため）。
        </p>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
          <Stat
            label="フレームワーク対応表"
            value={counts.framework_mappings}
            empty={counts.framework_mappings === 0}
          />
          <Stat
            label="リスク↔統制の紐付け"
            value={counts.risk_template_controls}
            empty={counts.risk_template_controls === 0}
          />
          <Stat
            label="標準チェック"
            value={counts.checks}
            href="/catalog/checks"
            empty={counts.checks === 0}
          />
          <Stat label="チェック↔統制" value={counts.check_controls} empty={counts.check_controls === 0} />
          <Stat
            label="コネクタ定義"
            value={counts.connector_manifests}
            href="/settings"
            empty={counts.connector_manifests === 0}
          />
        </div>
        <p className="mt-3 text-[12px] text-[var(--muted)]">
          運用データ（テナントのリスク台帳・実施状況）:{' '}
          {tenant.readable ? (
            <>テナント {tenant.tenants} 件</>
          ) : (
            <span className="text-[var(--warning)]">
              この画面からは読めない（テナント文脈が要る）。詳細は{' '}
              <Link className="underline" href="/operations">
                運用
              </Link>
            </span>
          )}
        </p>
      </section>

      <section>
        <h2 className="mb-1 text-[15px] font-semibold">ルールの正本はどこか</h2>
        <p className="mb-3 max-w-[860px] text-[12px] text-[var(--muted)]">
          正本は <b>Git</b>。DB はその投影で、この画面は投影を読むだけ。下の表は投入時に実測して
          記録した値（catalog.seed_provenance）で、画面に書いた固定文字列ではない。
        </p>
        <div className="card p-4">
          <ProvenanceTable rows={prov} />
        </div>
      </section>
    </div>
  );
}
