import { getCostWorkspace } from '@/lib/costRegister';
import { saveRate, saveEducationRecord } from '@/app/cost/actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: '教育コストと人件費' };

// postgres.js は numeric を文字列で返す。表示直前でのみ Number() 変換する(0035と同じ方針)。
function yen(value: string | null): string {
  if (value === null) return '—';
  return `¥${Number(value).toLocaleString('ja-JP')}`;
}

const ERROR_LABEL: Record<string, string> = {
  duplicate_rate: '同じ役割・同じ適用開始日の単価が既に登録されています。適用開始日を変えるか、既存の単価改定として別の日付で登録してください。',
  invalid_session: 'セッションが無効です。ページを再読み込みしてください。',
  no_token: 'テナントセッションが必要です。',
};

export default async function CostPage({ searchParams }: { searchParams: Promise<{ saved?: string; error?: string; mode?: string }> }) {
  const [result, sp] = await Promise.all([getCostWorkspace(), searchParams]);
  const data = result.ok ? result.data : null;
  const mode = sp.mode === 'isms' || sp.mode === 'risk' ? sp.mode : null;
  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-[21px] font-semibold">教育コストと人件費</h1>
        <p className="mt-1 text-[13px] text-[var(--muted)]">
          役割別の単価と教育工数から人件費を算出します。個人別の給与は扱いません(役割別の集計値のみ)。
          リターン(到達度)の算出方法は未確定のため、まずはコスト側のみを可視化します。
        </p>
      </div>
      {sp.saved === '1' && (
        <section className="card border-[var(--success)] bg-[var(--success-weak)] p-4" role="status">
          <p className="text-sm font-semibold text-[var(--badge-success-fg)]">保存しました</p>
        </section>
      )}
      {sp.error && (
        <section className="card border-[var(--danger)] bg-[var(--danger-weak)] p-4" role="alert">
          <p className="text-sm font-semibold text-[var(--badge-danger-fg)]">保存できませんでした</p>
          <p className="mt-1 text-xs text-[var(--fg-2)]">{ERROR_LABEL[sp.error] ?? `原因区分: ${sp.error}`}</p>
        </section>
      )}
      {!data ? <div className="card p-5 text-[13px] text-[var(--muted)]">テナントセッションが必要です。</div> : <>
        <section className="card p-4">
          <h2 className="text-[15px] font-semibold">単価マスタ</h2>
          <p className="mt-1 text-[12px] text-[var(--muted)]">役割ごとの時間単価。改定時は同じ役割に新しい適用開始日で追加登録します(既存行は書き換えません)。</p>
          <form action={saveRate} className="mt-3 grid gap-3 p-3 md:grid-cols-2 bg-[var(--surface-2)] rounded-[var(--radius)]">
            {mode ? <input type="hidden" name="mode" value={mode} /> : null}
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">役割<input className="input" name="role" placeholder="講師 / 教材作成 / 受講者 / 既定" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">時間単価(円)<input className="input" name="hourly_rate" type="text" inputMode="decimal" placeholder="3000" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">適用開始日<input className="input" type="date" name="effective_from" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">出所・判断メモ<input className="input" name="source_note" placeholder="決定した会議・根拠" /></label>
            <div className="md:col-span-2"><button className="btn btn-primary" type="submit">単価を登録</button></div>
          </form>
          <div className="mt-3 overflow-x-auto"><table className="min-w-[520px] w-full border-collapse text-[13px]"><thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]"><th className="px-3 py-2 font-medium">役割</th><th className="px-3 py-2 font-medium">時間単価</th><th className="px-3 py-2 font-medium">適用開始日</th><th className="px-3 py-2 font-medium">出所</th></tr></thead><tbody>{data.rates.map((rate) => <tr key={rate.id} className="border-b border-[var(--border)] last:border-0"><td className="px-3 py-2">{rate.role}</td><td className="px-3 py-2 tabular-nums">{yen(rate.hourly_rate)}</td><td className="px-3 py-2 text-[var(--muted)]">{rate.effective_from}</td><td className="px-3 py-2 text-[12px] text-[var(--muted)]">{rate.source_note || '—'}</td></tr>)}</tbody></table></div>
        </section>

        <section className="card p-4">
          <h2 className="text-[15px] font-semibold">教育工数の記録</h2>
          <form action={saveEducationRecord} className="mt-3 grid gap-3 p-3 md:grid-cols-2 bg-[var(--surface-2)] rounded-[var(--radius)]">
            {mode ? <input type="hidden" name="mode" value={mode} /> : null}
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">プログラム名<input className="input" name="program_name" placeholder="ISMS基礎研修" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">役割<input className="input" name="role" placeholder="単価マスタの役割と一致させる" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">対象者(任意)<select className="input" name="member_id" defaultValue=""><option value="">なし</option>{data.members.map((m) => <option key={m.id} value={m.id}>{m.display_name}</option>)}</select></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">工数(時間)<input className="input" name="hours" type="text" inputMode="decimal" placeholder="2" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">実施日<input className="input" type="date" name="conducted_on" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">紐付け施策(任意)<select className="input" name="related_measure_id" defaultValue=""><option value="">なし</option>{data.measures.map((m) => <option key={m.id} value={m.id}>{m.measure_key} {m.name}</option>)}</select></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">出所・判断メモ<input className="input" name="source_note" placeholder="研修記録・出席簿へのリンク等" /></label>
            <div className="md:col-span-2"><button className="btn btn-primary" type="submit">工数を記録</button></div>
          </form>
          <div className="mt-3 overflow-x-auto"><table className="min-w-[880px] w-full border-collapse text-[13px]"><thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]"><th className="px-3 py-2 font-medium">プログラム</th><th className="px-3 py-2 font-medium">役割</th><th className="px-3 py-2 font-medium">対象者</th><th className="px-3 py-2 font-medium">工数</th><th className="px-3 py-2 font-medium">実施日</th><th className="px-3 py-2 font-medium">コスト</th><th className="px-3 py-2 font-medium">紐付け施策</th></tr></thead><tbody>{data.educationRecords.map((rec) => <tr key={rec.id} className="border-b border-[var(--border)] last:border-0"><td className="px-3 py-2">{rec.program_name}</td><td className="px-3 py-2">{rec.role}</td><td className="px-3 py-2 text-[var(--muted)]">{rec.member_name ?? '—'}</td><td className="px-3 py-2 tabular-nums">{rec.hours}h</td><td className="px-3 py-2 text-[var(--muted)]">{rec.conducted_on}</td><td className="px-3 py-2 tabular-nums">{rec.cost_amount === null ? <span className="badge badge-client">単価未登録</span> : yen(rec.cost_amount)}</td><td className="px-3 py-2 text-[var(--muted)]">{rec.related_measure_name ?? '—'}</td></tr>)}</tbody></table></div>
        </section>

        <section className="card p-4">
          <h2 className="text-[15px] font-semibold">施策別コスト集計</h2>
          <p className="mt-1 text-[12px] text-[var(--muted)]">予算(画面②③) + 紐付けられた教育コストの合計。到達度に基づくリターンの算出は未実装(未決事項)。</p>
          <div className="mt-3 overflow-x-auto"><table className="min-w-[680px] w-full border-collapse text-[13px]"><thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]"><th className="px-3 py-2 font-medium">施策</th><th className="px-3 py-2 font-medium">予算</th><th className="px-3 py-2 font-medium">教育コスト</th><th className="px-3 py-2 font-medium">合計コスト</th></tr></thead><tbody>{data.measureCosts.map((mc) => <tr key={mc.id} className="border-b border-[var(--border)] last:border-0"><td className="px-3 py-2">{mc.measure_key} {mc.name}</td><td className="px-3 py-2 tabular-nums">{yen(mc.budget_amount)}</td><td className="px-3 py-2 tabular-nums">{yen(mc.education_cost)}</td><td className="px-3 py-2 tabular-nums font-medium">{yen(mc.total_cost)}</td></tr>)}</tbody></table></div>
        </section>
      </>}
    </div>
  );
}
