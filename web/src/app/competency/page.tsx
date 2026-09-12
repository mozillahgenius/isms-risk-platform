import { getCompetencyWorkspace } from '@/lib/competencyRegister';
import { saveRequirement, saveFulfillment } from '@/app/competency/actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: '力量' };

const ERROR_LABEL: Record<string, string> = {
  invalid_session: 'セッションが無効です。ページを再読み込みしてください。',
  no_token: 'テナントセッションが必要です。',
};

const STATUS_BADGE: Record<string, string> = {
  充足: 'badge-done',
  育成中: 'badge-active',
  未充足: 'badge-danger',
};

export default async function CompetencyPage({ searchParams }: { searchParams: Promise<{ saved?: string; error?: string; mode?: string }> }) {
  const [result, sp] = await Promise.all([getCompetencyWorkspace(), searchParams]);
  const data = result.ok ? result.data : null;
  const mode = sp.mode === 'isms' || sp.mode === 'risk' ? sp.mode : null;
  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-[21px] font-semibold">力量</h1>
        <p className="mt-1 text-[13px] text-[var(--muted)]">
          役割ごとに必要な力量(職能要件)を定義し、メンバーの充足状況を評価します(ISO/IEC 27001 本文7.2)。教育・訓練の受講完了だけでは自動的に充足とせず、評価済みの受講記録を根拠として引用できます。
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
          <h2 className="text-[15px] font-semibold">力量要件の定義</h2>
          <form action={saveRequirement} className="mt-3 grid gap-3 p-3 md:grid-cols-2 bg-[var(--surface-2)] rounded-[var(--radius)]">
            {mode ? <input type="hidden" name="mode" value={mode} /> : null}
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">役割<input className="input" name="role" placeholder="事務局 / 内部監査人 等" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">必要な力量<input className="input" name="required_competency" placeholder="ISO27001基礎知識" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">説明<textarea className="input min-h-16" name="description" placeholder="求める知識・経験・資格等" /></label>
            <div className="md:col-span-2"><button className="btn btn-primary" type="submit">要件を登録</button></div>
          </form>
        </section>

        <section className="card p-4">
          <h2 className="text-[15px] font-semibold">要件別の充足状況</h2>
          <p className="mt-1 text-[12px] text-[var(--muted)]">分母は充足状況が記録されているメンバー数(未評価者は含みません)。</p>
          <div className="mt-3 overflow-x-auto"><table className="min-w-[560px] w-full border-collapse text-[13px]"><thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]"><th className="px-3 py-2 font-medium">役割</th><th className="px-3 py-2 font-medium">必要な力量</th><th className="px-3 py-2 font-medium">充足率</th></tr></thead><tbody>{data.summaries.map((s) => <tr key={s.requirement_id} className="border-b border-[var(--border)] last:border-0"><td className="px-3 py-2">{s.role}</td><td className="px-3 py-2">{s.required_competency}</td><td className="px-3 py-2 tabular-nums">{s.total_count === 0 ? <span className="text-[var(--muted)]">未評価</span> : <>{s.fulfilled_count} / {s.total_count}{s.fulfilled_count < s.total_count && <span className="ms-2 badge badge-danger">未充足あり</span>}</>}</td></tr>)}</tbody></table></div>
        </section>

        <section className="card p-4">
          <h2 className="text-[15px] font-semibold">メンバー別の充足状況を記録</h2>
          <form action={saveFulfillment} className="mt-3 grid gap-3 p-3 md:grid-cols-2 bg-[var(--surface-2)] rounded-[var(--radius)]">
            {mode ? <input type="hidden" name="mode" value={mode} /> : null}
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">力量要件<select className="input" name="requirement_id" required><option value="">選択してください</option>{data.requirements.map((r) => <option key={r.id} value={r.id}>{r.role} / {r.required_competency}</option>)}</select></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">対象者<select className="input" name="member_id" required><option value="">選択してください</option>{data.members.map((m) => <option key={m.id} value={m.id}>{m.display_name}</option>)}</select></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">状況<select className="input" name="status" defaultValue="未充足"><option value="充足">充足</option><option value="育成中">育成中</option><option value="未充足">未充足</option></select></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">確認日<input className="input" type="date" name="assessed_on" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">評価済みの教育・訓練記録<select className="input" name="training_evidence_id" defaultValue=""><option value="">引用しない</option>{data.trainingEvidence.map((e) => <option key={`${e.training_id}:${e.user_id}`} value={`${e.training_id}:${e.user_id}`}>{e.label}</option>)}</select><span>対象者と一致し「有効」と評価された記録だけを保存時に引用します。</span></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">その他の根拠<input className="input" name="evidence_ref" placeholder="資格証明・面談記録などの所在（任意）" /></label>
            <div className="md:col-span-2"><button className="btn btn-primary" type="submit">記録する</button></div>
          </form>
          <div className="mt-3 overflow-x-auto"><table className="min-w-[780px] w-full border-collapse text-[13px]"><thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]"><th className="px-3 py-2 font-medium">役割 / 力量</th><th className="px-3 py-2 font-medium">対象者</th><th className="px-3 py-2 font-medium">状況</th><th className="px-3 py-2 font-medium">確認日</th><th className="px-3 py-2 font-medium">根拠</th></tr></thead><tbody>{data.fulfillments.map((f) => <tr key={f.id} className="border-b border-[var(--border)] last:border-0"><td className="px-3 py-2">{f.role} / {f.required_competency}</td><td className="px-3 py-2">{f.member_name}</td><td className="px-3 py-2"><span className={`badge ${STATUS_BADGE[f.status]}`}>{f.status}</span>{f.evidence_needs_review ? <span className="ms-2 badge badge-active">根拠の再評価要</span> : null}</td><td className="px-3 py-2 text-[var(--muted)]">{f.assessed_on}</td><td className="px-3 py-2 text-[12px] text-[var(--muted)]">{f.evidence_ref || '—'}</td></tr>)}</tbody></table></div>
        </section>
      </>}
    </div>
  );
}
