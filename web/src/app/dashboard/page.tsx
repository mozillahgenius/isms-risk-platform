import Link from 'next/link';
import { getCounts, getCurrentDom } from '@/lib/catalog';
import { RESOURCE_MANAGEMENT_NAME } from '@/lib/navigation';
import { getRiskWorkspace } from '@/lib/riskRegister';

export const dynamic = 'force-dynamic';

export const metadata = { title: 'ダッシュボード' };

function readReason(reason?: string) {
  if (reason === 'no_token') return '運用台帳はテナント文脈が未設定のため読めません';
  if (reason === 'invalid_session') return '運用台帳のセッションが無効です';
  return '運用台帳を読み取れません';
}

export default async function DashboardPage() {
  const [dom, counts, workspace] = await Promise.all([
    getCurrentDom(),
    getCounts(),
    getRiskWorkspace('RISK-MANAGEMENT'),
  ]);

  return (
    <div className="flex max-w-[1040px] flex-col gap-7">
      <section>
        <p className="text-[12px] font-medium text-[var(--accent)]">{RESOURCE_MANAGEMENT_NAME}</p>
        <h1 className="mt-1 text-[24px] font-semibold tracking-tight">今日の管理状況</h1>
        <p className="mt-2 max-w-[860px] text-[13px] leading-relaxed text-[var(--muted)]">
          ISMSを含む共通台帳の状態と、次に開く運用画面をまとめています。
        </p>
        {dom && (
          <p className="mt-2 text-[12px] text-[var(--muted)]">標準運用モデル DOM {dom.version}</p>
        )}
      </section>

      <section>
        <div className="flex items-end justify-between gap-3">
          <h2 className="text-[15px] font-semibold">共通台帳</h2>
          <Link className="text-[12px] underline underline-offset-2" href="/risk-management?framework=RISK-MANAGEMENT">詳細を開く</Link>
        </div>
        {workspace.ok ? (
          <div className="mt-3 grid gap-3 sm:grid-cols-3">
            {[
              ['情報資産', workspace.data.assets.length],
              ['リスク', workspace.data.risks.length],
              ['対応施策', workspace.data.measures.length],
            ].map(([label, value]) => (
              <div key={String(label)} className="card p-4">
                <div className="text-[12px] text-[var(--muted)]">{label}</div>
                <div className="mt-1 text-[26px] font-semibold tabular-nums">{value}</div>
              </div>
            ))}
          </div>
        ) : (
          <p className="mt-3 rounded-[var(--radius)] border border-[var(--warning)] bg-[var(--warning-weak)] p-4 text-[13px] text-[var(--fg-2)]">
            {readReason(workspace.reason)}。0件とは扱いません。
          </p>
        )}
      </section>

      <section>
        <h2 className="text-[15px] font-semibold">次に開く</h2>
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          {[
            { label: 'ISMSの12ステップ', note: '現在の不足と次の操作を確認', href: '/' },
            { label: '運用と証跡', note: 'チェック結果と記録を確認', href: '/operations' },
            { label: 'デバイス管理', note: '端末状態と固定操作を確認', href: '/operations/device-control' },
            { label: 'パスワード管理', note: '保管庫と統制状態を確認', href: '/operations/passwords' },
          ].map((item) => (
            <Link key={item.href} href={item.href} className="group flex items-center justify-between rounded-[var(--radius)] border border-[var(--border)] bg-[var(--surface)] p-4 hover:border-[var(--border-strong)]">
              <span>
                <span className="block text-[14px] font-semibold">{item.label}</span>
                <span className="mt-1 block text-[12px] text-[var(--muted)]">{item.note}</span>
              </span>
              <span aria-hidden="true" className="text-[var(--muted)] group-hover:text-[var(--accent)]">→</span>
            </Link>
          ))}
        </div>
      </section>

      <section className="border-t border-[var(--border)] pt-4">
        <h2 className="text-[13px] font-semibold">標準カタログ</h2>
        <p className="mt-1 text-[12px] text-[var(--muted)]">
          統制 {counts.controls}件、リスク雛形 {counts.risk_scenario_templates}件、規程 {counts.policies}本、チェック {counts.checks}本。
          <Link className="ml-2 underline underline-offset-2" href="/catalog">カタログを開く</Link>
        </p>
      </section>
    </div>
  );
}
