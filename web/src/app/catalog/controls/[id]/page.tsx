import Link from 'next/link';
import { notFound } from 'next/navigation';
import { getControl, getControlBacklinks, getProvenance, listFrameworks } from '@/lib/catalog';
import { ProvenanceTable } from '@/components/Provenance';
import { splitTheme } from '@/lib/graphModel';

export const dynamic = 'force-dynamic';

// Show the same category name as the list. Using an individual name would require
// another DB query just for the detail (the rows already fetched for the main render can't be reused).
export const metadata = { title: '統制' };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function ControlDetail({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  // Passing a non-uuid value to the DB causes a type error and a 500. Translate it to a 404 here.
  if (!UUID_RE.test(id)) notFound();

  const control = await getControl(id);
  if (!control) notFound();

  const [back, frameworks, prov] = await Promise.all([
    getControlBacklinks(id),
    listFrameworks(),
    getProvenance(),
  ]);
  const framework = frameworks.find((f) => f.key === control.framework_key);
  const parts = splitTheme(control.theme);
  // The list filter queries by the raw theme. Passing a normalized string here could leave
  // the "view controls in the same category (N)" link with an empty destination.
  const themeRaw = parts.length > 0 ? control.theme : null;

  const links: { label: string; count: number }[] = [
    { label: '同じ分類の統制', count: back.same_theme },
    { label: 'このリスク雛形から参照', count: back.risk_templates },
    { label: 'このチェックが検証', count: back.checks },
    { label: '他フレームワークへの対応（from）', count: back.mappings_from },
    { label: '他フレームワークからの対応（to）', count: back.mappings_to },
  ];

  return (
    <div className="flex flex-col gap-5">
      <div>
        <div className="text-[12px] text-[var(--muted)]">
          <Link className="underline" href="/catalog/controls">
            統制カタログ
          </Link>
          {' / '}
          {parts.length === 0 ? (
            // Don't silently omit a missing category (the breadcrumb would just look cut off).
            <span className="italic">分類なし</span>
          ) : (
            parts.map((p, i) => (
              <span key={p}>
                {i > 0 && ' / '}
                <Link className="underline" href={`/catalog/controls?theme=${encodeURIComponent(parts.slice(0, i + 1).join(' / '))}`}>
                  {p}
                </Link>
              </span>
            ))
          )}
        </div>
        <h1 className="mt-1 text-[20px] font-semibold tracking-tight">
          <span className="font-[family-name:var(--font-geist-mono)] text-[var(--accent)]">{control.code}</span>{' '}
          {control.title_ja}
        </h1>
        <p className="mt-1 text-[12px] text-[var(--muted)]">
          フレームワーク: {framework ? `${framework.name_ja}（${framework.key}）` : control.framework_key}
          {control.retired_at && <span className="ms-2 text-[var(--danger)]">（廃止済み）</span>}
        </p>
      </div>

      {control.guidance_md && (
        <section className="card p-4">
          <h2 className="mb-2 text-[13px] font-semibold">手引き</h2>
          <p className="whitespace-pre-wrap text-[13px] text-[var(--fg-2)]">{control.guidance_md}</p>
        </section>
      )}

      <section className="card p-4">
        <h2 className="mb-1 text-[13px] font-semibold">つながり</h2>
        <p className="mb-3 text-[12px] text-[var(--muted)]">
          0 件のものは、まだ紐付けが投入されていないという意味。項目自体を隠さない。
        </p>
        <ul className="grid gap-2 text-[13px] sm:grid-cols-2">
          {links.map((l) => (
            <li key={l.label} className="flex items-center justify-between gap-3 border-b border-[var(--border)] py-1.5">
              <span className={l.count === 0 ? 'text-[var(--muted)]' : ''}>{l.label}</span>
              <b className={l.count === 0 ? 'text-[var(--danger)]' : ''}>{l.count}</b>
            </li>
          ))}
        </ul>
        {/* Controls without a category have no destination. same_theme is also 0, so this isn't shown. */}
        {back.same_theme > 0 && themeRaw !== null && (
          <Link
            className="btn mt-4"
            href={`/catalog/controls?theme=${encodeURIComponent(themeRaw)}`}
          >
            同じ分類の統制を見る（{back.same_theme + 1} 件）
          </Link>
        )}
      </section>

      <section className="card p-4">
        <h2 className="mb-2 text-[13px] font-semibold">出所</h2>
        <ProvenanceTable rows={prov} only={['controls']} />
      </section>
    </div>
  );
}
