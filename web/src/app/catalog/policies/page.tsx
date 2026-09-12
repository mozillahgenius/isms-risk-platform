import Link from 'next/link';
import { listPolicies, getProvenance } from '@/lib/catalog';
import { ProvenanceTable } from '@/components/Provenance';
import { encodeNodeId } from '@/lib/nodeid';
import { isPlaceholderBody } from '@/lib/policyBody';

export const dynamic = 'force-dynamic';

export const metadata = { title: '規程' };

export default async function PoliciesPage() {
  const [rows, prov] = await Promise.all([listPolicies(), getProvenance()]);
  const placeholders = rows.filter((p) => isPlaceholderBody(p.body_md)).length;

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-[20px] font-semibold tracking-tight">標準規程</h1>
        <p className="mt-1 max-w-[860px] text-[13px] text-[var(--muted)]">
          DOM が定める {rows.length} 本。テナントはこれを写して使い、<b>差分は逸脱として記録される</b>
          （設計書 1.6）。
        </p>
        {placeholders > 0 && (
          <p className="mt-2 rounded-[var(--radius)] border border-[var(--warning)] bg-[var(--warning-weak)] px-3 py-2 text-[12px] text-[var(--badge-warning-fg)]">
            うち <b>{placeholders} 本は本文が未整備</b>（見出しだけの仮置き）。規程の中身はまだ書かれていない。
          </p>
        )}
      </div>

      <div className="card overflow-x-auto">
        <table className="w-full min-w-[720px] border-collapse text-[13px]">
          <thead>
            <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
              <th className="px-4 py-2 font-medium">#</th>
              <th className="px-4 py-2 font-medium">規程</th>
              <th className="px-4 py-2 font-medium">条項（seed 上の関連メタ）</th>
              <th className="px-4 py-2 font-medium">本文</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((p) => (
              <tr key={p.key} className="border-b border-[var(--border)] align-top hover:bg-[var(--surface-2)]">
                <td className="whitespace-nowrap px-4 py-2 text-[var(--muted)]">{p.sort_order}</td>
                <td className="px-4 py-2">
                  <Link className="underline" href={`/n/${encodeNodeId('policy', p.key)}`}>
                    {p.title_ja}
                  </Link>
                  <div className="font-[family-name:var(--font-geist-mono)] text-[11px] text-[var(--muted)]">{p.key}</div>
                </td>
                <td className="px-4 py-2">
                  <div className="flex flex-wrap gap-1">
                    {p.clause_refs.length === 0 ? (
                      <span className="text-[12px] text-[var(--muted)]">—</span>
                    ) : (
                      p.clause_refs.map((c) => (
                        <span key={c} className="badge">
                          {c}
                        </span>
                      ))
                    )}
                  </div>
                </td>
                <td className="px-4 py-2">
                  {isPlaceholderBody(p.body_md) ? (
                    <span className="text-[12px] text-[var(--warning)]">未整備（仮置き）</span>
                  ) : (
                    <span className="text-[12px] text-[var(--success)]">あり</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="text-[12px] text-[var(--muted)]">
        「条項」の欄は seed が規程に添えている関連メタで、<b>規格との正式な対応表ではない</b>
        （既知の取りこぼしがある）。段階と箇条の対応は
        <Link className="mx-1 underline" href="/">
          ISMS の進め方
        </Link>
        を正とする。
      </p>

      <section className="card p-4">
        <h2 className="mb-2 text-[13px] font-semibold">出所</h2>
        <ProvenanceTable rows={prov} only={['dom']} />
      </section>
    </div>
  );
}
