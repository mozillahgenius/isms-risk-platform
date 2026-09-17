import Link from 'next/link';
import { listPolicies } from '@/lib/policyRegister';

export const dynamic = 'force-dynamic';
export const metadata = { title: '規程文書' };

function StatusBadge({ approvedAt, effectiveFrom, isPlaceholder }: {
  approvedAt: string | Date | null;
  effectiveFrom: string | null;
  isPlaceholder: boolean;
}) {
  if (!effectiveFrom) {
    return <span className="badge badge-on-hold">現行版なし</span>;
  }
  if (isPlaceholder) {
    return <span className="badge badge-lead">仮置き本文</span>;
  }
  if (!approvedAt) {
    // 有効化は承認必須（DB 制約）のため、通常この分岐には来ない。念のための表示。
    return <span className="badge badge-danger">未承認のまま有効</span>;
  }
  return <span className="badge badge-done">承認・有効</span>;
}

export default async function PoliciesPage({ searchParams }: { searchParams: Promise<{ mode?: string }> }) {
  const sp = await searchParams;
  const result = await listPolicies();
  const policies = result.ok ? result.data : null;
  const mode = sp.mode === 'isms' || sp.mode === 'risk' ? sp.mode : null;

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-[21px] font-semibold">規程文書</h1>
        <p className="mt-1 text-[13px] text-[var(--muted)]">
          テナントの規程は版で管理します。内容を変えるときは新しい版を追加し、承認を経てから有効化します。
          承認済みの版は書き換えられません（DB が拒否します）。
        </p>
      </div>

      {!policies ? (
        <div className="card p-5 text-[13px] text-[var(--muted)]">
          テナントセッションが必要です。規程が読める状態にありません。
        </div>
      ) : (
        <section className="card overflow-x-auto">
          <table className="min-w-[900px] w-full border-collapse text-[13px]">
            <thead>
              <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                <th className="px-4 py-2 font-medium">規程</th>
                <th className="px-4 py-2 font-medium">現行版</th>
                <th className="px-4 py-2 font-medium">状態</th>
                <th className="px-4 py-2 font-medium">有効化日</th>
                <th className="px-4 py-2 font-medium">下書き</th>
                <th className="px-4 py-2 font-medium">全版数</th>
              </tr>
            </thead>
            <tbody>
              {policies.map((p) => (
                <tr
                  key={p.id}
                  className="border-b border-[var(--border)] align-top last:border-0 hover:bg-[var(--surface-2)]"
                >
                  <td className="px-4 py-3">
                    <Link className="font-medium underline underline-offset-2" href={mode ? `/policies/${p.id}?mode=${mode}` : `/policies/${p.id}`}>
                      {p.title}
                    </Link>
                    {p.catalog_key && (
                      <div className="mt-1 text-[11px] text-[var(--muted)]">{p.catalog_key}</div>
                    )}
                  </td>
                  <td className="px-4 py-3">{p.current_version ?? '—'}</td>
                  <td className="px-4 py-3">
                    <StatusBadge
                      approvedAt={p.current_approved_at}
                      effectiveFrom={p.current_effective_from}
                      isPlaceholder={p.current_is_placeholder}
                    />
                  </td>
                  <td className="px-4 py-3 text-[12px] text-[var(--muted)]">
                    {/* current_effective_from は date型を::textしたYYYY-MM-DD文字列。
                        Dateへ変換するとtoLocaleDateString()が実行環境のtimezoneに
                        依存し表示日がずれうるため、そのまま表示する
                        (Codexレビュー2026-09-02指摘)。 */}
                    {p.current_effective_from ?? '—'}
                  </td>
                  <td className="px-4 py-3">{p.draft_count > 0 ? <span className="badge badge-active">{p.draft_count} 件</span> : '0 件'}</td>
                  <td className="px-4 py-3 text-[12px] text-[var(--muted)]">{p.version_count}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </div>
  );
}
