import Link from 'next/link';
import { getSystemMaster } from '@/lib/organizationRegister';
import { saveDepartmentSystem, saveSystem, updateSystem } from '@/app/organization/actions';
import {
  first, ModeField, NoSession, OrganizationShell, SYSTEM_STATUS_LABEL, type SearchParams,
} from '@/app/organization/shell';

export const dynamic = 'force-dynamic';
export const metadata = { title: '利用システムマスタ' };

export default async function SystemMasterPage({ searchParams }: { searchParams: SearchParams }) {
  const [result, sp] = await Promise.all([getSystemMaster(), searchParams]);
  const data = result.ok ? result.data : null;
  const mode = first(sp.mode);

  return (
    <OrganizationShell
      active="systems"
      mode={mode}
      saved={first(sp.saved)}
      error={first(sp.error)}
      role={data?.role ?? null}
      title="利用システムマスタ"
      description={<>
        うちが使っているシステムの正本です。監査人以外のメンバーが登録・編集できます。
        ここに登録したシステムは、情報資産の「所在場所」として選べるようになります。
      </>}
    >
      {!data ? <NoSession /> : <>
      <section className="card p-4">
        <h2 className="text-[15px] font-semibold">利用システム一覧</h2>
        <p className="mt-1 max-w-[900px] text-[12px] leading-5 text-[var(--muted)]">
          うちが使っているシステムの一覧です。<strong>監査人以外は誰でも登録・編集できます</strong>。
          ここに登録したシステムは、情報資産の
          <Link className="underline underline-offset-2" href="/risk-management/assets">資産マスタ</Link>
          で「所在場所」として選べるようになります。委託先の台帳（外部リソース管理）とは別の軸なので、
          同じ会社が両方に出てくることがあります。
        </p>

        {data.canEditSystems && (
          <form action={saveSystem} className="mt-3 grid gap-3 rounded-[var(--radius)] bg-[var(--surface-2)] p-3 md:grid-cols-4">
            <ModeField mode={mode} />
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">システム名
              <input className="input" name="name" placeholder="Google Workspace / 販売管理システム" required />
            </label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">提供元（任意）
              <input className="input" name="provider" placeholder="google / 自社開発" />
            </label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">状態
              <select className="input" name="status" defaultValue="active">
                <option value="active">利用中</option>
                <option value="planned">導入予定</option>
                <option value="paused">停止中</option>
                <option value="retired">廃止</option>
              </select>
            </label>
            <div className="md:col-span-4"><button className="btn btn-primary" type="submit">システムを追加</button></div>
          </form>
        )}

        <div className="mt-3 overflow-x-auto">
          <table className="min-w-[880px] w-full border-collapse text-[13px]">
            <thead>
              <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                <th className="px-3 py-2 font-medium">システム</th>
                <th className="px-3 py-2 font-medium">提供元</th>
                <th className="px-3 py-2 font-medium">状態</th>
                <th className="px-3 py-2 font-medium">使っている部門</th>
                <th className="px-3 py-2 font-medium">所在としている資産</th>
                {data.canEditSystems && <th className="px-3 py-2 font-medium">編集</th>}
              </tr>
            </thead>
            <tbody>
              {data.systems.length === 0 ? (
                <tr><td className="px-3 py-6 text-[var(--muted)]" colSpan={6}>システムがまだ登録されていません。</td></tr>
              ) : data.systems.map((system) => (
                <tr key={system.id} className="border-b border-[var(--border)] align-top last:border-0">
                  <td className="px-3 py-2">
                    <div className="font-medium">{system.name}</div>
                    <div className="text-[11px] text-[var(--muted)]">{system.app_key}</div>
                  </td>
                  <td className="px-3 py-2 text-[var(--muted)]">{system.provider}</td>
                  <td className="px-3 py-2">
                    <span className={`badge ${system.status === 'active' ? 'badge-done' : system.status === 'retired' ? 'badge-danger' : 'badge-on-hold'}`}>
                      {SYSTEM_STATUS_LABEL[system.status] ?? system.status}
                    </span>
                  </td>
                  <td className="px-3 py-2 tabular-nums">{system.department_count}</td>
                  <td className="px-3 py-2 tabular-nums">{system.asset_count}</td>
                  {data.canEditSystems && (
                    <td className="px-3 py-2">
                      <details>
                        <summary className="cursor-pointer text-[12px] underline">編集</summary>
                        <form action={updateSystem} className="mt-2 grid min-w-[240px] gap-2 rounded-[var(--radius)] bg-[var(--surface-2)] p-2">
                          <ModeField mode={mode} />
                          <input type="hidden" name="application_id" value={system.id} />
                          <input className="input" name="name" defaultValue={system.name} required />
                          <input className="input" name="provider" defaultValue={system.provider} />
                          <select className="input" name="status" defaultValue={system.status}>
                            <option value="active">利用中</option>
                            <option value="planned">導入予定</option>
                            <option value="paused">停止中</option>
                            <option value="retired">廃止</option>
                          </select>
                          <button className="btn" type="submit">更新</button>
                        </form>
                      </details>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {data.canEditSystems && data.departmentOptions.length > 0 && data.systems.length > 0 && (
          <form action={saveDepartmentSystem} className="mt-4 grid gap-3 rounded-[var(--radius)] border border-[var(--border)] p-3 md:grid-cols-4">
            <ModeField mode={mode} />
            <h3 className="text-[13px] font-medium md:col-span-4">部門がどう使っているかを書く</h3>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">部門
              <select className="input" name="department_id" required>
                <option value="">選択してください</option>
                {data.departmentOptions.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
              </select>
            </label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">システム
              <select className="input" name="application_id" required>
                <option value="">選択してください</option>
                {data.systems.filter((sys) => sys.status !== 'retired').map((sys) => (
                  <option key={sys.id} value={sys.id}>{sys.name}</option>
                ))}
              </select>
            </label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">どう使っているか
              <input className="input" name="usage_note" placeholder="顧客の連絡先を登録し、見積の共有に使う" />
            </label>
            <div className="md:col-span-4"><button className="btn btn-primary" type="submit">利用を記録</button></div>
          </form>
        )}
      </section>
      </>}
    </OrganizationShell>
  );
}
