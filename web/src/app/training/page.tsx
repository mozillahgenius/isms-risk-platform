import { evaluateTrainingRecord, syncElearningCompletions } from './actions';
import { getTrainingWorkspace } from '@/lib/trainingRegister';

export const dynamic = 'force-dynamic';
export const metadata = { title: '教育・訓練' };

const EVALUATION_BADGE: Record<string, string> = {
  未評価: 'badge-on-hold',
  有効: 'badge-done',
  要確認: 'badge-active',
  対象外: 'badge-client',
};

const ERROR_LABEL: Record<string, string> = {
  integration_not_configured: 'eラーニング連携が未設定です。',
  integration_unavailable: 'eラーニングの受講データを取得できませんでした。',
  integration_truncated: '受講データが上限を超えたため、一部だけを同期せず中止しました。連携APIのページング対応が必要です。',
  invalid_session: 'セッションが無効です。ページを再読み込みしてください。',
  no_token: 'テナントセッションが必要です。',
};

export default async function TrainingPage({ searchParams }: {
  searchParams: Promise<{ mode?: string; synced?: string; unmatched?: string; deferred?: string; evaluated?: string; error?: string }>;
}) {
  const [result, sp] = await Promise.all([getTrainingWorkspace(), searchParams]);
  const data = result.ok ? result.data : null;
  const mode = sp.mode === 'isms' ? 'isms' : 'risk';
  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-[21px] font-semibold">教育・訓練</h1>
        <p className="mt-1 text-[13px] text-[var(--muted)]">
          受講実績を管理します。eラーニングで「isms」「risk-management」タグが付いた講座の完了データを引用し、力量評価の根拠として有効かを人が評価します。教育計画そのものの作成・編集はこの画面では行いません。
        </p>
      </div>
      {sp.synced !== undefined && <section className="card border-[var(--success)] bg-[var(--success-weak)] p-4" role="status"><p className="text-sm font-semibold">{sp.synced}件を同期しました</p><p className="mt-1 text-xs">名寄せできなかった受講記録: {sp.unmatched ?? '0'}件 / 対象講座があり、取消処理を保留した完了取消: {sp.deferred ?? '0'}件</p></section>}
      {sp.evaluated === '1' && <section className="card border-[var(--success)] bg-[var(--success-weak)] p-4" role="status"><p className="text-sm font-semibold">評価を保存しました</p></section>}
      {sp.error && <section className="card border-[var(--danger)] bg-[var(--danger-weak)] p-4" role="alert"><p className="text-sm font-semibold">処理できませんでした</p><p className="mt-1 text-xs">{ERROR_LABEL[sp.error] ?? `原因区分: ${sp.error}`}</p></section>}
      <section className="card p-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div><h2 className="text-[15px] font-semibold">eラーニング受講実績</h2><p className="mt-1 text-[12px] text-[var(--muted)]">対象タグ: isms / risk-management。完了データを引用しても、力量が自動的に充足になるわけではありません。</p></div>
          {data?.canManage ? <form action={syncElearningCompletions}><input type="hidden" name="mode" value={mode} /><button className="btn btn-primary" type="submit">受講データを同期</button></form> : null}
        </div>
      </section>
      {!data ? <div className="card p-5 text-[13px] text-[var(--muted)]">テナントセッションが必要です。</div> : (
        <section className="card p-4">
          <h2 className="text-[15px] font-semibold">受講記録と評価</h2>
          <div className="mt-3 overflow-x-auto"><table className="min-w-[980px] w-full border-collapse text-[13px]"><thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]"><th className="px-3 py-2 font-medium">講座</th><th className="px-3 py-2 font-medium">タグ</th><th className="px-3 py-2 font-medium">受講者</th><th className="px-3 py-2 font-medium">完了日時</th><th className="px-3 py-2 font-medium">評価</th><th className="px-3 py-2 font-medium">操作</th></tr></thead><tbody>
            {data.records.length === 0 ? <tr><td className="px-3 py-5 text-[var(--muted)]" colSpan={6}>対象の受講記録はまだありません。</td></tr> : data.records.map((record) => <tr key={`${record.training_id}:${record.user_id}`} className="border-b border-[var(--border)] last:border-0"><td className="px-3 py-2"><div className="font-medium">{record.course_title}</div><div className="text-[11px] text-[var(--muted)]">{record.evidence_ref}</div></td><td className="px-3 py-2"><div className="flex flex-wrap gap-1">{record.course_tags.map((tag) => <span className="badge" key={tag}>{tag}</span>)}</div></td><td className="px-3 py-2">{record.member_name}<div className="text-[11px] text-[var(--muted)]">{record.member_email}</div></td><td className="px-3 py-2 text-[var(--muted)]">{record.completed_at}</td><td className="px-3 py-2"><span className={`badge ${EVALUATION_BADGE[record.evaluation_status]}`}>{record.evaluation_status}</span></td><td className="px-3 py-2">{data.canManage ? <form action={evaluateTrainingRecord} className="flex gap-2"><input type="hidden" name="mode" value={mode} /><input type="hidden" name="training_id" value={record.training_id} /><input type="hidden" name="user_id" value={record.user_id} /><select className="input" name="evaluation_status" defaultValue={record.evaluation_status === '未評価' ? '要確認' : record.evaluation_status}><option value="有効">力量の根拠として有効</option><option value="要確認">要確認</option><option value="対象外">対象外</option></select><button className="btn" type="submit">評価</button></form> : <span className="text-[var(--muted)]">閲覧のみ</span>}</td></tr>)}
          </tbody></table></div>
        </section>
      )}
    </div>
  );
}
