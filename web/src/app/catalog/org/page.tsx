import { listAssetClasses, listCalendar, listRoles } from '@/lib/catalog';

export const dynamic = 'force-dynamic';

export const metadata = { title: '体制・分類' };

const SHARE_LABEL: Record<string, { label: string; cls: string }> = {
  forbidden: { label: '外部共有 禁止', cls: 'badge badge-danger' },
  approval_required: { label: '外部共有 要承認', cls: 'badge badge-on-hold' },
  allowed: { label: '外部共有 可', cls: 'badge badge-done' },
};

export default async function OrgPage() {
  const [roles, assets, calendar] = await Promise.all([listRoles(), listAssetClasses(), listCalendar()]);
  const eventsByRole = new Map<string, number>();
  for (const e of calendar) eventsByRole.set(e.owner_role, (eventsByRole.get(e.owner_role) ?? 0) + 1);

  return (
    <div className="flex flex-col gap-8">
      <section>
        <h1 className="text-[20px] font-semibold tracking-tight">標準ロール（{roles.length}）</h1>
        <p className="mt-1 text-[13px] text-[var(--muted)]">
          設計書 1.3 で 5 つに固定。増やさない（役割が増えるほど、誰も見ない役割が増えるため）。
        </p>
        <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {roles.map((r) => (
            <div key={r.key} className="card p-4">
              <div className="flex items-baseline justify-between gap-2">
                <h2 className="text-[14px] font-semibold">{r.name_ja}</h2>
                <span className="font-[family-name:var(--font-geist-mono)] text-[11px] text-[var(--muted)]">{r.key}</span>
              </div>
              <p className="mt-1.5 text-[13px] text-[var(--fg-2)]">{r.description}</p>
              <p className="mt-2 text-[11px] text-[var(--muted)]">
                年間カレンダーの担当: {eventsByRole.get(r.key) ?? 0} 件
              </p>
            </div>
          ))}
        </div>
      </section>

      <section>
        <h1 className="text-[20px] font-semibold tracking-tight">資産分類（{assets.length}）</h1>
        <p className="mt-1 text-[13px] text-[var(--muted)]">
          設計書 1.7 で 4 区分に固定。テナントごとの追加はできない（分類が増えると、同じ資産が
          組織ごとに違う扱いになり突合できなくなるため）。
        </p>
        <div className="mt-3 card overflow-x-auto">
          <table className="w-full min-w-[560px] border-collapse text-[13px]">
            <thead>
              <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                <th className="px-4 py-2 font-medium">位</th>
                <th className="px-4 py-2 font-medium">区分</th>
                <th className="px-4 py-2 font-medium">外部共有</th>
              </tr>
            </thead>
            <tbody>
              {assets.map((a) => (
                <tr key={a.key} className="border-b border-[var(--border)]">
                  <td className="px-4 py-2 text-[var(--muted)]">{a.rank}</td>
                  <td className="px-4 py-2">
                    {a.name_ja}
                    <span className="ml-2 font-[family-name:var(--font-geist-mono)] text-[11px] text-[var(--muted)]">
                      {a.key}
                    </span>
                  </td>
                  <td className="px-4 py-2">
                    <span className={SHARE_LABEL[a.external_share_policy]?.cls ?? 'badge'}>
                      {SHARE_LABEL[a.external_share_policy]?.label ?? a.external_share_policy}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}
