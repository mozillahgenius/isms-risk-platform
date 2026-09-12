import Link from 'next/link';
import { getMemberMaster, MANAGEMENT_ROLE_LABEL, type ManagementRole } from '@/lib/organizationRegister';
import { addMember, saveMemberRole, setMemberStatus } from '@/app/organization/actions';
import {
  dash, first, ModeField, NoSession, OrganizationShell, STATUS_LABEL, withMode,
  type SearchParams,
} from '@/app/organization/shell';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'メンバーマスタ' };

const ROLE_DUTY: Record<ManagementRole, string> = {
  owner: '受容判断・権限変更・例外承認',
  admin: '日々の運用・依頼・外部送信',
  manager: '自部門のリスクと依頼',
  member: '割り当てられた対象の編集',
  auditor: '内部監査の記録（業務データは変更しない）',
  none: '所属はあるが管理ロール未設定',
};

export default async function MemberMasterPage({ searchParams }: { searchParams: SearchParams }) {
  const [result, sp] = await Promise.all([getMemberMaster(), searchParams]);
  const data = result.ok ? result.data : null;
  const mode = first(sp.mode);
  const accessHref = withMode('/operations/access', mode);
  const assignmentsHref = withMode('/operations/assignments', mode);

  return (
    <OrganizationShell
      active="members"
      mode={mode}
      saved={first(sp.saved)}
      error={first(sp.error)}
      role={data?.role ?? null}
      title="メンバーマスタ"
      description={<>
        メンバーの登録と、権限（オーナー・管理者・マネージャー・メンバー・監査人）の管理です。
        ここで在籍にしたメンバーだけがこのシステムにログインでき、
        <Link className="underline underline-offset-2" href={assignmentsHref}>依頼・アサイン</Link>
        の担当者として選べるようになります。
      </>}
    >
      {!data ? <NoSession /> : <>
      <section className="card grid gap-3 p-5 sm:grid-cols-2 lg:grid-cols-5">
        {(['owner', 'admin', 'manager', 'member', 'auditor'] as const).map((role) => (
          <div key={role} className="rounded-[var(--radius)] bg-[var(--surface-2)] p-3">
            <div className="text-[12px] text-[var(--muted)]">{MANAGEMENT_ROLE_LABEL[role]}</div>
            <div className="mt-1 text-[20px] font-semibold tabular-nums">{data.roleCounts[role]}</div>
            <div className="mt-1 text-[11px] leading-5 text-[var(--muted)]">{ROLE_DUTY[role]}</div>
          </div>
        ))}
      </section>

      <section className="card overflow-hidden">
        <div className="flex flex-wrap items-start justify-between gap-3 border-b border-[var(--border)] px-4 py-3">
          <div>
            <h2 className="text-[15px] font-semibold">メンバー名簿</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">
              在籍しているメンバーだけがログインできます。停止・退職も残して表示します。
            </p>
          </div>
          <Link className="btn px-3 py-1.5 text-[12px]" href={accessHref}>権限だけの一覧を見る</Link>
        </div>

        {data.canManageOrg && (
          <form action={addMember} className="grid gap-3 border-b border-[var(--border)] bg-[var(--surface-2)] p-4 md:grid-cols-4">
            <ModeField mode={mode} />
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">氏名
              <input className="input" name="display_name" placeholder="山田 太郎" required />
            </label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">メールアドレス
              <input className="input" name="email" type="email" placeholder="member@example.com" required />
              <span className="text-[11px]">ログイン時の本人確認に使う識別子です。</span>
            </label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">権限
              <select className="input" name="role" defaultValue="member">
                {(['member', 'manager', 'admin', 'auditor', 'owner'] as const)
                  .filter((role) => role !== 'owner' || data.canManageRole)
                  .map((role) => <option key={role} value={role}>{MANAGEMENT_ROLE_LABEL[role]}</option>)}
              </select>
            </label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">所属部門（任意）
              <select className="input" name="department_id" defaultValue="">
                <option value="">なし</option>
                {data.departmentOptions.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
              </select>
            </label>
            <div className="md:col-span-4"><button className="btn btn-primary" type="submit">メンバーを追加</button></div>
          </form>
        )}

        <div className="overflow-x-auto">
          <table className="min-w-[980px] w-full border-collapse text-[13px]">
            <thead>
              <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                <th className="px-4 py-2 font-medium">メンバー</th>
                <th className="px-4 py-2 font-medium">権限</th>
                <th className="px-4 py-2 font-medium">所属</th>
                <th className="px-4 py-2 font-medium">在籍</th>
                <th className="px-4 py-2 font-medium">変更</th>
              </tr>
            </thead>
            <tbody>
              {data.members.length === 0 ? (
                <tr><td className="px-4 py-8 text-[var(--muted)]" colSpan={5}>メンバーがいません。</td></tr>
              ) : data.members.map((member) => (
                <tr key={member.id} className="border-b border-[var(--border)] align-top last:border-0">
                  <td className="px-4 py-3">
                    <div className="font-medium">{member.display_name}</div>
                    <div className="text-[12px] text-[var(--muted)]">{member.email}</div>
                  </td>
                  <td className="px-4 py-3">
                    <span className="badge">{MANAGEMENT_ROLE_LABEL[member.role]}</span>
                    {member.leads_departments.length > 0 && (
                      <div className="mt-1 text-[11px] text-[var(--muted)]">責任者: {member.leads_departments.join('、')}</div>
                    )}
                  </td>
                  <td className="px-4 py-3 text-[var(--muted)]">{dash(member.department_name)}</td>
                  <td className="px-4 py-3">
                    <span className={`badge ${member.status === 'active' ? 'badge-done' : 'badge-danger'}`}>
                      {STATUS_LABEL[member.status] ?? member.status}
                    </span>
                  </td>
                  <td className="px-4 py-3">
                    <div className="flex flex-col gap-2">
                      {data.canManageRole ? (
                        <form action={saveMemberRole} className="flex flex-wrap items-center gap-2">
                          <ModeField mode={mode} />
                          <input type="hidden" name="user_id" value={member.id} />
                          <select className="input max-w-[170px]" name="role" defaultValue={member.role === 'none' ? 'member' : member.role}>
                            {(['owner', 'admin', 'manager', 'member', 'auditor'] as const).map((role) => (
                              <option key={role} value={role}>{MANAGEMENT_ROLE_LABEL[role]}</option>
                            ))}
                          </select>
                          <button className="btn" type="submit">権限を保存</button>
                        </form>
                      ) : <span className="text-[12px] text-[var(--muted)]">権限の変更はオーナーのみ</span>}
                      {data.canManageOrg && member.id !== data.currentUserId && (
                        <form action={setMemberStatus} className="flex flex-wrap items-center gap-2">
                          <ModeField mode={mode} />
                          <input type="hidden" name="user_id" value={member.id} />
                          <select className="input max-w-[130px]" name="status" defaultValue={member.status}>
                            <option value="active">在籍</option>
                            <option value="suspended">停止</option>
                            <option value="left">退職</option>
                          </select>
                          <button className="btn" type="submit">在籍を保存</button>
                        </form>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
      </>}
    </OrganizationShell>
  );
}
