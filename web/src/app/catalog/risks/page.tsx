import Link from 'next/link';
import { listRisks, listRiskDomains, getProvenance, listFrameworks } from '@/lib/catalog';
import { ProvenanceTable } from '@/components/Provenance';
import { encodeNodeId } from '@/lib/nodeid';
import { frameworkForMode } from '@/lib/navigation';
import { firstParam, pageParam, type RawParam } from '@/lib/searchParams';

export const dynamic = 'force-dynamic';

export const metadata = { title: 'リスクシナリオ雛形' };

const PAGE_SIZE = 100;
const FRAMES = ['管理可能性', '精度', 'スピード'];

type SearchParams = Promise<Record<string, RawParam>>;

export default async function RisksPage({ searchParams }: { searchParams: SearchParams }) {
  const sp = await searchParams;
  const q = firstParam(sp.q);
  const domain = firstParam(sp.domain);
  const frame = firstParam(sp.frame);
  const requestedMode = firstParam(sp.mode);
  const mode = requestedMode === 'isms' || requestedMode === 'risk' ? requestedMode : undefined;
  const framework = firstParam(frameworkForMode(firstParam(sp.framework), mode));
  const page = pageParam(sp.page);

  // Filter options are fetched with DISTINCT. Fetching the whole list again to count them would
  // read every row not used for display twice on every request.
  const [rows, domains, prov, frameworks] = await Promise.all([
    listRisks({ q, domain, frame, framework }),
    listRiskDomains(framework),
    getProvenance(),
    listFrameworks(),
  ]);

  const total = rows.length;
  const pages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const current = Math.min(page, pages);
  const slice = rows.slice((current - 1) * PAGE_SIZE, current * PAGE_SIZE);

  const qs = (over: Record<string, string>) => {
    const p = new URLSearchParams();
    const merged = { q, domain, frame, framework, mode, page: String(current), ...over };
    for (const [k, v] of Object.entries(merged)) if (v) p.set(k, v);
    return `?${p.toString()}`;
  };

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-[20px] font-semibold tracking-tight">リスクシナリオ雛形</h1>
        <p className="mt-1 text-[13px] text-[var(--muted)]">
          該当 <b className="text-[var(--fg-2)]">{total}</b> 件。テナントのリスク台帳ではなく、
          台帳を作るときの<b>雛形</b>。
        </p>
      </div>

      <form className="card flex flex-wrap items-end gap-3 p-4" method="get">
        {mode && <input type="hidden" name="mode" value={mode} />}
        <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">
          検索（要約・テーマ・施策・領域）
          <input className="input min-w-[260px]" type="search" name="q" defaultValue={q} placeholder="例: 資金ショート" />
        </label>
        <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">
          枠組みタグ
          <select className="input min-w-[220px]" name="framework" defaultValue={framework}>
            <option value="">すべて</option>
            {frameworks.map((item) => <option key={item.key} value={item.key}>{item.name_ja}</option>)}
          </select>
        </label>
        <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">
          領域
          <select className="input min-w-[220px]" name="domain" defaultValue={domain}>
            <option value="">すべて</option>
            {domains.map((d) => (
              <option key={d} value={d}>
                {d}
              </option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">
          観点
          <select className="input min-w-[160px]" name="frame" defaultValue={frame}>
            <option value="">すべて</option>
            {FRAMES.map((f) => (
              <option key={f} value={f}>
                {f}
              </option>
            ))}
          </select>
        </label>
        <button className="btn btn-primary" type="submit">
          絞り込む
        </button>
        {(q || domain || frame || framework) && (
          <Link className="btn" href={qs({ q: '', domain: '', frame: '', framework: '', page: '1' })}>
            解除
          </Link>
        )}
      </form>

      {total === 0 ? (
        <div className="card p-6 text-center text-[13px] text-[var(--muted)]">条件に合う雛形がありません。</div>
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[900px] border-collapse text-[13px]">
            <thead>
              <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                <th className="px-4 py-2 font-medium">Phase</th>
                <th className="px-4 py-2 font-medium">領域</th>
                <th className="px-4 py-2 font-medium">テーマ / 施策</th>
                <th className="px-4 py-2 font-medium">観点</th>
                <th className="px-4 py-2 font-medium">想定するリスク</th>
              </tr>
            </thead>
            <tbody>
              {slice.map((r) => (
                <tr key={r.id} className="border-b border-[var(--border)] align-top hover:bg-[var(--surface-2)]">
                  <td className="whitespace-nowrap px-4 py-2 text-[12px] text-[var(--muted)]">{r.phase}</td>
                  <td className="whitespace-nowrap px-4 py-2 text-[12px] text-[var(--muted)]">{r.area}</td>
                  <td className="px-4 py-2">
                    {r.theme}
                    <div className="text-[12px] text-[var(--muted)]">{r.measure}</div>
                  </td>
                  <td className="whitespace-nowrap px-4 py-2">
                    <span className="badge">{r.frame}</span>
                  </td>
                  <td className="px-4 py-2">
                    <Link className="underline" href={`/n/${encodeNodeId('risk', r.id)}${mode ? `?mode=${encodeURIComponent(mode)}` : ''}`}>
                      {r.summary}
                    </Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {pages > 1 && (
        <nav className="flex items-center gap-2 text-[13px]">
          {current > 1 && (
            <Link className="btn" href={qs({ page: String(current - 1) })}>
              前へ
            </Link>
          )}
          <span className="text-[var(--muted)]">
            {current} / {pages}
          </span>
          {current < pages && (
            <Link className="btn" href={qs({ page: String(current + 1) })}>
              次へ
            </Link>
          )}
        </nav>
      )}

      <section className="card p-4">
        <h2 className="mb-2 text-[13px] font-semibold">出所</h2>
        <ProvenanceTable rows={prov} only={['risk_scenario_templates']} />
      </section>
    </div>
  );
}
