import Link from 'next/link';
import { listControls, listFrameworks, getProvenance } from '@/lib/catalog';
import { ProvenanceTable } from '@/components/Provenance';
import { encodeNodeId } from '@/lib/nodeid';
import { frameworkForMode } from '@/lib/navigation';
import { firstParam, pageParam, type RawParam } from '@/lib/searchParams';

export const dynamic = 'force-dynamic';

export const metadata = { title: '統制' };

const PAGE_SIZE = 100;

type SearchParams = Promise<Record<string, RawParam>>;

export default async function ControlsPage({ searchParams }: { searchParams: SearchParams }) {
  const sp = await searchParams;
  const q = firstParam(sp.q);
  const theme = firstParam(sp.theme);
  const requestedMode = firstParam(sp.mode);
  const mode = requestedMode === 'isms' || requestedMode === 'risk' ? requestedMode : undefined;
  const framework = firstParam(frameworkForMode(firstParam(sp.framework), mode));
  const page = pageParam(sp.page);

  const [rows, frameworks, prov] = await Promise.all([
    listControls({ q, theme, framework }),
    listFrameworks(),
    getProvenance(),
  ]);

  const total = rows.length;
  const pages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const current = Math.min(page, pages);
  const slice = rows.slice((current - 1) * PAGE_SIZE, current * PAGE_SIZE);

  const qs = (over: Record<string, string>) => {
    const p = new URLSearchParams();
    const merged = { q, theme, framework, mode, page: String(current), ...over };
    for (const [k, v] of Object.entries(merged)) if (v) p.set(k, v);
    return `?${p.toString()}`;
  };

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-[20px] font-semibold tracking-tight">統制カタログ</h1>
        <p className="mt-1 text-[13px] text-[var(--muted)]">
          該当 <b className="text-[var(--fg-2)]">{total}</b> 件
          {(q || theme || framework) && <>（絞り込み中）</>}
        </p>
      </div>

      <form className="card flex flex-wrap items-end gap-3 p-4" method="get">
        {mode && <input type="hidden" name="mode" value={mode} />}
        <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">
          検索（コード・表題・分類）
          <input className="input min-w-[260px]" type="search" name="q" defaultValue={q} placeholder="例: 取締役会" />
        </label>
        <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">
          フレームワーク
          <select className="input min-w-[200px]" name="framework" defaultValue={framework}>
            <option value="">すべて</option>
            {frameworks.map((f) => (
              <option key={f.key} value={f.key}>
                {f.key}（{f.control_count}）
              </option>
            ))}
          </select>
        </label>
        {theme && <input type="hidden" name="theme" value={theme} />}
        <button className="btn btn-primary" type="submit">
          絞り込む
        </button>
        {(q || theme || framework) && (
          <Link className="btn" href={qs({ q: '', theme: '', framework: '', page: '1' })}>
            解除
          </Link>
        )}
      </form>

      {theme && (
        <p className="text-[13px]">
          分類: <b>{theme}</b> で絞り込み中
        </p>
      )}

      {total === 0 ? (
        <div className="card p-6 text-center text-[13px] text-[var(--muted)]">
          条件に合う統制がありません（絞り込みを外すと全件が出ます）。
        </div>
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[860px] border-collapse text-[13px]">
            <thead>
              <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                <th className="px-4 py-2 font-medium">コード</th>
                <th className="px-4 py-2 font-medium">要請事項</th>
                <th className="px-4 py-2 font-medium">分類</th>
              </tr>
            </thead>
            <tbody>
              {slice.map((c) => (
                <tr key={c.id} className="border-b border-[var(--border)] align-top hover:bg-[var(--surface-2)]">
                  <td className="whitespace-nowrap px-4 py-2 font-[family-name:var(--font-geist-mono)]">
                    <Link className="underline" href={`/n/${encodeNodeId('control', c.id)}${mode ? `?mode=${encodeURIComponent(mode)}` : ''}`}>
                      {c.code}
                    </Link>
                  </td>
                  <td className="px-4 py-2">{c.title_ja}</td>
                  {/* 分類が無い統制を空欄にすると「取れなかった」のか「無い」のか区別が付かない。 */}
                  <td className="px-4 py-2 text-[12px] text-[var(--muted)]">
                    {(c.theme ?? '').trim() === '' ? <span className="italic">分類なし</span> : c.theme}
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
        <ProvenanceTable rows={prov} only={['controls']} />
      </section>
    </div>
  );
}
