import Link from 'next/link';
import { frameworkForMode } from '@/lib/navigation';
import { getIsoRemovalContext, getRiskWorkspace, normalizeFrameworkKey } from '@/lib/riskRegister';
import { FrameworkFields } from '@/components/RegisterFormFields';
import { requestIsoRemoval, saveMeasure } from '@/app/risk-management/actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: '施策マスタ' };

type SearchParams = Promise<Record<string, string | string[] | undefined>>;

// budget_amount/resource_fte は postgres.js が numeric を文字列で返すため、
// 表示直前でのみ Number() へ変換する（2026-09-02追加）。
function formatBudget(value: string | null): string {
  if (value === null) return '—';
  return `¥${Number(value).toLocaleString('ja-JP')}`;
}
function formatFte(value: string | null): string {
  if (value === null) return '—';
  return `${Number(value).toLocaleString('ja-JP', { minimumFractionDigits: 0, maximumFractionDigits: 2 })} FTE`;
}

export default async function MeasuresPage({ searchParams }: { searchParams: SearchParams }) {
  const sp = await searchParams;
  const requestedMode = Array.isArray(sp.mode) ? sp.mode[0] : sp.mode;
  const mode = requestedMode === 'isms' || requestedMode === 'risk' ? requestedMode : undefined;
  const frameworkKey = normalizeFrameworkKey(frameworkForMode(sp.framework, mode));
  const frameworkSearch = `framework=${encodeURIComponent(frameworkKey)}${mode === 'isms' ? '&mode=isms' : ''}`;
  const [result, isoResult] = await Promise.all([getRiskWorkspace(frameworkKey), getIsoRemovalContext()]);
  const data = result.ok ? result.data : null;
  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-start justify-between gap-3"><div><Link className="text-[12px] text-[var(--muted)] underline" href={`/risk-management?${frameworkSearch}`}>← リスク台帳へ戻る</Link><h1 className="mt-2 text-[21px] font-semibold">施策マスタ</h1><p className="mt-1 text-[13px] text-[var(--muted)]">施策を共通登録し、リスク評価の施策後スコアに紐付けます。</p></div><span className="badge badge-note">{frameworkKey}</span></div>
      {!data ? <div className="card p-5 text-[13px] text-[var(--muted)]">テナントセッションが必要です。</div> : <>
        <form action={saveMeasure} className="card grid gap-3 p-4 md:grid-cols-2">
          {mode && <input type="hidden" name="mode" value={mode} />}
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">施策キー<input className="input" name="measure_key" placeholder="M-009" required /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">名称<input className="input" name="name" placeholder="アクセスレビュー" required /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">内容<textarea className="input min-h-20" name="summary" placeholder="何を、誰が、どの頻度で行うか" required /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">対応方針<select className="input" name="strategy" defaultValue="mitigate"><option value="mitigate">低減</option><option value="transfer">移転</option><option value="avoid">回避</option><option value="accept">受容</option></select></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">予算（円、任意）<input className="input" name="budget_amount" type="text" inputMode="decimal" placeholder="150000" /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">人的リソース（FTE、任意）<input className="input" name="resource_fte" type="text" inputMode="decimal" placeholder="0.15" /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">出所・判断メモ<textarea className="input" name="source_note" defaultValue="運用登録時の初期案。承認前" /></label>
          <div className="md:col-span-2"><FrameworkFields frameworks={data.frameworks} selected={frameworkKey} /></div>
          <div className="md:col-span-2"><button className="btn btn-primary" type="submit">施策を保存</button></div>
        </form>
        <section className="card overflow-x-auto"><table className="min-w-[980px] w-full border-collapse text-[13px]"><thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]"><th className="px-4 py-2 font-medium">キー / 名称</th><th className="px-4 py-2 font-medium">対応方針</th><th className="px-4 py-2 font-medium">内容</th><th className="px-4 py-2 font-medium">予算・リソース</th><th className="px-4 py-2 font-medium">関連リスク</th><th className="px-4 py-2 font-medium">編集</th></tr></thead><tbody>{data.measures.map((measure) => <tr key={measure.id} className="border-b border-[var(--border)] align-top last:border-0"><td className="px-4 py-3"><div className="font-medium">{measure.measure_key} {measure.name}</div><div className="mt-1 flex flex-wrap gap-1">{measure.tags.map((tag) => <span key={tag} className="badge badge-note">{tag}</span>)}</div></td><td className="px-4 py-3"><span className="badge">{measure.strategy}</span></td><td className="max-w-[440px] px-4 py-3 text-[12px] text-[var(--muted)]">{measure.summary}</td><td className="px-4 py-3 text-[12px] tabular-nums"><div>{formatBudget(measure.budget_amount)}</div><div className="text-[var(--muted)]">{formatFte(measure.resource_fte)}</div></td><td className="px-4 py-3">{measure.linked_risks}件</td><td className="px-4 py-3"><details><summary className="cursor-pointer text-[12px] underline">編集</summary><form action={saveMeasure} className="mt-3 grid min-w-[320px] gap-2 rounded-[var(--radius)] bg-[var(--surface-2)] p-3">{mode && <input type="hidden" name="mode" value={mode} />}<input type="hidden" name="id" value={measure.id} />{measure.tags.map((tag) => <input key={tag} type="hidden" name="framework_keys" value={tag} />)}<input className="input" name="measure_key" defaultValue={measure.measure_key} required /><input className="input" name="name" defaultValue={measure.name} required /><textarea className="input" name="summary" defaultValue={measure.summary} required /><select className="input" name="strategy" defaultValue={measure.strategy}><option value="mitigate">低減</option><option value="transfer">移転</option><option value="avoid">回避</option><option value="accept">受容</option></select><label className="flex flex-col gap-1 text-[11px] text-[var(--muted)]">予算（円、任意）<input className="input" name="budget_amount" type="text" inputMode="decimal" defaultValue={measure.budget_amount ?? ''} /></label><label className="flex flex-col gap-1 text-[11px] text-[var(--muted)]">人的リソース（FTE、任意）<input className="input" name="resource_fte" type="text" inputMode="decimal" defaultValue={measure.resource_fte ?? ''} /></label><textarea className="input" name="source_note" defaultValue="初期案。承認前" /><button className="btn btn-primary" type="submit">更新</button></form>{isoResult.ok && isoResult.data.relations.find((row) => row.entity_type === 'measure' && row.entity_id === measure.id) && <form action={requestIsoRemoval} className="mt-2 grid gap-1">{mode && <input type="hidden" name="mode" value={mode} />}<input type="hidden" name="entity_type" value="measure" /><input type="hidden" name="entity_id" value={measure.id} /><input type="hidden" name="generation_id" value={isoResult.data.relations.find((row) => row.entity_type === 'measure' && row.entity_id === measure.id)!.generation_id} /><input className="input" name="reason" placeholder="除外理由" required /><input className="input" name="alternate_control" placeholder="代替統制" required /><input className="input" name="expires_at" type="datetime-local" required /><button className="btn btn-primary" type="submit">ISO除外申請</button></form>}</details></td></tr>)}</tbody></table></section>
      </>}
    </div>
  );
}
