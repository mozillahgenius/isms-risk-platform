import Link from 'next/link';
import { frameworkForMode } from '@/lib/navigation';
import { getRiskWorkspace, normalizeFrameworkKey } from '@/lib/riskRegister';
import { LatestRiskLevel } from '@/components/LatestRiskLevel';
import { saveRisk } from '@/app/risk-management/actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'リスク台帳' };

type SearchParams = Promise<Record<string, string | string[] | undefined>>;

export default async function RisksRegisterPage({ searchParams }: { searchParams: SearchParams }) {
  const sp = await searchParams;
  const requestedMode = Array.isArray(sp.mode) ? sp.mode[0] : sp.mode;
  const mode = requestedMode === 'isms' || requestedMode === 'risk' ? requestedMode : undefined;
  const frameworkKey = normalizeFrameworkKey(frameworkForMode(sp.framework, mode));
  const frameworkSearch = `framework=${encodeURIComponent(frameworkKey)}${mode === 'isms' ? '&mode=isms' : ''}`;
  const result = await getRiskWorkspace(frameworkKey);
  const data = result.ok ? result.data : null;
  const requestedEditId = Array.isArray(sp.edit) ? sp.edit[0] : sp.edit;
  const editedRisk = data?.risks.find((risk) => risk.id === requestedEditId);
  const isEditing = Boolean(editedRisk);
  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-start justify-between gap-3"><div><Link className="text-[12px] text-[var(--muted)] underline" href={`/risk-management?${frameworkSearch}`}>← リスク台帳へ戻る</Link><h1 className="mt-2 text-[21px] font-semibold">リスク台帳</h1><p className="mt-1 text-[13px] text-[var(--muted)]">Phase、領域、対象資産、施策前後の評価履歴を一つのリスク項目で保持します。</p></div><div className="flex items-center gap-2"><Link className="btn px-3 py-1.5 text-[12px]" href={`/operations/assignments?work_type=risk_assessment${mode ? `&mode=${mode}` : ''}`}>作業を依頼</Link><span className="badge badge-note">{frameworkKey}</span></div></div>
      {!data ? <div className="card p-5 text-[13px] text-[var(--muted)]">テナントセッションが必要です。</div> : <>
        <form action={saveRisk} className="card grid gap-3 p-4 md:grid-cols-2">
          {mode && <input type="hidden" name="mode" value={mode} />}
          {editedRisk && <input type="hidden" name="risk_id" value={editedRisk.id} />}
          <div className="text-[13px] font-medium md:col-span-2">{isEditing ? `${editedRisk!.risk_key} を編集` : '新しいリスクを登録'}</div>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">リスクキー<input className="input" name="risk_key" placeholder="RISK-009" defaultValue={editedRisk?.risk_key} required /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">Phase<select className="input" name="phase" defaultValue={String(editedRisk?.phase ?? 1)}><option value="1">Phase 1</option><option value="2">Phase 2</option><option value="3">Phase 3</option><option value="4">Phase 4</option><option value="5">Phase 5</option></select></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">領域<input className="input" name="area" placeholder="顧客・案件管理" defaultValue={editedRisk?.area} required /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">観点<select className="input" name="frame" defaultValue={editedRisk?.frame ?? '管理可能性'}><option value="管理可能性">管理可能性</option><option value="精度">精度</option><option value="スピード">スピード</option></select></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">テーマ<input className="input" name="theme" placeholder="権限管理" defaultValue={editedRisk?.theme} required /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">想定する施策<input className="input" name="measure" placeholder="アクセス棚卸" defaultValue={editedRisk?.measure} required /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">リスク要約<textarea className="input min-h-20" name="summary" placeholder="何が起き、何に影響するか" defaultValue={editedRisk?.summary} required /></label>
          <fieldset className="flex flex-col gap-2 md:col-span-2"><legend className="text-[12px] font-medium text-[var(--muted)]">関連資産</legend><div className="grid gap-2 sm:grid-cols-2">{data.assets.map((asset) => <label key={asset.id} className="inline-flex items-start gap-1.5 text-[12px]"><input type="checkbox" name="asset_ids" value={asset.id} defaultChecked={editedRisk?.assets.some((linked) => linked.id === asset.id)} /><span><span className="font-[family-name:var(--font-geist-mono)]">{asset.asset_key}</span> {asset.name}</span></label>)}</div></fieldset>
          <fieldset className="flex flex-col gap-2 md:col-span-2"><legend className="text-[12px] font-medium text-[var(--muted)]">枠組みタグ</legend><div className="flex flex-wrap gap-3">{data.frameworks.map((framework) => <label key={framework.key} className="inline-flex items-center gap-1.5 text-[12px]"><input type="checkbox" name="framework_keys" value={framework.key} defaultChecked={editedRisk ? editedRisk.tags.includes(framework.key) : framework.key === frameworkKey || framework.key === 'RISK-MANAGEMENT'} />{framework.name_ja}</label>)}</div></fieldset>
          <div className="flex gap-2 md:col-span-2"><button className="btn btn-primary" type="submit">{isEditing ? '変更を保存' : 'リスクを保存'}</button>{isEditing && <Link className="btn" href={`/risk-management/risks?${frameworkSearch}`}>編集をやめる</Link>}</div>
          </form>
          <section className="card overflow-x-auto"><table className="min-w-[1100px] w-full border-collapse text-[13px]"><thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]"><th className="px-4 py-2 font-medium">Phase</th><th className="px-4 py-2 font-medium">キー / リスク</th><th className="px-4 py-2 font-medium">資産</th><th className="px-4 py-2 font-medium">施策</th><th className="px-4 py-2 font-medium">最新レベル</th><th className="px-4 py-2 font-medium">評価履歴</th></tr></thead><tbody>{data.risks.map((risk) => <tr key={risk.id} className="border-b border-[var(--border)] align-top last:border-0 hover:bg-[var(--surface-2)]"><td className="px-4 py-3"><span className="badge">Phase {risk.phase}</span><div className="mt-1 text-[11px] text-[var(--muted)]">{risk.area}</div></td><td className="px-4 py-3"><Link className="font-medium underline underline-offset-2" href={`/risk-management/risks/${risk.id}?${frameworkSearch}`}>{risk.risk_key} {risk.summary}</Link><div className="mt-1 flex flex-wrap gap-1">{risk.tags.map((tag) => <span key={tag} className="badge badge-note">{tag}</span>)}</div><Link className="mt-2 inline-block text-[12px] underline" href={`/risk-management/risks?${frameworkSearch}&edit=${encodeURIComponent(risk.id)}`}>編集</Link></td><td className="px-4 py-3 text-[12px] text-[var(--muted)]">{risk.assets.map((asset) => asset.name).join('、') || '未紐付け'}</td><td className="px-4 py-3 text-[12px] text-[var(--muted)]">{risk.measure}</td><td className="px-4 py-3"><LatestRiskLevel level={risk.latest_level} stage={risk.latest_stage} /></td><td className="px-4 py-3"><Link className="text-[12px] underline" href={`/risk-management/risks/${risk.id}?${frameworkSearch}`}>{risk.snapshot_count}件を確認</Link></td></tr>)}</tbody></table></section>
      </>}
    </div>
  );
}
