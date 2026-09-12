import Link from 'next/link';
import { getWizardSteps } from '@/lib/organizationRegister';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'ISMS構築ウィザード' };

// Deep links to the actual screen (existing page) for each step. Key logic from the spec:
// "Each step is a path to an existing screen and has no new data model"
// (only steps 1 and 2, initial organization setup and certification body info, are new).
const STEP_LINKS: Record<number, { href: string; label: string }> = {
  1: { href: '/organization/profile', label: '組織情報へ' },
  2: { href: '/organization/profile', label: '組織情報へ' },
  3: { href: '/risk-management', label: 'リスク管理へ' },
  4: { href: '/competency', label: '力量管理へ' },
  5: { href: '/incidents', label: 'インシデント管理へ' },
  6: { href: '/cost', label: 'コストへ' },
};

export default async function WizardPage() {
  const result = await getWizardSteps();
  const steps = result.ok ? result.data : null;
  const completedCount = steps?.filter((s) => s.complete).length ?? 0;
  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-[21px] font-semibold">ISMS構築ウィザード</h1>
        <p className="mt-1 text-[13px] text-[var(--muted)]">
          ゼロからのISMS立ち上げをステップ形式で案内します。ウィザードを完走しなくても、各画面から直接データ登録できます。
        </p>
      </div>
      {!steps ? <div className="card p-5 text-[13px] text-[var(--muted)]">テナントセッションが必要です。</div> : <>
        <section className="card p-4">
          <p className="text-[13px] font-medium">{completedCount} / {steps.length} ステップ完了</p>
          <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-[var(--surface-3)]">
            <div className="h-full rounded-full bg-[var(--accent)]" style={{ width: `${(completedCount / steps.length) * 100}%` }} />
          </div>
        </section>
        <section className="flex flex-col gap-3">
          {steps.map((s) => (
            <div key={s.step} className="card flex flex-wrap items-center justify-between gap-3 p-4">
              <div className="flex items-center gap-3">
                <span className={`badge ${s.complete ? 'badge-done' : 'badge-on-hold'}`}>{s.complete ? '完了' : '未完了'}</span>
                <span className="text-[13px]"><span className="font-medium">ステップ{s.step}.</span> {s.label}</span>
              </div>
              <Link className="text-[12px] underline" href={STEP_LINKS[s.step].href}>{STEP_LINKS[s.step].label}</Link>
            </div>
          ))}
        </section>
        <section className="card p-4 text-[12px] text-[var(--muted)]">
          年次アクションカレンダー(いつ何をすべきかの一覧)は本ウィザードの対象外で、未実装です。
        </section>
      </>}
    </div>
  );
}
