import Link from 'next/link';
import {
  ANSWER_TYPE_LABEL, DELIVERY_STATUS_LABEL, getExternalResourceWorkspace,
  MANAGEMENT_ROLE_LABEL, QUESTIONNAIRE_STATUS_LABEL, TEMPLATE_KIND_LABEL,
} from '@/lib/externalResources';
import {
  addTemplateQuestion, createQuestionnaire, removeTemplateQuestion,
  saveExternalResource, saveTemplate, updateTemplate,
} from './actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: '外部リソース管理' };

type SearchParams = Promise<Record<string, string | string[] | undefined>>;

const ERROR_LABEL: Record<string, string> = {
  invalid_session: 'セッションが無効です。ページを再読み込みしてください。',
  no_token: 'テナントセッションが必要です。',
  duplicate_template: '同じ名前のテンプレートが既にあります。',
  template_not_found: 'テンプレートが見つからないか、無効になっています。',
  template_empty: '設問が 0 件のテンプレートからは質問票を作れません。',
  invalid_input: '入力内容を確認してください。',
};

function first(value: string | string[] | undefined): string {
  return Array.isArray(value) ? value[0] ?? '' : value ?? '';
}

function statusBadge(status: string): string {
  if (status === 'submitted' || status === 'reviewed') return 'badge-done';
  if (status === 'cancelled') return 'badge-danger';
  if (status === 'queued' || status === 'sent') return 'badge-note';
  return 'badge-on-hold';
}

export default async function ExternalResourcesPage({ searchParams }: { searchParams: SearchParams }) {
  const sp = await searchParams;
  const mode = first(sp.mode);
  const error = first(sp.error);
  const result = await getExternalResourceWorkspace({ templateId: first(sp.template) });
  const data = result.ok ? result.data : null;
  // const に束ねてから使う。data.selectedTemplate のままだと、map の
  // コールバック内で null 除外の絞り込みが効かない。
  const selectedTemplate = data ? data.selectedTemplate : null;
  const modeInput = mode === 'isms' || mode === 'risk' ? <input type="hidden" name="mode" value={mode} /> : null;
  const withMode = (href: string) => (mode ? `${href}${href.includes('?') ? '&' : '?'}mode=${mode}` : href);

  return (
    <div className="flex flex-col gap-5">
      <header>
        <div className="flex flex-wrap items-center gap-2">
          <span className="badge badge-note">共通機能</span>
          {data ? <span className="badge">現在の権限: {MANAGEMENT_ROLE_LABEL[data.role]}</span> : null}
        </div>
        <h1 className="mt-2 text-[22px] font-semibold tracking-tight">外部リソース管理</h1>
        <p className="mt-1 max-w-[900px] text-[13px] leading-6 text-[var(--muted)]">
          委託先・クラウドサービス・外部業者を共通のリソースとして管理し、チェックリストやアンケートの
          テンプレートを作って送付します。ISMSに限定せず、他の業務にも使える設計です。
        </p>
      </header>

      {first(sp.saved) === '1' && <div className="card border-[var(--success)] bg-[var(--success-weak)] p-4 text-sm">保存しました。</div>}
      {error && (
        <div className="card border-[var(--danger)] bg-[var(--danger-weak)] p-4 text-sm">
          {ERROR_LABEL[error] ?? `処理できませんでした。原因区分: ${error}`}
        </div>
      )}

      {!data ? <div className="card p-5 text-[13px] text-[var(--muted)]">テナントセッションまたは信頼済みの利用者識別が必要です。</div> : <>
        {data.canWork && (
          <section className="card grid gap-3 p-5">
            <div>
              <h2 className="text-[15px] font-semibold">外部リソースを登録</h2>
              <p className="mt-1 text-[12px] text-[var(--muted)]">既存の委託先台帳を共通リソースとして再利用します。</p>
            </div>
            <form action={saveExternalResource} className="grid gap-3 md:grid-cols-4">
              {modeInput}
              <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">会社・サービス名
                <input className="input" name="name" placeholder="例：クラウド業者A" required />
              </label>
              <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">サービス名
                <input className="input" name="service_name" placeholder="利用サービス・委託業務" />
              </label>
              <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">重要度
                <select className="input" name="criticality" defaultValue="medium">
                  <option value="high">高</option><option value="medium">中</option><option value="low">低</option>
                </select>
              </label>
              <div className="flex items-end"><button className="btn btn-primary" type="submit">リソースを登録</button></div>
            </form>
            <div className="mt-1 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
              {data.vendors.length === 0 ? <p className="text-[13px] text-[var(--muted)]">外部リソースはまだありません。</p> : data.vendors.map((vendor) => (
                <div key={vendor.id} className="rounded-[var(--radius)] border border-[var(--border)] p-3">
                  <div className="font-medium">{vendor.name}</div>
                  <div className="mt-1 text-[12px] text-[var(--muted)]">
                    {vendor.service_name || 'サービス名未設定'} · 重要度 {vendor.criticality || '未設定'} · 質問票 {vendor.questionnaire_count}件
                  </div>
                </div>
              ))}
            </div>
          </section>
        )}

        {data.canManage && (
          <section className="card p-5">
            <h2 className="text-[15px] font-semibold">チェックリスト・アンケートのテンプレート</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">
              聞くことを雛形として登録しておき、送るときに複写します。テンプレートを後から直しても、
              既に送った質問票の中身は変わりません。
            </p>

            <div className="mt-3 grid gap-4 lg:grid-cols-[minmax(0,320px)_minmax(0,1fr)]">
              <div className="flex flex-col gap-3">
                <form action={saveTemplate} className="grid gap-2 rounded-[var(--radius)] bg-[var(--surface-2)] p-3">
                  {modeInput}
                  <h3 className="text-[13px] font-medium">テンプレートを新規作成</h3>
                  <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">名前
                    <input className="input" name="name" placeholder="委託先セキュリティチェックリスト" required />
                  </label>
                  <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">種類
                    <select className="input" name="kind" defaultValue="checklist">
                      {Object.entries(TEMPLATE_KIND_LABEL).map(([key, label]) => <option key={key} value={key}>{label}</option>)}
                    </select>
                  </label>
                  <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">目的
                    <input className="input" name="purpose" placeholder="契約更新・新規利用開始・定期評価など" />
                  </label>
                  <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">説明（社内用）
                    <textarea className="input min-h-16" name="description" />
                  </label>
                  <button className="btn btn-primary" type="submit">作成して設問を足す</button>
                </form>

                <ul className="flex flex-col gap-2">
                  {data.templates.length === 0 ? (
                    <li className="text-[13px] text-[var(--muted)]">テンプレートはまだありません。</li>
                  ) : data.templates.map((template) => (
                    <li key={template.id}>
                      <Link
                        href={withMode(`/operations/external-resources?template=${template.id}`)}
                        className={`block rounded-[var(--radius)] border p-3 ${selectedTemplate?.id === template.id ? 'border-[var(--accent-line)] bg-[var(--accent-weak)]' : 'border-[var(--border)]'}`}
                      >
                        <div className="flex flex-wrap items-center gap-2">
                          <span className="font-medium text-[13px]">{template.name}</span>
                          <span className="badge">{TEMPLATE_KIND_LABEL[template.kind] ?? template.kind}</span>
                          {!template.is_active && <span className="badge badge-danger">停止中</span>}
                        </div>
                        <div className="mt-1 text-[12px] text-[var(--muted)]">
                          設問 {template.question_count}問{template.purpose ? ` · ${template.purpose}` : ''}
                        </div>
                      </Link>
                    </li>
                  ))}
                </ul>
              </div>

              <div>
                {!selectedTemplate ? (
                  <p className="text-[13px] text-[var(--muted)]">左のテンプレートを選ぶと、設問の編集と質問票の作成ができます。</p>
                ) : (
                  <div className="flex flex-col gap-4">
                    <form action={updateTemplate} className="grid gap-2 rounded-[var(--radius)] border border-[var(--border)] p-3 md:grid-cols-2">
                      {modeInput}
                      <input type="hidden" name="template_id" value={selectedTemplate.id} />
                      <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">名前
                        <input className="input" name="name" defaultValue={selectedTemplate.name} required />
                      </label>
                      <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">種類
                        <select className="input" name="kind" defaultValue={selectedTemplate.kind}>
                          {Object.entries(TEMPLATE_KIND_LABEL).map(([key, label]) => <option key={key} value={key}>{label}</option>)}
                        </select>
                      </label>
                      <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">目的
                        <input className="input" name="purpose" defaultValue={selectedTemplate.purpose} />
                      </label>
                      <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">説明（社内用）
                        <textarea className="input min-h-16" name="description" defaultValue={selectedTemplate.description} />
                      </label>
                      <label className="flex items-center gap-2 text-[12px] text-[var(--muted)] md:col-span-2">
                        <input type="checkbox" name="is_active" defaultChecked={selectedTemplate.is_active} />
                        このテンプレートを使えるようにする（外すと新規の質問票では選べなくなります）
                      </label>
                      <div className="md:col-span-2"><button className="btn" type="submit">テンプレートを保存</button></div>
                    </form>

                    <div className="rounded-[var(--radius)] border border-[var(--border)]">
                      <div className="border-b border-[var(--border)] px-3 py-2 text-[13px] font-medium">
                        設問（{selectedTemplate.questions.length}問）
                      </div>
                      <ul className="divide-y divide-[var(--border)]">
                        {selectedTemplate.questions.length === 0 ? (
                          <li className="px-3 py-4 text-[12px] text-[var(--muted)]">設問がありません。下のフォームから足してください。</li>
                        ) : selectedTemplate.questions.map((question) => (
                          <li key={question.id} className="flex flex-wrap items-start justify-between gap-2 px-3 py-2">
                            <div className="min-w-[240px]">
                              <div className="text-[13px]">問{question.ordinal}. {question.prompt}</div>
                              <div className="mt-1 text-[11px] text-[var(--muted)]">
                                {ANSWER_TYPE_LABEL[question.answer_type] ?? question.answer_type}
                                {question.required ? ' · 必須' : ' · 任意'}
                                {Array.isArray(question.options) && question.options.length > 0
                                  ? ` · 選択肢: ${(question.options as unknown[]).map(String).join(' / ')}` : ''}
                              </div>
                            </div>
                            <form action={removeTemplateQuestion}>
                              {modeInput}
                              <input type="hidden" name="template_id" value={selectedTemplate.id} />
                              <input type="hidden" name="question_id" value={question.id} />
                              <button className="btn px-2 py-1 text-[11px]" type="submit">削除</button>
                            </form>
                          </li>
                        ))}
                      </ul>
                      <form action={addTemplateQuestion} className="grid gap-2 border-t border-[var(--border)] bg-[var(--surface-2)] p-3 md:grid-cols-2">
                        {modeInput}
                        <input type="hidden" name="template_id" value={selectedTemplate.id} />
                        <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">設問
                          <input className="input" name="prompt" placeholder="貴社の情報セキュリティ責任者・連絡窓口を教えてください。" required />
                        </label>
                        <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">回答形式
                          <select className="input" name="answer_type" defaultValue="text">
                            {Object.entries(ANSWER_TYPE_LABEL).map(([key, label]) => <option key={key} value={key}>{label}</option>)}
                          </select>
                        </label>
                        <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">選択肢（1行に1つ・選択式のときのみ）
                          <textarea className="input min-h-16" name="options" placeholder={'実施している\n実施していない\n該当しない'} />
                        </label>
                        <label className="flex items-center gap-2 text-[12px] text-[var(--muted)] md:col-span-2">
                          <input type="checkbox" name="required" defaultChecked /> 必須回答にする
                        </label>
                        <div className="md:col-span-2"><button className="btn btn-primary" type="submit">設問を追加</button></div>
                      </form>
                    </div>

                    <form action={createQuestionnaire} className="grid gap-2 rounded-[var(--radius)] border border-[var(--accent-line)] bg-[var(--accent-weak)] p-3 md:grid-cols-2">
                      {modeInput}
                      <input type="hidden" name="template_id" value={selectedTemplate.id} />
                      <h3 className="text-[13px] font-medium md:col-span-2">このテンプレートから質問票を作る</h3>
                      <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">送付先の外部リソース
                        <select className="input" name="vendor_id" required>
                          <option value="">選択してください</option>
                          {data.vendors.map((vendor) => (
                            <option key={vendor.id} value={vendor.id}>
                              {vendor.name}{vendor.service_name ? ` / ${vendor.service_name}` : ''}
                            </option>
                          ))}
                        </select>
                      </label>
                      <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">質問票タイトル
                        <input className="input" name="title" defaultValue={selectedTemplate.name} required />
                      </label>
                      <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">回答担当者
                        <input className="input" name="recipient_name" placeholder="情報システム部 ご担当者" />
                      </label>
                      <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">送付先メールアドレス
                        <input className="input" name="recipient_email" type="email" required />
                      </label>
                      <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">回答期限
                        <input className="input" name="due_date" type="date" />
                      </label>
                      <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">目的
                        <input className="input" name="purpose" defaultValue={selectedTemplate.purpose} />
                      </label>
                      <div className="md:col-span-2">
                        <button className="btn btn-primary" type="submit" disabled={data.vendors.length === 0}>質問票を作成する</button>
                        {data.vendors.length === 0 && <span className="ml-2 text-[12px] text-[var(--muted)]">先に外部リソースを登録してください。</span>}
                      </div>
                    </form>
                  </div>
                )}
              </div>
            </div>
          </section>
        )}

        <section className="card overflow-x-auto">
          <div className="border-b border-[var(--border)] px-4 py-3">
            <h2 className="text-[15px] font-semibold">質問票と送付状況</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">
              送付はメール送信キューに積まれ、配信ワーカーが実送信します。送信の成否はここに出ます。
            </p>
          </div>
          <table className="min-w-[1040px] w-full border-collapse text-[13px]">
            <thead>
              <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                <th className="px-4 py-2 font-medium">質問票</th>
                <th className="px-4 py-2 font-medium">対象</th>
                <th className="px-4 py-2 font-medium">送付先</th>
                <th className="px-4 py-2 font-medium">期限</th>
                <th className="px-4 py-2 font-medium">状態</th>
                <th className="px-4 py-2 font-medium">送信</th>
              </tr>
            </thead>
            <tbody>
              {data.questionnaires.length === 0 ? (
                <tr><td className="px-4 py-8 text-[var(--muted)]" colSpan={6}>質問票はまだありません。</td></tr>
              ) : data.questionnaires.map((questionnaire) => (
                <tr key={questionnaire.id} className="border-b border-[var(--border)] align-top last:border-0">
                  <td className="px-4 py-3">
                    <Link className="font-medium underline underline-offset-2" href={withMode(`/operations/external-resources/${questionnaire.id}`)}>
                      {questionnaire.title}
                    </Link>
                    <div className="text-[11px] text-[var(--muted)]">
                      {questionnaire.question_count}問 · 回答 {questionnaire.answered_count}件
                      {questionnaire.template_name ? ` · 雛形: ${questionnaire.template_name}` : ''}
                    </div>
                  </td>
                  <td className="px-4 py-3">{questionnaire.vendor_name}</td>
                  <td className="px-4 py-3">
                    {questionnaire.recipient_name || '—'}
                    <div className="text-[11px] text-[var(--muted)]">{questionnaire.recipient_email}</div>
                  </td>
                  <td className="px-4 py-3 tabular-nums text-[var(--muted)]">{questionnaire.due_date || '—'}</td>
                  <td className="px-4 py-3">
                    <span className={`badge ${statusBadge(questionnaire.status)}`}>
                      {QUESTIONNAIRE_STATUS_LABEL[questionnaire.status] ?? questionnaire.status}
                    </span>
                  </td>
                  <td className="px-4 py-3">
                    {questionnaire.delivery_status ? (
                      <>
                        <span className={`badge ${questionnaire.delivery_status === 'failed' ? 'badge-danger' : questionnaire.delivery_status === 'sent' ? 'badge-done' : 'badge-on-hold'}`}>
                          {DELIVERY_STATUS_LABEL[questionnaire.delivery_status] ?? questionnaire.delivery_status}
                        </span>
                        {questionnaire.delivery_error && (
                          <div className="mt-1 max-w-[220px] text-[11px] text-[var(--badge-danger-fg)]">{questionnaire.delivery_error}</div>
                        )}
                      </>
                    ) : <span className="text-[12px] text-[var(--muted)]">未送付</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      </>}
    </div>
  );
}
