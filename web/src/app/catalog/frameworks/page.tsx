import Link from 'next/link';
import { getAnnexAShape, getCounts, listFrameworks } from '@/lib/catalog';

export const dynamic = 'force-dynamic';

export const metadata = { title: 'フレームワーク' };

export default async function FrameworksPage() {
  const [frameworks, counts, annexA] = await Promise.all([
    listFrameworks(),
    getCounts(),
    getAnnexAShape(),
  ]);
  const empty = frameworks.filter((f) => f.control_count === 0);

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-[20px] font-semibold tracking-tight">フレームワーク（{frameworks.length}）</h1>
        <p className="mt-1 max-w-[880px] text-[13px] text-[var(--muted)]">
          統制の出どころ。行が在ることと、その統制が入っていることは別。
          {empty.length > 0 && (
            <>
              　いま <b className="text-[var(--danger)]">{empty.length} 件は統制が 0 件</b>（枠だけ在る）。
            </>
          )}
        </p>
      </div>

      <div className="grid gap-3 lg:grid-cols-3">
        {frameworks.map((f) => (
          <div key={f.key} className={`card p-4 ${f.control_count === 0 ? 'border-[var(--danger)]' : ''}`}>
            <div className="flex items-baseline justify-between gap-2">
              <h2 className="text-[14px] font-semibold">{f.name_ja}</h2>
              <span className="font-[family-name:var(--font-geist-mono)] text-[11px] text-[var(--muted)]">{f.key}</span>
            </div>
            <div className={`mt-2 text-[24px] font-semibold ${f.control_count === 0 ? 'text-[var(--danger)]' : ''}`}>
              {f.control_count}
              <span className="ml-1 text-[12px] font-normal text-[var(--muted)]">件の統制</span>
            </div>
            {f.control_count === 0 && (
              <p className="mt-1 text-[11px] text-[var(--danger)]">未投入（この規格の統制本体はまだ入っていない）</p>
            )}
            {f.source_note && <p className="mt-2 text-[12px] text-[var(--fg-2)]">{f.source_note}</p>}
            {f.control_count > 0 && (
              <Link className="btn mt-3" href={`/catalog/controls?framework=${encodeURIComponent(f.key)}`}>
                統制を見る
              </Link>
            )}
          </div>
        ))}
      </div>

      {/* 件数だけを見ていると、附属書 A ではない統制を ISO27001:2022 に紐付けても通ってしまう。
          コードの形（A.x.y）が合っている件数を併せて出す。 */}
      <section className="card p-4">
        <h2 className="mb-1 text-[13px] font-semibold">附属書 A の統制コードの形</h2>
        <p className="text-[13px]">
          ISO/IEC 27001:2022 に紐付いた統制 <b>{annexA.total}</b> 件のうち、
          附属書 A のコードの形（A.x.y）をしているものは <b>{annexA.wellFormed}</b> 件。
        </p>
        {annexA.total === 0 ? (
          <p className="mt-1 text-[12px] text-[var(--danger)]">
            附属書 A の統制はまだ 1 件も入っていない。適用宣言書はこれがそろうまで作れない。
          </p>
        ) : annexA.wellFormed !== annexA.total ? (
          <p className="mt-1 text-[12px] text-[var(--danger)]">
            形が合わないものが {annexA.total - annexA.wellFormed} 件ある。
            附属書 A の統制として扱えない。
          </p>
        ) : null}
      </section>

      <section className="card p-4">
        <h2 className="mb-1 text-[13px] font-semibold">フレームワーク間の対応表</h2>
        <p className="text-[13px]">
          <b className={counts.framework_mappings === 0 ? 'text-[var(--danger)]' : ''}>{counts.framework_mappings}</b> 件
          {counts.framework_mappings === 0 && (
            <span className="ml-2 text-[12px] text-[var(--muted)]">
              （catalog.framework_mappings が未投入。IPO-KARTE と ISO27001 の対応はまだ作られていない）
            </span>
          )}
        </p>
      </section>
    </div>
  );
}
