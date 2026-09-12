import Link from 'next/link';
import { notFound } from 'next/navigation';
import {
  ANSWER_TYPE_LABEL, DELIVERY_STATUS_LABEL, getQuestionnaireDetail,
  MANAGEMENT_ROLE_LABEL, QUESTIONNAIRE_STATUS_LABEL,
} from '@/lib/externalResources';
import { recordAnswers, reviewQuestionnaire, sendQuestionnaire } from '../actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: '質問票' };

type Params = Promise<{ id: string }>;
type SearchParams = Promise<Record<string, string | string[] | undefined>>;

const ERROR_LABEL: Record<string, string> = {
  invalid_session: 'セッションが無効です。ページを再読み込みしてください。',
  no_token: 'テナントセッションが必要です。',
  not_sendable: 'この質問票は下書き・送信準備済みのときだけ送付できます。',
  no_questions: '設問が 0 件のため送付できません。',
  not_reviewable: '回答を受領した質問票だけレビュー済みにできます。',
  invalid_input: '入力内容を確認してください。',
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function first(value: string | string[] | undefined): string {
  return Array.isArray(value) ? value[0] ?? '' : value ?? '';
}

export default async function QuestionnairePage({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();
  const sp = await searchParams;
  const mode = first(sp.mode);
  const error = first(sp.error);
  const result = await getQuestionnaireDetail(id);
  const data = result.ok ? result.data : null;
  const modeInput = mode === 'isms' || mode === 'risk' ? <input type="hidden" name="mode" value={mode} /> : null;
  const backHref = mode ? `/operations/external-resources?mode=${mode}` : '/operations/external-resources';

  if (result.ok && result.data === null) notFound();

  return (
    <div className="flex flex-col gap-5">
      <header>
        <Link className="text-[12px] underline underline-offset-2" href={backHref}>← 外部リソース管理へ戻る</Link>
        <div className="mt-2 flex flex-wrap items-center gap-2">
          <span className="badge badge-note">質問票</span>
          {data ? <span className="badge">現在の権限: {MANAGEMENT_ROLE_LABEL[data.role]}</span> : null}
          {data ? <span className="badge">{QUESTIONNAIRE_STATUS_LABEL[data.questionnaire.status] ?? data.questionnaire.status}</span> : null}
        </div>
        <h1 className="mt-2 text-[22px] font-semibold tracking-tight">{data?.questionnaire.title ?? '質問票'}</h1>
        {data && (
          <p className="mt-1 text-[13px] text-[var(--muted)]">
            {data.questionnaire.vendor_name} 宛 · {data.questionnaire.recipient_name || '担当者未設定'}（{data.questionnaire.recipient_email}）
            · 期限 {data.questionnaire.due_date ?? '指定なし'}
          </p>
        )}
      </header>

      {first(sp.saved) === '1' && <div className="card border-[var(--success)] bg-[var(--success-weak)] p-4 text-sm">保存しました。</div>}
      {first(sp.queued) === '1' && <div className="card border-[var(--accent-line)] bg-[var(--accent-weak)] p-4 text-sm">送信キューへ積みました。配信ワーカーが送信すると「送信済み」に変わります。</div>}
      {error && (
        <div className="card border-[var(--danger)] bg-[var(--danger-weak)] p-4 text-sm">
          {ERROR_LABEL[error] ?? `処理できませんでした。原因区分: ${error}`}
        </div>
      )}

      {!data ? <div className="card p-5 text-[13px] text-[var(--muted)]">テナントセッションまたは信頼済みの利用者識別が必要です。</div> : <>
        <section className="card flex flex-wrap items-center gap-3 p-5">
          <div className="flex-1 min-w-[240px] text-[13px] text-[var(--muted)]">
            {data.questionnaire.purpose || '目的の記載なし'}
          </div>
          {data.canSend && ['draft', 'ready'].includes(data.questionnaire.status) && (
            <form action={sendQuestionnaire}>
              {modeInput}
              <input type="hidden" name="questionnaire_id" value={data.questionnaire.id} />
              <button className="btn btn-primary" type="submit">この内容でメール送付する</button>
            </form>
          )}
          {data.canManage && data.questionnaire.status === 'submitted' && (
            <form action={reviewQuestionnaire}>
              {modeInput}
              <input type="hidden" name="questionnaire_id" value={data.questionnaire.id} />
              <button className="btn" type="submit">レビュー済みにする</button>
            </form>
          )}
        </section>

        <section className="card p-5">
          <h2 className="text-[15px] font-semibold">設問と回答</h2>
          <p className="mt-1 text-[12px] text-[var(--muted)]">
            返信で届いた回答をここへ記録します。回答は設問ごとに保存され、監査時の証跡になります。
          </p>
          <form action={recordAnswers} className="mt-3 flex flex-col gap-3">
            {modeInput}
            <input type="hidden" name="questionnaire_id" value={data.questionnaire.id} />
            {data.questions.length === 0 ? (
              <p className="text-[13px] text-[var(--muted)]">設問がありません。</p>
            ) : data.questions.map((question) => (
              <div key={question.id} className="rounded-[var(--radius)] border border-[var(--border)] p-3">
                <div className="text-[13px]">
                  問{question.ordinal}. {question.prompt}
                  {question.required ? <span className="ms-1 text-[11px] text-[var(--badge-danger-fg)]">必須</span> : null}
                </div>
                <div className="mt-1 text-[11px] text-[var(--muted)]">
                  {ANSWER_TYPE_LABEL[question.answer_type] ?? question.answer_type}
                  {Array.isArray(question.options) && question.options.length > 0
                    ? ` · 選択肢: ${(question.options as unknown[]).map(String).join(' / ')}` : ''}
                </div>
                {data.canManage ? (
                  question.answer_type === 'single_choice' && Array.isArray(question.options) && question.options.length > 0 ? (
                    <select className="input mt-2" name={`answer_${question.id}`} defaultValue={question.answer_text}>
                      <option value="">未回答</option>
                      {(question.options as unknown[]).map((option) => (
                        <option key={String(option)} value={String(option)}>{String(option)}</option>
                      ))}
                    </select>
                  ) : question.answer_type === 'boolean' ? (
                    <select className="input mt-2" name={`answer_${question.id}`} defaultValue={question.answer_text}>
                      <option value="">未回答</option>
                      <option value="はい">はい</option>
                      <option value="いいえ">いいえ</option>
                    </select>
                  ) : (
                    <textarea className="input mt-2 min-h-16" name={`answer_${question.id}`} defaultValue={question.answer_text} placeholder="受領した回答を記録" />
                  )
                ) : (
                  <p className="mt-2 text-[13px]">{question.answer_text || '未回答'}</p>
                )}
              </div>
            ))}
            {data.canManage && data.questions.length > 0 && (
              <>
                <label className="flex items-center gap-2 text-[12px] text-[var(--muted)]">
                  <input type="checkbox" name="mark_submitted" defaultChecked />
                  回答をすべて受領したものとして「回答受領」に進める
                </label>
                <div><button className="btn btn-primary" type="submit">回答を保存</button></div>
              </>
            )}
          </form>
        </section>

        <section className="card overflow-x-auto">
          <div className="border-b border-[var(--border)] px-4 py-3">
            <h2 className="text-[15px] font-semibold">送信の記録</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">送信キューの実際の状態です。失敗した理由もここに残ります。</p>
          </div>
          <table className="min-w-[820px] w-full border-collapse text-[13px]">
            <thead>
              <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                <th className="px-4 py-2 font-medium">宛先</th>
                <th className="px-4 py-2 font-medium">件名</th>
                <th className="px-4 py-2 font-medium">状態</th>
                <th className="px-4 py-2 font-medium">積んだ時刻</th>
                <th className="px-4 py-2 font-medium">送信時刻</th>
              </tr>
            </thead>
            <tbody>
              {data.deliveries.length === 0 ? (
                <tr><td className="px-4 py-6 text-[var(--muted)]" colSpan={5}>まだ送信していません。</td></tr>
              ) : data.deliveries.map((delivery) => (
                <tr key={delivery.id} className="border-b border-[var(--border)] align-top last:border-0">
                  <td className="px-4 py-3">{delivery.to_email}</td>
                  <td className="px-4 py-3">{delivery.subject}</td>
                  <td className="px-4 py-3">
                    <span className={`badge ${delivery.status === 'failed' ? 'badge-danger' : delivery.status === 'sent' ? 'badge-done' : 'badge-on-hold'}`}>
                      {DELIVERY_STATUS_LABEL[delivery.status] ?? delivery.status}
                    </span>
                    {delivery.attempts > 0 && <div className="mt-1 text-[11px] text-[var(--muted)]">試行 {delivery.attempts}回</div>}
                    {delivery.last_error && <div className="mt-1 max-w-[280px] text-[11px] text-[var(--badge-danger-fg)]">{delivery.last_error}</div>}
                  </td>
                  <td className="px-4 py-3 tabular-nums text-[var(--muted)]">{delivery.queued_at}</td>
                  <td className="px-4 py-3 tabular-nums text-[var(--muted)]">{delivery.sent_at ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      </>}
    </div>
  );
}
