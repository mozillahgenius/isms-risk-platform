import { listChecks } from '@/lib/catalog';

export const dynamic = 'force-dynamic';

export const metadata = { title: '標準チェック' };

export default async function ChecksPage() {
  const rows = await listChecks();

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-[20px] font-semibold tracking-tight">標準チェック（{rows.length}）</h1>
        <p className="mt-1 max-w-[880px] text-[13px] text-[var(--muted)]">
          統制が実際に効いているかを機械で確かめる問い合わせ。DOM の一部として配られる想定。
        </p>
      </div>

      {rows.length === 0 ? (
        <div className="card border-[var(--danger)] p-6">
          <h2 className="text-[15px] font-semibold text-[var(--danger)]">未投入（0 件）</h2>
          <p className="mt-2 max-w-[760px] text-[13px] text-[var(--fg-2)]">
            設計書は 66 本を想定しているが、実際に投入されているのは 0 本。
            設計書に <code className="font-[family-name:var(--font-geist-mono)]">query_sql</code> と
            <code className="font-[family-name:var(--font-geist-mono)]">negative_fixture</code>
            が書かれているのが 4 本しかなく、残りは中身が決まっていないため入れていない。
          </p>
          <p className="mt-2 max-w-[760px] text-[13px] text-[var(--muted)]">
            件数を偽らないために、この画面は「66 本ある」とは書かない。
            チェックは<b>落ちることを確かめてから</b>数える（negative_fixture が要るのはそのため）。
          </p>
        </div>
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[860px] border-collapse text-[13px]">
            <thead>
              <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                <th className="px-4 py-2 font-medium">キー</th>
                <th className="px-4 py-2 font-medium">名称</th>
                <th className="px-4 py-2 font-medium">深刻度</th>
                <th className="px-4 py-2 font-medium">周期</th>
                <th className="px-4 py-2 font-medium">コネクタ</th>
                <th className="px-4 py-2 font-medium">期限</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((c) => (
                <tr key={c.key} className="border-b border-[var(--border)]">
                  <td className="px-4 py-2 font-[family-name:var(--font-geist-mono)]">{c.key}</td>
                  <td className="px-4 py-2">{c.title_ja}</td>
                  <td className="px-4 py-2">{c.severity}</td>
                  <td className="px-4 py-2">{c.cadence}</td>
                  <td className="px-4 py-2 text-[12px] text-[var(--muted)]">{c.connectors.join(', ')}</td>
                  <td className="px-4 py-2">{c.due_days} 日</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
