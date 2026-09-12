import Link from 'next/link';
import {
  ASSIGNMENT_ROLE_LABEL,
  ASSIGNMENT_STATUS_LABEL,
  getAssignmentWorkspace,
  MANAGEMENT_ROLE_LABEL,
  RESOURCE_TYPE_LABEL,
  RESOURCE_TYPES_FOR_WORK,
  WORK_TYPE_LABEL,
  type AssignmentRow,
  type AssignmentWorkspace,
  type MemberOption,
} from '@/lib/workAssignments';
import {
  addAssignees, cancelAssignment, saveAssignment, updateAssignment, removeAssignee,
} from './actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: '依頼・アサイン' };

type SearchParams = Promise<Record<string, string | string[] | undefined>>;

const ERROR_LABEL: Record<string, string> = {
  invalid_session: 'セッションが無効です。ページを再読み込みしてください。',
  no_token: 'テナントセッションが必要です。',
  no_assignee: '担当メンバーまたは部門を 1 つ以上選んでください。',
  empty_department: '選んだ部門に在籍しているメンバーがいません。',
  last_assignee: '最後の 1 人は外せません。作業ごと取り消してください。',
  not_found: '対象の作業が見つからないか、既に完了・取消済みです。',
  invalid_input: '入力内容を確認してください。',
};

function first(value: string | string[] | undefined): string {
  return Array.isArray(value) ? value[0] ?? '' : value ?? '';
}

function workTypeUrl(type: string, mode: string): string {
  const query = mode ? `?mode=${encodeURIComponent(mode)}` : '';
  if (type === 'asset_inventory') return `/risk-management/assets${query}`;
  if (type === 'risk_assessment') return `/risk-management/risks${query}`;
  if (type === 'incident_response') return `/incidents${query}`;
  if (type === 'training_execution') return `/training${query}`;
  if (type === 'external_resource_review') return `/operations/external-resources${query}`;
  return `/operations/assignments${query}`;
}

function statusBadge(status: string): string {
  if (status === 'completed') return 'badge-done';
  if (status === 'declined' || status === 'cancelled') return 'badge-danger';
  return 'badge-on-hold';
}

/** Group assignee candidates by permission. Show who is a manager at the time of choosing. */
function memberGroups(users: MemberOption[]) {
  const order = ['owner', 'admin', 'manager', 'member', 'none'] as const;
  return order
    .map((role) => ({ role, users: users.filter((user) => user.role === role) }))
    .filter((group) => group.users.length > 0);
}

function AssigneePicker({ data, idPrefix }: {
  data: AssignmentWorkspace;
  idPrefix: string;
}) {
  return (
    <>
      <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">担当メンバー
        <select className="input min-h-32" name="assignee_user_id" id={`${idPrefix}-users`} multiple>
          {memberGroups(data.users).map((group) => (
            <optgroup key={group.role} label={MANAGEMENT_ROLE_LABEL[group.role]}>
              {group.users.map((user) => (
                <option key={user.id} value={user.id}>
                  {user.display_name}{user.department_name ? `（${user.department_name}）` : ''}
                </option>
              ))}
            </optgroup>
          ))}
        </select>
        <span className="text-[11px]">複数選択可（Mac: ⌘ / Windows: Ctrl）。監査人は業務データを変更しないため候補に出しません。</span>
      </label>
      <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">部門ごと依頼
        <select className="input min-h-32" name="department_id" id={`${idPrefix}-departments`} multiple>
          {data.departments.map((department) => (
            <option key={department.id} value={department.id} disabled={department.active_member_count === 0}>
              {department.name}（在籍{department.active_member_count}名
              {department.owner_name ? ` / 責任者 ${department.owner_name}` : ''}）
            </option>
          ))}
        </select>
        <span className="text-[11px]">選んだ時点の在籍メンバーへ展開します。後から部門構成が変わっても担当は増減しません。</span>
      </label>
    </>
  );
}

export default async function AssignmentsPage({ searchParams }: { searchParams: SearchParams }) {
  const sp = await searchParams;
  const mode = first(sp.mode);
  const scope = first(sp.scope) === 'mine' ? 'mine' : 'all';
  const workType = first(sp.work_type);
  const error = first(sp.error);
  const result = await getAssignmentWorkspace({ scope, workType });
  const data = result.ok ? result.data : null;

  const linkFor = (next: Record<string, string>) => {
    const params = new URLSearchParams();
    if (mode) params.set('mode', mode);
    if (scope === 'mine') params.set('scope', 'mine');
    if (workType) params.set('work_type', workType);
    for (const [key, value] of Object.entries(next)) {
      if (value) params.set(key, value); else params.delete(key);
    }
    const query = params.toString();
    return query ? `/operations/assignments?${query}` : '/operations/assignments';
  };

  const hiddenContext = (
    <>
      {mode === 'isms' || mode === 'risk' ? <input type="hidden" name="mode" value={mode} /> : null}
      {scope === 'mine' ? <input type="hidden" name="scope" value="mine" /> : null}
    </>
  );

  return (
    <div className="flex flex-col gap-5">
      <header>
        <div className="flex flex-wrap items-center gap-2">
          <span className="badge badge-note">作業依頼</span>
          {data ? <span className="badge">現在の権限: {MANAGEMENT_ROLE_LABEL[data.role]}</span> : null}
        </div>
        <h1 className="mt-2 text-[22px] font-semibold tracking-tight">依頼・アサイン</h1>
        <p className="mt-1 max-w-[900px] text-[13px] leading-6 text-[var(--muted)]">
          資産棚卸し、リスクアセスメント、インシデント対応、教育・訓練などの作業を、
          個人・部門・特定のレコード単位でメンバーやマネージャーへ依頼します。
          依頼先の候補は<Link className="underline underline-offset-2" href={mode ? `/organization?mode=${mode}` : '/organization'}>組織・メンバー管理</Link>で在籍にしたメンバーです。
        </p>
      </header>

      {first(sp.saved) === '1' && <div className="card border-[var(--success)] bg-[var(--success-weak)] p-4 text-sm">依頼を保存しました。通知を選んだ場合は送信キューへ積まれます。</div>}
      {error && (
        <div className="card border-[var(--danger)] bg-[var(--danger-weak)] p-4 text-sm">
          {ERROR_LABEL[error] ?? `保存できませんでした。原因区分: ${error}`}
        </div>
      )}

      {!data ? <div className="card p-5 text-[13px] text-[var(--muted)]">テナントセッションまたは信頼済みの利用者識別が必要です。</div> : (
        <>
          <nav className="flex flex-wrap items-center gap-2">
            <Link className={`btn px-3 py-1.5 text-[12px] ${scope === 'all' ? 'btn-primary' : ''}`} href={linkFor({ scope: '' })}>
              すべての作業（{data.totalCount}）
            </Link>
            <Link className={`btn px-3 py-1.5 text-[12px] ${scope === 'mine' ? 'btn-primary' : ''}`} href={linkFor({ scope: 'mine' })}>
              自分の担当（{data.mineCount}）
            </Link>
            <span className="ms-2 text-[12px] text-[var(--muted)]">絞り込み:</span>
            <Link className={`badge ${workType === '' ? 'badge-note' : ''}`} href={linkFor({ work_type: '' })}>すべての種別</Link>
            {data.workTypes.map((type) => (
              <Link key={type.value} className={`badge ${workType === type.value ? 'badge-note' : ''}`} href={linkFor({ work_type: type.value })}>
                {type.label}
              </Link>
            ))}
          </nav>

          {data.canManage && (
            <section className="card p-5">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <h2 className="text-[15px] font-semibold">新しい作業を依頼</h2>
                  <p className="mt-1 text-[12px] text-[var(--muted)]">
                    まず作業種別を選ぶと、その種別に対応する台帳のレコードを対象に指定できます。
                  </p>
                </div>
                <Link className="btn px-3 py-1.5 text-[12px]" href={mode ? `/operations/access?mode=${mode}` : '/operations/access'}>権限を管理</Link>
              </div>

              <form method="get" className="mt-4 flex flex-wrap items-end gap-2">
                {mode === 'isms' || mode === 'risk' ? <input type="hidden" name="mode" value={mode} /> : null}
                {scope === 'mine' ? <input type="hidden" name="scope" value="mine" /> : null}
                <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">作業種別
                  <select className="input" name="work_type" defaultValue={data.selectedWorkType}>
                    <option value="">作業種別を選択</option>
                    {data.workTypes.map((type) => <option key={type.value} value={type.value}>{type.label}</option>)}
                  </select>
                </label>
                <button className="btn" type="submit">この種別で依頼する</button>
              </form>

              {!data.selectedWorkType ? (
                <p className="mt-3 text-[12px] text-[var(--muted)]">作業種別を選ぶと入力欄が開きます。</p>
              ) : (
                <form action={saveAssignment} className="mt-4 grid gap-3 md:grid-cols-2">
                  {hiddenContext}
                  <input type="hidden" name="work_type" value={data.selectedWorkType} />
                  <div className="md:col-span-2 text-[12px] text-[var(--muted)]">
                    作業種別: <span className="font-medium text-[var(--fg)]">{WORK_TYPE_LABEL[data.selectedWorkType]}</span>
                  </div>
                  <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">作業タイトル
                    <input className="input" name="title" placeholder="2026年度の営業部 情報資産棚卸し" required />
                  </label>

                  {(RESOURCE_TYPES_FOR_WORK[data.selectedWorkType] ?? []).length > 0 && (
                    <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">対象レコード（任意）
                      <select className="input" name="target" defaultValue="">
                        <option value="">指定しない（作業全体への依頼）</option>
                        {data.targets.map((target) => (
                          <option key={`${target.resource_type}:${target.resource_id}`} value={`${target.resource_type}:${target.resource_id}`}>
                            [{RESOURCE_TYPE_LABEL[target.resource_type]}] {target.label}
                          </option>
                        ))}
                      </select>
                      <span className="text-[11px]">
                        {data.targets.length === 0
                          ? 'この種別に対応する台帳のレコードがまだありません。'
                          : '特定の資産・リスク・インシデント等について依頼する場合に選びます。'}
                      </span>
                    </label>
                  )}

                  <AssigneePicker data={data} idPrefix="new" />

                  <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">担当区分
                    <select className="input" name="assignment_role" defaultValue="editor">
                      {Object.entries(ASSIGNMENT_ROLE_LABEL).map(([key, label]) => <option key={key} value={key}>{label}</option>)}
                    </select>
                  </label>
                  <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">期限
                    <input className="input" name="due_date" type="date" />
                  </label>
                  <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">依頼内容
                    <textarea className="input min-h-20" name="instructions" placeholder="確認する項目、登録時の注意点、必要な証跡" />
                  </label>
                  <label className="flex items-center gap-2 text-[12px] text-[var(--muted)] md:col-span-2">
                    <input type="checkbox" name="notify" defaultChecked />
                    担当メンバーへ依頼メールを送る（送信キューへ積み、配信ワーカーが送ります）
                  </label>
                  <div className="md:col-span-2"><button className="btn btn-primary" type="submit">対応を依頼する</button></div>
                </form>
              )}
            </section>
          )}

          <section className="card overflow-hidden">
            <div className="border-b border-[var(--border)] px-4 py-3">
              <h2 className="text-[15px] font-semibold">{scope === 'mine' ? '自分の担当' : '作業台帳'}</h2>
              <p className="mt-1 text-[12px] text-[var(--muted)]">
                メンバーは自分の作業を、管理者・マネージャーは作業全体と担当者ごとの進捗を確認できます。
              </p>
            </div>
            {data.assignments.length === 0 ? (
              <p className="px-4 py-8 text-[13px] text-[var(--muted)]">
                {scope === 'mine' ? '自分が担当の作業はありません。' : '作業はまだありません。'}
              </p>
            ) : (
              <ul className="divide-y divide-[var(--border)]">
                {data.assignments.map((assignment) => (
                  <AssignmentCard
                    key={assignment.id}
                    assignment={assignment}
                    data={data}
                    mode={mode}
                    hiddenContext={hiddenContext}
                  />
                ))}
              </ul>
            )}
          </section>
        </>
      )}
    </div>
  );
}

function AssignmentCard({ assignment, data, mode, hiddenContext }: {
  assignment: AssignmentRow;
  data: AssignmentWorkspace;
  mode: string;
  hiddenContext: React.ReactNode;
}) {
  const open = assignment.status !== 'completed' && assignment.status !== 'cancelled';
  return (
    <li className="flex flex-col gap-3 p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-[280px]">
          <div className="flex flex-wrap items-center gap-2">
            <span className={`badge ${statusBadge(assignment.status)}`}>
              {ASSIGNMENT_STATUS_LABEL[assignment.status] ?? assignment.status}
            </span>
            <Link className="text-[12px] underline underline-offset-2" href={workTypeUrl(assignment.work_type, mode)}>
              {WORK_TYPE_LABEL[assignment.work_type]}
            </Link>
            {assignment.mine && <span className="badge badge-note">自分の担当</span>}
          </div>
          <h3 className="mt-1 text-[14px] font-medium">{assignment.title}</h3>
          {assignment.resource_type && (
            <p className="mt-1 text-[12px] text-[var(--muted)]">
              対象: [{RESOURCE_TYPE_LABEL[assignment.resource_type] ?? assignment.resource_type}]{' '}
              {assignment.resource_label ?? '（削除済みまたは参照できません）'}
            </p>
          )}
          <p className="mt-1 text-[12px] leading-5 text-[var(--muted)]">
            {assignment.instructions || '依頼内容の記載なし'}
          </p>
          <p className="mt-1 text-[11px] text-[var(--muted)]">
            依頼者: {assignment.requester_name ?? '—'} · 期限: {assignment.due_date ?? '指定なし'}
            {assignment.notified_count > 0 ? ` · 通知 ${assignment.notified_count}件をキューへ` : ''}
          </p>
        </div>

        {data.canManage && open && (
          <form action={cancelAssignment}>
            {hiddenContext}
            <input type="hidden" name="work_item_id" value={assignment.id} />
            <button className="btn px-3 py-1.5 text-[12px]" type="submit">この依頼を取り消す</button>
          </form>
        )}
      </div>

      <div className="overflow-x-auto">
        <table className="min-w-[620px] w-full border-collapse text-[12px]">
          <thead>
            <tr className="text-left text-[11px] text-[var(--muted)]">
              <th className="py-1 pr-3 font-medium">担当者</th>
              <th className="py-1 pr-3 font-medium">担当区分</th>
              <th className="py-1 pr-3 font-medium">状態</th>
              <th className="py-1 pr-3 font-medium">対応結果</th>
              {data.canManage && open && <th className="py-1 font-medium">解除</th>}
            </tr>
          </thead>
          <tbody>
            {assignment.assignees.map((assignee) => (
              <tr key={assignee.user_id} className="border-t border-[var(--border)] align-top">
                <td className="py-2 pr-3">
                  {assignee.display_name}
                  {assignee.department_name && <div className="text-[11px] text-[var(--muted)]">{assignee.department_name}</div>}
                </td>
                <td className="py-2 pr-3 text-[var(--muted)]">{ASSIGNMENT_ROLE_LABEL[assignee.assignment_role] ?? assignee.assignment_role}</td>
                <td className="py-2 pr-3">
                  <span className={`badge ${statusBadge(assignee.status)}`}>
                    {ASSIGNMENT_STATUS_LABEL[assignee.status] ?? assignee.status}
                  </span>
                </td>
                <td className="py-2 pr-3 text-[var(--muted)]">{assignee.completion_note || '—'}</td>
                {data.canManage && open && (
                  <td className="py-2">
                    <form action={removeAssignee}>
                      {hiddenContext}
                      <input type="hidden" name="work_item_id" value={assignment.id} />
                      <input type="hidden" name="assignee_user_id" value={assignee.user_id} />
                      <button className="btn px-2 py-1 text-[11px]" type="submit">外す</button>
                    </form>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="flex flex-wrap gap-3">
        {assignment.mine && open && (
          <details className="min-w-[280px]">
            <summary className="cursor-pointer text-[12px] underline underline-offset-2">自分の状態を更新</summary>
            <form action={updateAssignment} className="mt-2 grid gap-2 rounded-[var(--radius)] bg-[var(--surface-2)] p-3">
              {hiddenContext}
              <input type="hidden" name="work_item_id" value={assignment.id} />
              <input type="hidden" name="assignee_user_id" value={assignment.mine.user_id} />
              <select className="input" name="status" defaultValue={assignment.mine.status}>
                {Object.entries(ASSIGNMENT_STATUS_LABEL).map(([key, label]) => <option key={key} value={key}>{label}</option>)}
              </select>
              <textarea className="input" name="completion_note" defaultValue={assignment.mine.completion_note} placeholder="対応結果・証跡メモ" />
              <button className="btn btn-primary" type="submit">更新</button>
            </form>
          </details>
        )}

        {data.canManage && open && (
          <details className="min-w-[280px]">
            <summary className="cursor-pointer text-[12px] underline underline-offset-2">担当者を追加する</summary>
            <form action={addAssignees} className="mt-2 grid gap-2 rounded-[var(--radius)] bg-[var(--surface-2)] p-3">
              {hiddenContext}
              <input type="hidden" name="work_item_id" value={assignment.id} />
              <AssigneePicker data={data} idPrefix={`add-${assignment.id}`} />
              <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">担当区分
                <select className="input" name="assignment_role" defaultValue="editor">
                  {Object.entries(ASSIGNMENT_ROLE_LABEL).map(([key, label]) => <option key={key} value={key}>{label}</option>)}
                </select>
              </label>
              <label className="flex items-center gap-2 text-[12px] text-[var(--muted)]">
                <input type="checkbox" name="notify" defaultChecked />
                追加した人へ依頼メールを送る
              </label>
              <button className="btn btn-primary" type="submit">担当者を追加</button>
            </form>
          </details>
        )}
      </div>
    </li>
  );
}
