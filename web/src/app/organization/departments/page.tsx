import Link from 'next/link';
import { getDepartmentMaster } from '@/lib/organizationRegister';
import {
  removeDepartmentSystem, saveDepartment, saveMembership, updateDepartment,
} from '@/app/organization/actions';
import { OrgChart } from '@/components/OrgChart';
import {
  first, ModeField, NoSession, OrganizationShell, type SearchParams,
} from '@/app/organization/shell';

export const dynamic = 'force-dynamic';
export const metadata = { title: '部門マスタ' };

export default async function DepartmentMasterPage({ searchParams }: { searchParams: SearchParams }) {
  const [result, sp] = await Promise.all([getDepartmentMaster(), searchParams]);
  const data = result.ok ? result.data : null;
  const mode = first(sp.mode);

  return (
    <OrganizationShell
      active="departments"
      mode={mode}
      saved={first(sp.saved)}
      error={first(sp.error)}
      role={data?.role ?? null}
      title="部門マスタ"
      description={<>
        部門と責任者（マネージャー）、メンバーの所属を管理します。
        あわせて、その部門がどのシステムを使い、そこにどんな情報資産があるかを一覧します。
      </>}
    >
      {!data ? <NoSession /> : <>
      <section className="card p-4">
        <h2 className="text-[15px] font-semibold">部門と責任者（マネージャー）</h2>
        <p className="mt-1 text-[12px] text-[var(--muted)]">
          部門の責任者は、その部門のリスクと是正処置を担います。組織図はツリーで表示されます。
        </p>
        {data.canManageOrg && (
          <div className="mt-3 grid gap-3 md:grid-cols-2">
            <form action={saveDepartment} className="grid gap-2 rounded-[var(--radius)] bg-[var(--surface-2)] p-3">
              <ModeField mode={mode} />
              <h3 className="text-[13px] font-medium">部門を登録</h3>
              <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">部門名<input className="input" name="name" required /></label>
              <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">上位部門(任意)
                <select className="input" name="parent_id" defaultValue=""><option value="">なし</option>
                  {data.departments.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
                </select>
              </label>
              <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">責任者(任意)
                <select className="input" name="owner_user_id" defaultValue=""><option value="">未設定</option>
                  {data.users.map((u) => <option key={u.id} value={u.id}>{u.display_name}</option>)}
                </select>
              </label>
              <div><button className="btn btn-primary" type="submit">部門を登録</button></div>
            </form>
            {data.canManageRole && (
              <form action={saveMembership} className="grid gap-2 rounded-[var(--radius)] bg-[var(--surface-2)] p-3">
                <ModeField mode={mode} />
                <h3 className="text-[13px] font-medium">所属と役割を割り当て</h3>
                <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">対象者
                  <select className="input" name="user_id" required><option value="">選択してください</option>
                    {data.users.map((u) => <option key={u.id} value={u.id}>{u.display_name}</option>)}
                  </select>
                </label>
                <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">役割
                  <select className="input" name="role_key" required><option value="">選択してください</option>
                    {data.roles.map((r) => <option key={r.key} value={r.key}>{r.name_ja}</option>)}
                  </select>
                </label>
                <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">所属部門(任意)
                  <select className="input" name="department_id" defaultValue=""><option value="">なし</option>
                    {data.departments.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
                  </select>
                </label>
                <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">任命日<input className="input" type="date" name="granted_at" required /></label>
                <div><button className="btn btn-primary" type="submit">割り当てる</button></div>
              </form>
            )}
          </div>
        )}

        {data.canManageOrg && data.departments.length > 0 && (
          <details className="mt-3">
            <summary className="cursor-pointer text-[13px] underline underline-offset-2">既存の部門を編集する</summary>
            <div className="mt-3 grid gap-3 md:grid-cols-2">
              {data.departments.map((d) => (
                <form key={d.id} action={updateDepartment} className="grid gap-2 rounded-[var(--radius)] border border-[var(--border)] p-3">
                  <ModeField mode={mode} />
                  <input type="hidden" name="department_id" value={d.id} />
                  <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">部門名
                    <input className="input" name="name" defaultValue={d.name} required />
                  </label>
                  <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">上位部門
                    <select className="input" name="parent_id" defaultValue={d.parent_id ?? ''}>
                      <option value="">なし</option>
                      {data.departments.filter((other) => other.id !== d.id).map((other) => (
                        <option key={other.id} value={other.id}>{other.name}</option>
                      ))}
                    </select>
                  </label>
                  <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">責任者(マネージャー)
                    <select className="input" name="owner_user_id" defaultValue={d.owner_user_id ?? ''}>
                      <option value="">未設定</option>
                      {data.users.map((u) => <option key={u.id} value={u.id}>{u.display_name}</option>)}
                    </select>
                  </label>
                  <div><button className="btn" type="submit">この部門を更新</button></div>
                </form>
              ))}
            </div>
          </details>
        )}

        <div className="mt-4"><OrgChart departments={data.departments} memberships={data.memberships} /></div>
      </section>

      <section className="card p-4">
        <h2 className="text-[15px] font-semibold">部門ごとの利用実態と、扱っている情報</h2>
        <p className="mt-1 max-w-[900px] text-[12px] leading-5 text-[var(--muted)]">
          どの部門が、どのシステムを、どう使っていて、そこにどんな情報資産が置かれているかです。
          ここに新しい入力欄は置いていません。<strong>扱っている情報の正本は情報資産台帳</strong>で、
          資産の「管理部門」と「所在場所」を埋めるとこの表が埋まります。
        </p>
        {data.assetsWithoutDepartment > 0 && (
          <p className="mt-2 text-[12px] text-[var(--badge-danger-fg)]">
            管理部門が未設定の情報資産が {data.assetsWithoutDepartment} 件あります。
            <Link className="underline underline-offset-2" href="/risk-management/assets">資産マスタ</Link>
            で管理部門を設定すると、ここに反映されます。
          </p>
        )}

        {data.departments.length === 0 ? (
          <p className="mt-3 text-[13px] text-[var(--muted)]">先に部門を登録してください。</p>
        ) : (
          <div className="mt-3 flex flex-col gap-4">
            {data.departments.map((department) => {
              const usages = data.departmentSystems.filter((row) => row.department_id === department.id);
              const information = data.departmentInformation.filter((row) => row.department_id === department.id);
              return (
                <div key={department.id} className="rounded-[var(--radius)] border border-[var(--border)] p-3">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium text-[14px]">{department.name}</span>
                    <span className="text-[12px] text-[var(--muted)]">
                      在籍 {department.member_count}名{department.owner_name ? ` / 責任者 ${department.owner_name}` : ''}
                    </span>
                  </div>

                  <div className="mt-2 text-[12px] font-medium text-[var(--muted)]">使っているシステム</div>
                  {usages.length === 0 ? (
                    <p className="text-[12px] text-[var(--muted)]">まだ記録がありません。</p>
                  ) : (
                    <ul className="mt-1 flex flex-col gap-1">
                      {usages.map((usage) => (
                        <li key={usage.application_id} className="flex flex-wrap items-center gap-2 text-[13px]">
                          <span className="badge badge-note">{usage.system_name}</span>
                          <span className="text-[var(--muted)]">{usage.usage_note || '用途の記載なし'}</span>
                          {data.canEditSystems && (
                            <form action={removeDepartmentSystem}>
                              <ModeField mode={mode} />
                              <input type="hidden" name="department_id" value={usage.department_id} />
                              <input type="hidden" name="application_id" value={usage.application_id} />
                              <button className="btn px-2 py-0.5 text-[11px]" type="submit">外す</button>
                            </form>
                          )}
                        </li>
                      ))}
                    </ul>
                  )}

                  <div className="mt-3 text-[12px] font-medium text-[var(--muted)]">そこにある情報資産</div>
                  {information.length === 0 ? (
                    <p className="text-[12px] text-[var(--muted)]">この部門を管理部門とする情報資産がまだありません。</p>
                  ) : (
                    <div className="mt-1 overflow-x-auto">
                      <table className="min-w-[620px] w-full border-collapse text-[12px]">
                        <thead>
                          <tr className="text-left text-[11px] text-[var(--muted)]">
                            <th className="py-1 pr-3 font-medium">所在場所</th>
                            <th className="py-1 pr-3 font-medium">件数</th>
                            <th className="py-1 pr-3 font-medium">分類</th>
                            <th className="py-1 font-medium">情報資産</th>
                          </tr>
                        </thead>
                        <tbody>
                          {information.map((row) => (
                            <tr key={`${row.application_id ?? 'none'}:${row.location_note}`} className="border-t border-[var(--border)] align-top">
                              <td className="py-1 pr-3">
                                {row.system_name ? <span className="badge badge-note">{row.system_name}</span> : null}
                                {row.location_note ? <div className="text-[var(--muted)]">{row.location_note}</div> : null}
                                {!row.system_name && !row.location_note ? <span className="text-[var(--muted)]">未設定</span> : null}
                              </td>
                              <td className="py-1 pr-3 tabular-nums">{row.asset_count}</td>
                              <td className="py-1 pr-3">
                                <div className="flex flex-wrap gap-1">
                                  {row.classifications.map((c) => <span key={c} className="badge">{c}</span>)}
                                </div>
                              </td>
                              <td className="py-1 text-[var(--muted)]">{row.asset_names.join('、')}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </section>
      </>}
    </OrganizationShell>
  );
}
