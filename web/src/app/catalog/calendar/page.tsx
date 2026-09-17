import { listCalendar, listRoles } from '@/lib/catalog';

export const dynamic = 'force-dynamic';

export const metadata = { title: '年間カレンダー' };

const CADENCE_LABEL: Record<string, string> = {
  daily: '毎日',
  weekly: '毎週',
  monthly: '毎月',
  quarterly: '四半期',
  semiannual: '半期',
  annual: '毎年',
  event: '随時',
};

export default async function CalendarPage() {
  const [events, roles] = await Promise.all([listCalendar(), listRoles()]);
  const roleName = new Map(roles.map((r) => [r.key, r.name_ja]));

  const groups = [...new Set(events.map((e) => e.cadence))];

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-[20px] font-semibold tracking-tight">年間カレンダー（{events.length}）</h1>
        <p className="mt-1 max-w-[880px] text-[13px] text-[var(--muted)]">
          期首からの月数で持つので、テナントの期首月が 4 月でなくてもそのまま使える。
          担当ロールは <code className="font-[family-name:var(--font-geist-mono)]">owner_role</code> の外部キーで、
          <b>画面が導き出したものではなく DB に実在する関係</b>。
        </p>
      </div>

      {groups.map((cad) => (
        <section key={cad}>
          <h2 className="mb-2 text-[14px] font-semibold">
            {CADENCE_LABEL[cad] ?? cad}
            <span className="ml-2 text-[12px] font-normal text-[var(--muted)]">
              {events.filter((e) => e.cadence === cad).length} 件
            </span>
          </h2>
          <div className="card overflow-x-auto">
            <table className="w-full min-w-[760px] border-collapse text-[13px]">
              <thead>
                <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                  <th className="px-4 py-2 font-medium">行事</th>
                  <th className="px-4 py-2 font-medium">期首からの月</th>
                  <th className="px-4 py-2 font-medium">担当</th>
                  <th className="px-4 py-2 font-medium">条項（seed 上の関連メタ）</th>
                  <th className="px-4 py-2 font-medium">延期</th>
                </tr>
              </thead>
              <tbody>
                {events
                  .filter((e) => e.cadence === cad)
                  .map((e) => (
                    <tr key={e.key} className="border-b border-[var(--border)]">
                      <td className="px-4 py-2">
                        {e.name_ja}
                        <div className="font-[family-name:var(--font-geist-mono)] text-[11px] text-[var(--muted)]">
                          {e.key}
                        </div>
                      </td>
                      <td className="px-4 py-2 text-[var(--muted)]">
                        {e.offset_months === null ? '—' : `+${e.offset_months} か月`}
                      </td>
                      <td className="px-4 py-2">{roleName.get(e.owner_role) ?? e.owner_role}</td>
                      <td className="px-4 py-2">
                        {e.clause_ref ? <span className="badge">{e.clause_ref}</span> : <span className="text-[var(--muted)]">—</span>}
                      </td>
                      <td className="px-4 py-2 text-[12px]">
                        {e.extendable ? (
                          <span className="text-[var(--muted)]">可</span>
                        ) : (
                          <span className="text-[var(--danger)]">不可</span>
                        )}
                      </td>
                    </tr>
                  ))}
              </tbody>
            </table>
          </div>
        </section>
      ))}
    </div>
  );
}
