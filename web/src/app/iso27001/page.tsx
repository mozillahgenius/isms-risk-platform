import { RiskWorkspace } from '@/components/RiskWorkspace';
import { approveIsoRemoval, executeIsoRemoval } from '@/app/risk-management/actions';
import { getIsoRemovalContext, getRiskDetail, getRiskWorkspace } from '@/lib/riskRegister';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'ISMS（リソースマネジメント共通台帳のISO対象）' };

export default async function Iso27001Page() {
  const frameworkKey = 'ISO27001:2022';
  const [result, removals] = await Promise.all([getRiskWorkspace(frameworkKey), getIsoRemovalContext()]);
  const detail = result.ok && result.data.risks[0] ? await getRiskDetail(result.data.risks[0].id, frameworkKey) : null;
  return <><RiskWorkspace frameworkKey={frameworkKey} workspace={result.ok ? result.data : null} detail={detail?.ok ? detail.data : null} errorReason={result.ok ? undefined : result.reason} />{removals.ok && removals.data.pending.length > 0 && <section className="card mt-5 p-4"><h2 className="text-[15px] font-semibold">ISO 除外申請</h2><div className="mt-3 grid gap-2">{removals.data.pending.map((request) => <div key={request.id} className="flex flex-wrap items-center gap-2 border-b border-[var(--border)] py-2 text-[12px]"><span>{request.entity_type} / {request.entity_id} / {request.status}</span>{request.status === 'requested' && <form action={approveIsoRemoval}><input type="hidden" name="id" value={request.id} /><button className="btn btn-primary" type="submit">承認</button></form>}{request.status === 'approved' && <form action={executeIsoRemoval}><input type="hidden" name="id" value={request.id} /><button className="btn btn-primary" type="submit">除外を実行</button></form>}</div>)}</div></section>}</>;
}
