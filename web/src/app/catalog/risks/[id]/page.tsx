import Link from 'next/link';
import { notFound } from 'next/navigation';
import { getProvenance, getRisk, getRiskControlCount } from '@/lib/catalog';
import { ProvenanceTable } from '@/components/Provenance';

export const dynamic = 'force-dynamic';

// Show the same domain and Phase as the list. Phase is not embedded in the title but shown as a separate value.
export const metadata = { title: 'リスクシナリオ雛形' };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function RiskDetail({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID_RE.test(id)) notFound();

  const risk = await getRisk(id);
  if (!risk) notFound();

  const [controlCount, prov] = await Promise.all([getRiskControlCount(id), getProvenance()]);
  return (
    <div className="flex flex-col gap-5">
      <div>
        <div className="text-[12px] text-[var(--muted)]">
          <Link className="underline" href="/catalog/risks">
            リスクシナリオ雛形
          </Link>
          {' / '}
          <Link className="underline" href={`/catalog/risks?domain=${encodeURIComponent(risk.domain)}`}>
            Phase {risk.phase} / {risk.area}
          </Link>
        </div>
        <h1 className="mt-1 text-[20px] font-semibold tracking-tight">{risk.summary}</h1>
        <p className="mt-1 text-[12px] text-[var(--muted)]">
          {risk.theme} / {risk.measure}
          {risk.retired_at && <span className="ms-2 text-[var(--danger)]">（廃止済み）</span>}
        </p>
      </div>

      <section className="card p-4">
        <dl className="grid gap-3 text-[13px] sm:grid-cols-2">
          <div>
            <dt className="text-[12px] text-[var(--muted)]">観点</dt>
            <dd className="mt-0.5">
              <Link className="badge" href={`/catalog/risks?frame=${encodeURIComponent(risk.frame)}`}>
                {risk.frame}
              </Link>
            </dd>
          </div>
          <div>
            <dt className="text-[12px] text-[var(--muted)]">既定の対応</dt>
            <dd className="mt-0.5">{risk.default_action}</dd>
          </div>
          <div className="sm:col-span-2">
            <dt className="text-[12px] text-[var(--muted)]">想定業種</dt>
            <dd className="mt-0.5 flex flex-wrap gap-1.5">
              {risk.industry_presets.map((p) => (
                <span key={p} className="badge">
                  {p}
                </span>
              ))}
            </dd>
          </div>
        </dl>
      </section>

      <section className="card p-4">
        <h2 className="mb-1 text-[13px] font-semibold">紐付いている統制</h2>
        <p className="text-[13px]">
          <b className={controlCount === 0 ? 'text-[var(--danger)]' : ''}>{controlCount}</b> 件
          {controlCount === 0 && (
            <span className="ms-2 text-[12px] text-[var(--muted)]">
              （catalog.risk_template_controls が未投入。雛形と統制の対応はまだ作られていない）
            </span>
          )}
        </p>
      </section>

      <section className="card p-4">
        <h2 className="mb-2 text-[13px] font-semibold">出所</h2>
        <ProvenanceTable rows={prov} only={['risk_scenario_templates']} />
      </section>
    </div>
  );
}
