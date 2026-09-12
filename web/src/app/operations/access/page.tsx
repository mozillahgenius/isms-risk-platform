import Link from 'next/link';
import { getAssignmentWorkspace, MANAGEMENT_ROLE_LABEL } from '@/lib/workAssignments';
import { saveManagementRole } from '@/app/operations/assignments/actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: '権限管理' };

type SearchParams = Promise<Record<string, string | string[] | undefined>>;

function first(value: string | string[] | undefined): string {
  return Array.isArray(value) ? value[0] ?? '' : value ?? '';
}

export default async function AccessPage({ searchParams }: { searchParams: SearchParams }) {
  const sp = await searchParams;
  const mode = first(sp.mode);
  const result = await getAssignmentWorkspace();
  const data = result.ok ? result.data : null;
  return (
    <div className="flex flex-col gap-5">
      <header><span className="badge badge-note">組織アクセス</span><h1 className="mt-2 text-[22px] font-semibold">権限管理</h1><p className="mt-1 max-w-[820px] text-[13px] leading-6 text-[var(--muted)]">既存のISMS標準ロールを、リソースマネジメント上の権限として表示します。オーナーは受容・権限変更、管理者は日々の運用、マネージャーは部門の依頼、メンバーはアサインされた対象の編集を担います。メンバーの追加・停止や部門の編集は<Link className="underline underline-offset-2" href={mode ? `/organization?mode=${mode}` : '/organization'}>組織・メンバー管理</Link>で行います。</p></header>
      {sp.saved === '1' && <div className="card border-[var(--success)] bg-[var(--success-weak)] p-4 text-sm">権限を更新しました。</div>}
      {sp.error && <div className="card border-[var(--danger)] bg-[var(--danger-weak)] p-4 text-sm">権限を更新できませんでした。原因区分: {first(sp.error)}</div>}
      {!data ? <div className="card p-5 text-[13px] text-[var(--muted)]">テナントセッションまたは信頼済みの利用者識別が必要です。</div> : <>
        <section className="card grid gap-3 p-5 sm:grid-cols-2 lg:grid-cols-5">{(['owner','admin','manager','member','auditor'] as const).map((role) => <div key={role} className="rounded-[var(--radius)] bg-[var(--surface-2)] p-3"><div className="text-[12px] text-[var(--muted)]">{MANAGEMENT_ROLE_LABEL[role]}</div><div className="mt-1 text-[20px] font-semibold">{data.users.filter((user) => user.role === role).length}</div><div className="mt-1 text-[11px] text-[var(--muted)]">{role === 'owner' ? '受容・権限変更' : role === 'admin' ? '運用・依頼・送信' : role === 'manager' ? '部門対応・依頼' : role === 'member' ? '担当対象の編集' : '監査記録'}</div></div>)}</section>
        <section className="card overflow-x-auto"><table className="min-w-[780px] w-full border-collapse text-[13px]"><thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]"><th className="px-4 py-2 font-medium">利用者</th><th className="px-4 py-2 font-medium">現在の権限</th><th className="px-4 py-2 font-medium">変更</th></tr></thead><tbody>{data.users.map((user) => <tr key={user.id} className="border-b border-[var(--border)] last:border-0"><td className="px-4 py-3"><div className="font-medium">{user.display_name}</div><div className="text-[12px] text-[var(--muted)]">{user.email}</div></td><td className="px-4 py-3"><span className="badge">{MANAGEMENT_ROLE_LABEL[user.role]}</span></td><td className="px-4 py-3">{data.role === 'owner' ? <form action={saveManagementRole} className="flex flex-wrap items-center gap-2"><input type="hidden" name="user_id" value={user.id} />{mode === 'isms' || mode === 'risk' ? <input type="hidden" name="mode" value={mode} /> : null}<select className="input max-w-[190px]" name="role" defaultValue={user.role === 'none' ? 'member' : user.role}><option value="owner">オーナー</option><option value="admin">管理者</option><option value="manager">マネージャー</option><option value="member">メンバー</option><option value="auditor">監査人</option></select><button className="btn" type="submit">保存</button></form> : <span className="text-[12px] text-[var(--muted)]">オーナーのみ変更可能</span>}</td></tr>)}</tbody></table></section>
      </>}
    </div>
  );
}
