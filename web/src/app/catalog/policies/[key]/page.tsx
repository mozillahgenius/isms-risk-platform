import Link from 'next/link';
import { notFound } from 'next/navigation';
import { getPolicy, getProvenance } from '@/lib/catalog';
import { ProvenanceTable } from '@/components/Provenance';
import { isPlaceholderBody } from '@/lib/policyBody';

export const dynamic = 'force-dynamic';

// Show the same category name as the list. Using an individual name would mean querying the DB
// once more just to show details (the rows already fetched for the main render cannot be reused).
export const metadata = { title: '規程' };

const KEY_RE = /^[a-z0-9_]{1,64}$/;

export default async function PolicyDetail({ params }: { params: Promise<{ key: string }> }) {
  const { key } = await params;
  if (!KEY_RE.test(key)) notFound();

  const policy = await getPolicy(key);
  if (!policy) notFound();

  const prov = await getProvenance();
  const placeholder = isPlaceholderBody(policy.body_md);

  return (
    <div className="flex flex-col gap-5">
      <div>
        <div className="text-[12px] text-[var(--muted)]">
          <Link className="underline" href="/catalog/policies">
            標準規程
          </Link>
        </div>
        <h1 className="mt-1 text-[20px] font-semibold tracking-tight">{policy.title_ja}</h1>
        <p className="mt-1 font-[family-name:var(--font-geist-mono)] text-[12px] text-[var(--muted)]">{policy.key}</p>
      </div>

      <section className="card p-4">
        <h2 className="mb-2 text-[13px] font-semibold">対応する条項</h2>
        <div className="flex flex-wrap gap-1.5">
          {policy.clause_refs.length === 0 ? (
            <span className="text-[12px] text-[var(--muted)]">—</span>
          ) : (
            policy.clause_refs.map((c) => (
              <span key={c} className="badge">
                {c}
              </span>
            ))
          )}
        </div>
        <p className="mt-2 text-[11px] text-[var(--muted)]">
          条項番号は文字列で持っており、統制カタログ側の行とは結ばれていない（対応表は未投入）。
        </p>
      </section>

      <section className="card p-4">
        <h2 className="mb-2 text-[13px] font-semibold">本文</h2>
        {placeholder && (
          <p className="mb-3 rounded-[var(--radius)] border border-[var(--warning)] bg-[var(--warning-weak)] px-3 py-2 text-[12px] text-[var(--badge-warning-fg)]">
            この規程の本文はまだ書かれていない（見出しだけの仮置き）。下に出ているのが DB の中身のすべて。
          </p>
        )}
        <pre className="overflow-x-auto whitespace-pre-wrap rounded-[var(--radius)] bg-[var(--surface-2)] p-3 text-[13px] text-[var(--fg-2)]">
          {policy.body_md}
        </pre>
      </section>

      <section className="card p-4">
        <h2 className="mb-2 text-[13px] font-semibold">出所</h2>
        <ProvenanceTable rows={prov} only={['dom']} />
      </section>
    </div>
  );
}
