import Link from 'next/link';
import { canTakeException, nextFindingSteps } from '@/lib/findingFlow';
import { getRecordsActor, getRecordsWorkspace, LIST_LIMIT, type Person } from '@/lib/ismsRecords';
import {
  addReviewOutput, advanceFinding, approveException, approveReview, completeCorrective, evaluateObjective,
  assessLegalRequirement, cancelChange, decideChangeRequest, implementChange, progressVulnerability,
  reactivateContext, reactivateContinuityPlan, reactivateLegalRequirement, requestChange, updateChangeRequest,
  recordContinuityTest, retireContext, retireContinuityPlan, retireLegalRequirement, reviewContext, reviewCorrective,
  saveAudit, saveContextIssue, saveContinuityPlan, saveCorrective, saveEffectiveness, saveEvidence, saveFinding,
  saveInterestedParty, saveLegalRequirement, saveObjective, saveReview, saveVendorAssessment, saveVulnerability,
  updateContextIssue,
  updateContinuityPlan, updateInterestedParty, updateLegalRequirement,
} from './actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'ISMS の運用記録' };

// Internal audit (9.2), findings and corrective actions (10.2), management review (9.3), and control effectiveness evaluation (9.1) are
// entered from the screen (stage 1 of design doc 2026-09-11 §5). Stage 2 added information security objectives (6.2),
// supplier evaluation (A.5.19-5.22), manual evidence, and finding exceptions. Counts mean the same as on the stage screens:
// plans are not counted as implemented (only those with an implementation/meeting/evaluation date up to today are implemented).

const ERROR_LABEL: Record<string, string> = {
  forbidden: 'この記録を書く役割がありません',
  invalid_input: '入力を確かめてください',
  invalid_session: 'セッションが無効です。ページを開き直してください',
  no_token: 'テナントセッションが必要です',
  not_found: '対象が見つかりません',
  future_performed: '実施日に先の日付は入れられません（予定は予定日に入れてください）',
  future_evaluated: '評価日に先の日付は入れられません',
  not_completed: '処置が完了する前に有効性は確認できません',
  reviewer_is_owner: '処置の担当者は、自分の処置の有効性を確認できません（別の人が確認します）',
  not_verified: '検証が済んでいない指摘は完了にできません',
  review_exists_for_year: 'その年度のレビューはもうあります。一覧から開いて更新してください',
  not_held: '開催日が今日までに入っていないレビューの議事は承認できません',
  minutes_empty: '議事が空のレビューは承認できません',
  executive_required: '議事の承認は経営層（最高責任者）だけができます',
  already_approved: 'この議事はもう承認されています。議事を直すと改めて承認できます',
  objective_exists: '同じ年度に同じ名前の目的があります',
  future_assessed: '評価日に先の日付は入れられません',
  next_due_before_assessed: '次回の期限は評価日より後にしてください',
  future_collected: '収集日に先の日付は入れられません',
  expiry_not_future: '例外の期限は今日より後にしてください',
  expiry_too_far: '例外の期限は 1 年以内にしてください（期限のない受容にしないため）',
  finding_closed: '完了した指摘には例外を付けられません',
  finding_verified: '検証済みの指摘は是正が済んでいます。例外ではなく完了にしてください',
  already_exception: 'この指摘には期限内の例外（またはリスク受容）がもうあります',
  invalid_transition: 'その状態へは今の状態から進められません（検証済み・完了は戻せません）',
  not_auditor: '監査人には、監査人の役割を持つ有効な利用者を選んでください',
  context_exists: '同じ種類・同じ名前の課題があります（取り下げたものは一覧の「戻す」で戻せます）',
  party_exists: '同じ名前の利害関係者があります（取り下げたものは一覧の「戻す」で戻せます）',
  legal_exists: '同じ種類・同じ名前の要求事項があります（取り下げたものは一覧の「戻す」で戻せます）',
  inactive_user: '担当には、このテナントに所属する有効な利用者を選んでください',
  ref_unavailable: '結ぶ統制・証跡が見つからないか、取り下げ・削除されています',
  plan_exists: '同じ名前の計画があります（取り下げたものは一覧の「戻す」で戻せます）',
  future_tested: '試験の実施日に先の日付は入れられません（予定は計画の「次の試験期限」に入れてください）',
  future_detected: '検知日に先の日付は入れられません',
  due_before_detected: '対応期限は検知日より後にしてください',
  vuln_open_exists: '同じ識別子・同じ資産で、開いている記録がもうあります（閉じた後の再発なら新しく登録できます）',
  false_positive_reason: '誤検知にするときは、なぜ脆弱性でないかを書いてください',
  change_executive_required: '変更の承認・却下は経営層（最高責任者）だけができます',
  not_awaiting_decision: 'この申請はもう判断されています',
  requester_cannot_decide: '申請者は自分の申請を判断できません（別の経営層が判断します）',
  rejection_reason_required: '却下するときは理由を書いてください',
  change_not_editable: '中身を直せるのは申請中だけです（承認・却下した中身とずれないように）',
  next_review_not_after: '次の見直し日は今日より後にしてください',
  error: '保存できませんでした（委託先評価は、担当として割り当てられている必要があります）',
};

const SAVED_LABEL: Record<string, string> = {
  audits: '内部監査を保存しました',
  findings: '指摘を保存しました',
  corrective: '是正処置を保存しました',
  reviews: 'マネジメントレビューを保存しました',
  effectiveness: '有効性評価を保存しました',
  objectives: '情報セキュリティ目的を保存しました',
  vendors: '委託先評価を保存しました',
  evidences: '証跡を保存しました',
  exceptions: '例外を承認しました',
  context: '組織の課題を保存しました',
  parties: '利害関係者を保存しました',
  legal: '法令・契約上の要求事項を保存しました',
  continuity: '事業継続の記録を保存しました',
  vulnerabilities: '脆弱性を保存しました',
  changes: '変更の申請を保存しました',
};
const RISK_LEVEL_LABEL: Record<string, string> = { low: '低', medium: '中', high: '高' };
const CHANGE_STATUS_LABEL: Record<string, string> = {
  requested: '申請中', approved: '承認済み', rejected: '却下', implemented: '実施済み', cancelled: '取りやめ',
};
const VULN_SOURCE_LABEL: Record<string, string> = {
  scan: 'スキャン', advisory: 'ベンダー・公的機関の勧告', report: '報告・問い合わせ', pentest: '侵入試験', other: 'その他',
};
const VULN_STATUS_LABEL: Record<string, string> = {
  open: '検知', in_progress: '対応中', mitigated: '対処済み', false_positive: '誤検知',
};
const CONTINUITY_METHOD_LABEL: Record<string, string> = {
  tabletop: '机上演習', walkthrough: '手順の読み合わせ', simulation: '模擬（切り替えの試行）', full_interruption: '実際に止めて切り替え',
};
const CONTINUITY_RESULT_LABEL: Record<string, string> = {
  passed: '計画どおりできた', partially_passed: '一部できた', failed: 'できなかった',
};

const CONTEXT_KIND_LABEL: Record<string, string> = { external: '外部', internal: '内部' };
const PARTY_CATEGORY_LABEL: Record<string, string> = {
  customer: '顧客', regulator: '規制当局・行政', employee: '従業員', shareholder: '株主・出資者',
  supplier: '委託先・仕入先', partner: '取引先・提携先', other: 'その他',
};
const LEGAL_KIND_LABEL: Record<string, string> = {
  law: '法令', regulation: '規制・ガイドライン', contract: '契約', standard: '規格・業界基準', other: 'その他',
};
const COMPLIANCE_LABEL: Record<string, string> = {
  not_assessed: '未評価', compliant: '適合', partially_compliant: '一部適合', non_compliant: '不適合',
};

const VENDOR_RESULT_LABEL: Record<string, string> = {
  acceptable: '委託してよい', conditional: '条件付き', unacceptable: '委託できない',
};
const OBJECTIVE_STATUS_LABEL: Record<string, string> = {
  planned: '計画', in_progress: '進行中', achieved: '達成', not_achieved: '未達成', cancelled: '取消',
};

const ROLE_LABEL: Record<string, string> = {
  owner: 'オーナー（最高責任者）', admin: '管理者', manager: 'マネージャー', member: 'メンバー', auditor: '監査人', none: '役割なし',
};
const SEVERITY_LABEL: Record<string, string> = { critical: '重大', high: '高', medium: '中', low: '低' };
const FINDING_STATUS_LABEL: Record<string, string> = {
  detected: '検出', in_remediation: '是正中', remediated: '是正済み', retest_passed: '再確認合格',
  verified: '検証済み', closed: '完了', exception: '例外', risk_accepted: 'リスク受容',
};
const RESULT_LABEL: Record<string, string> = {
  effective: '有効', partially_effective: '一部有効', not_effective: '有効でない',
};

/** Tomorrow (JST). Used as the minimum for date fields where the server requires "after today". */
function tomorrow(): string {
  return new Date(Date.now() + 9 * 3600_000 + 86_400_000).toISOString().slice(0, 10);
}

function today(): string {
  return new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10);
}
function performedBadge(date: string | null) {
  if (!date) return <span className="badge badge-on-hold">未実施</span>;
  return date <= today() ? <span className="badge badge-done">実施済み</span> : <span className="badge badge-on-hold">予定</span>;
}

function PersonSelect({ name, people, required, placeholder }: { name: string; people: Person[]; required?: boolean; placeholder: string }) {
  return (
    <select className="input" name={name} required={required} defaultValue="">
      <option value="">{placeholder}</option>
      {people.map((p) => <option key={p.id} value={p.id}>{p.display_name}（{p.email}）</option>)}
    </select>
  );
}

/** When the list hits the limit, say so (do not silently hide older records). */
function Truncated({ shown, limit }: { shown: number; limit: number }) {
  if (shown < limit) return null;
  return (
    <p className="mt-1 text-[11px] text-[var(--muted)]">
      新しい順に {limit} 件だけ表示しています（段階の画面の件数はすべてを数えています）。
    </p>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="flex flex-col gap-1 text-[12px] text-[var(--fg-2)]">
      {label}
      {children}
    </label>
  );
}

export default async function IsmsRecordsPage({
  searchParams,
}: {
  searchParams: Promise<{ mode?: string; saved?: string; error?: string; field?: string }>;
}) {
  const sp = await searchParams;
  const mode = sp.mode === 'isms' || sp.mode === 'risk' ? sp.mode : 'isms';
  // Read records only when the user and role are verified (do not show audit records, minutes, or exception reasons to an unknown person).
  const actor = await getRecordsActor();
  const role = actor?.role ?? null;
  // The user viewing the screen (to align server checks with what the screen shows, e.g. not showing the decision field to the requester).
  const actorId = actor?.userId ?? null;
  const identified = role !== null && role !== 'none';
  const result = identified ? await getRecordsWorkspace() : null;
  const data = result?.ok ? result.data : null;
  const can = (roles: string[]) => role !== null && roles.includes(role);
  const hidden = <input type="hidden" name="mode" value={mode} />;

  return (
    <div className="flex flex-col gap-6">
      <div>
        <Link href={`/iso27001?mode=${mode}`} className="text-[12px] text-[var(--muted)] underline underline-offset-2">ISMS へ戻る</Link>
        <h1 className="mt-2 text-[21px] font-semibold">ISMS の運用記録</h1>
        <p className="mt-1 max-w-[860px] text-[13px] text-[var(--muted)]">
          内部監査・指摘と是正処置・マネジメントレビュー・統制の有効性評価・目的・委託先評価・証跡・例外・
          組織の課題・利害関係者を記録します。
          予定と実施は分けて数えます。実施日・開催日・評価日が今日までに入っている記録だけが「実施済み」です。
        </p>
        <p className="mt-2 text-[12px] text-[var(--fg-2)]">
          あなたの役割: <b>{role ? ROLE_LABEL[role] ?? role : '確認できません'}</b>
          <span className="ms-2 text-[var(--muted)]">書ける記録は役割で決まります（保存のときにも確かめます）。</span>
        </p>
      </div>

      {sp.saved && SAVED_LABEL[sp.saved] && (
        <section className="card border-[var(--success)] bg-[var(--success-weak)] p-4" role="status">
          <p className="text-sm font-semibold text-[var(--badge-success-fg)]">{SAVED_LABEL[sp.saved]}</p>
        </section>
      )}
      {sp.error && (
        <section className="card border-[var(--danger)] bg-[var(--danger-weak)] p-4" role="alert">
          <p className="text-sm font-semibold text-[var(--badge-danger-fg)]">{ERROR_LABEL[sp.error] ?? ERROR_LABEL.error}</p>
          {sp.field && <p className="mt-1 text-xs text-[var(--fg-2)]">項目: {sp.field}</p>}
        </section>
      )}

      {!data ? (
        <div className="card p-5 text-[13px] text-[var(--muted)]">
          {identified
            ? 'テナントセッションが必要です。記録が読める状態にありません。'
            : '本人と役割を確かめられないため、記録は表示しません。'}
        </div>
      ) : (
        <>
          {/* ---- Internal audit ---- */}
          <section id="audits" className="card p-5">
            <h2 className="text-[16px] font-semibold">内部監査（9.2）</h2>
            <Truncated shown={data.audits.length} limit={LIST_LIMIT.audits} />
            <p className="mt-1 text-[12px] text-[var(--muted)]">監査人・範囲・基準・予定日と実施日。実施日は今日までしか入れられません。</p>
            {data.audits.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだ監査の記録がありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[760px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">年度</th><th className="px-3 py-2 font-medium">範囲</th>
                    <th className="px-3 py-2 font-medium">監査人</th><th className="px-3 py-2 font-medium">予定日</th>
                    <th className="px-3 py-2 font-medium">実施日</th><th className="px-3 py-2 font-medium">状態</th>
                    <th className="px-3 py-2 font-medium">指摘</th>
                  </tr></thead>
                  <tbody>
                    {data.audits.map((a) => (
                      <tr key={a.id} className="border-b border-[var(--border)] last:border-0">
                        <td className="px-3 py-2">{a.fiscal_year}</td>
                        <td className="px-3 py-2">{a.scope}<div className="text-[11px] text-[var(--muted)]">基準: {a.criteria}</div></td>
                        <td className="px-3 py-2">{a.auditor_name ?? '—'}</td>
                        <td className="px-3 py-2">{a.planned_on ?? '—'}</td>
                        <td className="px-3 py-2">{a.performed_on ?? '—'}</td>
                        <td className="px-3 py-2">{performedBadge(a.performed_on)}</td>
                        <td className="px-3 py-2">{a.finding_count}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {can(['owner', 'admin', 'auditor']) && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">監査を追加する</summary>
                <form action={saveAudit} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="年度"><input className="input" name="fiscal_year" type="number" required defaultValue={new Date().getFullYear()} /></Field>
                  <Field label="監査人（監査人ロールの人）">
                    <PersonSelect name="auditor_user_id" people={data.auditors} required placeholder="選んでください" />
                  </Field>
                  <Field label="範囲"><input className="input" name="scope" required maxLength={4000} placeholder="例: 全社の ISMS（附属書 A 全統制）" /></Field>
                  <Field label="監査基準"><input className="input" name="criteria" required maxLength={4000} placeholder="例: JIS Q 27001:2023 と社内規程" /></Field>
                  <Field label="予定日"><input className="input" name="planned_on" type="date" /></Field>
                  <Field label="実施日（実施したときだけ）"><input className="input" name="performed_on" type="date" max={today()} /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">保存</button></div>
                </form>
                {data.auditors.length === 0 && (
                  <p className="mt-2 text-[12px] text-[var(--muted)]">監査人ロールの人がいません。組織・メンバー管理で監査人を割り当ててください。</p>
                )}
              </details>
            )}
          </section>

          {/* ---- Findings ---- */}
          <section id="findings" className="card p-5">
            <h2 className="text-[16px] font-semibold">指摘・不適合（10.2）</h2>
            <Truncated shown={data.findings.length} limit={LIST_LIMIT.findings} />
            <p className="mt-1 text-[12px] text-[var(--muted)]">検証と完了は、是正した人とは別の役割（オーナー・管理者）が行います。</p>
            {data.findings.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだ指摘の記録がありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[760px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">検出日</th><th className="px-3 py-2 font-medium">指摘</th>
                    <th className="px-3 py-2 font-medium">重大度</th><th className="px-3 py-2 font-medium">担当</th>
                    <th className="px-3 py-2 font-medium">期限</th><th className="px-3 py-2 font-medium">状態</th>
                    <th className="px-3 py-2 font-medium">進める</th>
                  </tr></thead>
                  <tbody>
                    {data.findings.map((f) => (
                      <tr key={f.id} className="border-b border-[var(--border)] align-top last:border-0">
                        <td className="px-3 py-2">{f.detected_at}</td>
                        <td className="px-3 py-2">{f.title}<div className="text-[11px] text-[var(--muted)]">{f.source === 'internal_audit' ? '内部監査' : f.source}</div></td>
                        <td className="px-3 py-2">{SEVERITY_LABEL[f.severity] ?? f.severity}</td>
                        <td className="px-3 py-2">{f.assignee_name ?? '—'}</td>
                        <td className="px-3 py-2">{f.due_date ?? '—'}</td>
                        <td className="px-3 py-2">{FINDING_STATUS_LABEL[f.status] ?? f.status}</td>
                        <td className="px-3 py-2">
                          {nextFindingSteps(f.status).length > 0 && (
                            <form action={advanceFinding} className="flex gap-2">
                              {hidden}
                              <input type="hidden" name="id" value={f.id} />
                              <select className="input" name="status" defaultValue="">
                                <option value="" disabled>状態</option>
                                {nextFindingSteps(f.status).map((s) => (
                                  <option key={s} value={s}>{FINDING_STATUS_LABEL[s]}</option>
                                ))}
                              </select>
                              <button className="btn px-2 py-1 text-[12px]" type="submit">更新</button>
                            </form>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {can(['owner', 'admin', 'auditor', 'manager']) && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">指摘を追加する</summary>
                <form action={saveFinding} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="監査（監査で出た指摘のとき）">
                    <select className="input" name="audit_id" defaultValue="">
                      <option value="">監査以外（不適合）</option>
                      {data.audits.map((a) => <option key={a.id} value={a.id}>{a.fiscal_year} {a.scope}</option>)}
                    </select>
                  </Field>
                  <Field label="重大度">
                    <select className="input" name="severity" defaultValue="medium">
                      {Object.entries(SEVERITY_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                    </select>
                  </Field>
                  <Field label="指摘"><input className="input" name="title" required maxLength={500} /></Field>
                  <Field label="担当"><PersonSelect name="assigned_to" people={data.people} placeholder="未定" /></Field>
                  <Field label="期限"><input className="input" name="due_date" type="date" /></Field>
                  <Field label="詳細"><textarea className="input" name="detail" rows={2} maxLength={4000} /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">保存</button></div>
                </form>
              </details>
            )}
          </section>

          {/* ---- Corrective actions ---- */}
          <section id="corrective" className="card p-5">
            <h2 className="text-[16px] font-semibold">是正処置（10.2）</h2>
            <Truncated shown={data.correctiveActions.length} limit={LIST_LIMIT.correctiveActions} />
            <p className="mt-1 text-[12px] text-[var(--muted)]">原因・処置・完了・有効性の確認まで。有効性は処置の完了後に、担当者とは別の人が確かめます。</p>
            {data.correctiveActions.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだ是正処置の記録がありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[820px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">指摘</th><th className="px-3 py-2 font-medium">原因と処置</th>
                    <th className="px-3 py-2 font-medium">担当</th><th className="px-3 py-2 font-medium">期限</th>
                    <th className="px-3 py-2 font-medium">完了</th><th className="px-3 py-2 font-medium">有効性</th>
                  </tr></thead>
                  <tbody>
                    {data.correctiveActions.map((c) => (
                      <tr key={c.id} className="border-b border-[var(--border)] align-top last:border-0">
                        <td className="px-3 py-2">{c.finding_title}</td>
                        <td className="px-3 py-2">原因: {c.root_cause}<div className="text-[12px]">処置: {c.action}</div></td>
                        <td className="px-3 py-2">{c.owner_name ?? '—'}</td>
                        <td className="px-3 py-2">{c.due_date ?? '—'}</td>
                        <td className="px-3 py-2">
                          {c.completed_at ?? (can(['owner', 'admin', 'manager']) ? (
                            <form action={completeCorrective}>{hidden}<input type="hidden" name="id" value={c.id} />
                              <button className="btn px-2 py-1 text-[12px]" type="submit">完了にする</button></form>
                          ) : '—')}
                        </td>
                        <td className="px-3 py-2">
                          {c.effectiveness_result ? (
                            <span>{RESULT_LABEL[c.effectiveness_result] ?? c.effectiveness_result}
                              <span className="block text-[11px] text-[var(--muted)]">{c.reviewer_name}・{c.effectiveness_reviewed_at}</span></span>
                          ) : c.completed_at && can(['owner', 'admin']) ? (
                            <form action={reviewCorrective} className="flex gap-2">{hidden}
                              <input type="hidden" name="id" value={c.id} />
                              <select className="input" name="result" defaultValue="effective">
                                <option value="effective">有効</option><option value="not_effective">有効でない</option>
                              </select>
                              <button className="btn px-2 py-1 text-[12px]" type="submit">確認</button>
                            </form>
                          ) : <span className="text-[var(--muted)]">未確認</span>}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {can(['owner', 'admin', 'manager']) && data.findings.length > 0 && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">是正処置を追加する</summary>
                <form action={saveCorrective} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="指摘">
                    <select className="input" name="finding_id" required defaultValue="">
                      <option value="" disabled>選んでください</option>
                      {data.findings.map((f) => <option key={f.id} value={f.id}>{f.title}</option>)}
                    </select>
                  </Field>
                  <Field label="担当"><PersonSelect name="owner_user_id" people={data.people} placeholder="未定" /></Field>
                  <Field label="原因"><textarea className="input" name="root_cause" required rows={2} maxLength={4000} /></Field>
                  <Field label="処置"><textarea className="input" name="action" required rows={2} maxLength={4000} /></Field>
                  <Field label="期限"><input className="input" name="due_date" type="date" /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">保存</button></div>
                </form>
              </details>
            )}
          </section>

          {/* ---- Management review ---- */}
          <section id="reviews" className="card p-5">
            <h2 className="text-[16px] font-semibold">マネジメントレビュー（9.3）</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">年度に 1 回。開催日が今日までに入り、議事がある記録を経営層が承認します。承認は議事の中身に結び付くので、議事を直すと改めて承認が要ります。</p>
            {data.reviews.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだレビューの記録がありません。</p>
            ) : data.reviews.map((r) => (
              <article key={r.id} className="mt-4 rounded-md border border-[var(--border)] p-4">
                <div className="flex flex-wrap items-center gap-3">
                  <b>{r.fiscal_year} 年度</b>
                  <span className="text-[12px]">開催日: {r.held_on ?? '未定'}</span>
                  {performedBadge(r.held_on)}
                  <span className="text-[12px]">主宰: {r.chair_name ?? '—'}</span>
                  {r.approved_count > 0
                    ? <span className="badge badge-done">承認済み（最新 {r.last_approved_at}）</span>
                    : <span className="badge badge-on-hold">未承認</span>}
                </div>
                <pre className="mt-2 whitespace-pre-wrap text-[12px] text-[var(--fg-2)]">{r.minutes_md || '（議事なし）'}</pre>
                {r.outputs.length > 0 && (
                  <ul className="mt-2 list-disc pl-5 text-[12px]">
                    {r.outputs.map((o) => <li key={o.id}>{o.decision}（{o.owner_name ?? '—'}・期限 {o.due_date}・{o.status}）</li>)}
                  </ul>
                )}
                {can(['owner', 'admin']) && (
                  <div className="mt-3 grid gap-3 lg:grid-cols-3">
                    <details><summary className="cursor-pointer text-[12px] font-semibold">議事を更新</summary>
                      <form action={saveReview} className="mt-2 flex flex-col gap-2">{hidden}
                        <input type="hidden" name="id" value={r.id} />
                        <input type="hidden" name="fiscal_year" value={r.fiscal_year} />
                        <Field label="開催日"><input className="input" name="held_on" type="date" defaultValue={r.held_on ?? ''} /></Field>
                        <Field label="主宰"><PersonSelect name="chaired_by" people={data.people} placeholder="未定" /></Field>
                        <Field label="議事"><textarea className="input" name="minutes_md" rows={4} defaultValue={r.minutes_md} /></Field>
                        <button className="btn px-3 py-1.5 text-[12px]" type="submit">保存</button>
                      </form></details>
                    <details><summary className="cursor-pointer text-[12px] font-semibold">決定事項を追加</summary>
                      <form action={addReviewOutput} className="mt-2 flex flex-col gap-2">{hidden}
                        <input type="hidden" name="review_id" value={r.id} />
                        <Field label="決定事項"><input className="input" name="decision" required maxLength={4000} /></Field>
                        <Field label="担当"><PersonSelect name="owner_user_id" people={data.people} required placeholder="選んでください" /></Field>
                        <Field label="期限"><input className="input" name="due_date" type="date" required /></Field>
                        <button className="btn px-3 py-1.5 text-[12px]" type="submit">追加</button>
                      </form></details>
                    {role === 'owner' && (
                      <form action={approveReview} className="flex flex-col gap-2">{hidden}
                        <input type="hidden" name="review_id" value={r.id} />
                        <Field label="承認のコメント（任意）"><input className="input" name="comment" maxLength={2000} /></Field>
                        <button className="btn btn-primary px-3 py-1.5 text-[12px]" type="submit">議事を承認する</button>
                      </form>
                    )}
                  </div>
                )}
              </article>
            ))}
            {can(['owner', 'admin']) && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">レビューを追加する</summary>
                <form action={saveReview} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="年度"><input className="input" name="fiscal_year" type="number" required defaultValue={new Date().getFullYear()} /></Field>
                  <Field label="開催日（予定でも可。数えるのは今日までの開催だけ）"><input className="input" name="held_on" type="date" /></Field>
                  <Field label="主宰"><PersonSelect name="chaired_by" people={data.people} placeholder="未定" /></Field>
                  <Field label="議事"><textarea className="input" name="minutes_md" rows={3} maxLength={100000} /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">保存</button></div>
                </form>
              </details>
            )}
          </section>

          {/* ---- Effectiveness evaluation ---- */}
          <section id="effectiveness" className="card p-5">
            <h2 className="text-[16px] font-semibold">統制の有効性評価（9.1）</h2>
            <Truncated shown={data.effectiveness.length} limit={LIST_LIMIT.effectiveness} />
            <p className="mt-1 text-[12px] text-[var(--muted)]">統制を実施したことと、効いていることは別。何をもって有効とみなしたか（判定基準）と一緒に残します。</p>
            {data.effectiveness.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだ有効性評価の記録がありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[760px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">評価日</th><th className="px-3 py-2 font-medium">施策</th>
                    <th className="px-3 py-2 font-medium">判定基準</th><th className="px-3 py-2 font-medium">結果</th>
                    <th className="px-3 py-2 font-medium">評価者</th>
                  </tr></thead>
                  <tbody>
                    {data.effectiveness.map((e) => (
                      <tr key={e.id} className="border-b border-[var(--border)] align-top last:border-0">
                        <td className="px-3 py-2">{e.evaluated_on}</td>
                        <td className="px-3 py-2">{e.measure_key} {e.measure_name}</td>
                        <td className="px-3 py-2">{e.criteria}{e.evidence_note && <div className="text-[11px] text-[var(--muted)]">証跡: {e.evidence_note}</div>}</td>
                        <td className="px-3 py-2">{RESULT_LABEL[e.result] ?? e.result}</td>
                        <td className="px-3 py-2">{e.evaluator_name ?? '—'}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {can(['owner', 'admin']) && data.measures.length === 0 && (
              <p className="mt-4 text-[12px] text-[var(--muted)]">
                評価する施策（統制）がまだありません。
                <Link className="underline underline-offset-2" href={`/risk-management/measures?mode=${mode}`}>施策の台帳</Link>
                で登録してから評価します。
              </p>
            )}
            {can(['owner', 'admin']) && data.measures.length > 0 && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">有効性評価を追加する</summary>
                <form action={saveEffectiveness} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="施策（統制）">
                    <select className="input" name="measure_id" required defaultValue="">
                      <option value="" disabled>選んでください</option>
                      {data.measures.map((m) => <option key={m.id} value={m.id}>{m.measure_key} {m.name}</option>)}
                    </select>
                  </Field>
                  <Field label="評価日"><input className="input" name="evaluated_on" type="date" required max={today()} defaultValue={today()} /></Field>
                  <Field label="判定基準（何をもって有効とみなすか）"><textarea className="input" name="criteria" required rows={2} maxLength={4000} /></Field>
                  <Field label="結果">
                    <select className="input" name="result" defaultValue="effective">
                      {Object.entries(RESULT_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                    </select>
                  </Field>
                  <Field label="証跡の所在（任意）"><input className="input" name="evidence_note" maxLength={4000} /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">保存</button></div>
                </form>
              </details>
            )}
          </section>
          {/* ---- Information security objectives ---- */}
          <section id="objectives" className="card p-5">
            <h2 className="text-[16px] font-semibold">情報セキュリティ目的（6.2）</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">測れる目的だけを立てます。測り方は必須。達成の評価は実測値と一緒に残します。</p>
            {data.objectives.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだ目的の記録がありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[820px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">年度</th><th className="px-3 py-2 font-medium">目的</th>
                    <th className="px-3 py-2 font-medium">測り方・目標</th><th className="px-3 py-2 font-medium">担当・期限</th>
                    <th className="px-3 py-2 font-medium">状態</th><th className="px-3 py-2 font-medium">評価</th>
                  </tr></thead>
                  <tbody>
                    {data.objectives.map((o) => (
                      <tr key={o.id} className="border-b border-[var(--border)] align-top last:border-0">
                        <td className="px-3 py-2">{o.fiscal_year}</td>
                        <td className="px-3 py-2">{o.title}{o.description && <div className="text-[11px] text-[var(--muted)]">{o.description}</div>}</td>
                        <td className="px-3 py-2">{o.measure_how}{o.target_value && <div className="text-[11px]">目標: {o.target_value}</div>}</td>
                        <td className="px-3 py-2">{o.owner_name ?? '—'}<div className="text-[11px] text-[var(--muted)]">{o.due_date ?? '期限なし'}</div></td>
                        <td className="px-3 py-2">{OBJECTIVE_STATUS_LABEL[o.status] ?? o.status}</td>
                        <td className="px-3 py-2">
                          {o.evaluated_at ? (
                            <span>実測: {o.achieved_value}<span className="block text-[11px] text-[var(--muted)]">{o.evaluator_name}・{o.evaluated_at}</span></span>
                          ) : can(['owner', 'admin']) && o.status !== 'cancelled' ? (
                            <form action={evaluateObjective} className="flex flex-col gap-1">{hidden}
                              <input type="hidden" name="id" value={o.id} />
                              <input className="input" name="achieved_value" required maxLength={500} placeholder="実測値" />
                              <select className="input" name="status" defaultValue="achieved">
                                <option value="achieved">達成</option><option value="not_achieved">未達成</option>
                              </select>
                              <button className="btn px-2 py-1 text-[12px]" type="submit">評価する</button>
                            </form>
                          ) : <span className="text-[var(--muted)]">未評価</span>}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {can(['owner', 'admin']) && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">目的を追加する</summary>
                <form action={saveObjective} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="年度"><input className="input" name="fiscal_year" type="number" required defaultValue={new Date().getFullYear()} /></Field>
                  <Field label="目的"><input className="input" name="title" required maxLength={300} /></Field>
                  <Field label="測り方（必須）"><textarea className="input" name="measure_how" required rows={2} maxLength={4000} /></Field>
                  <Field label="目標値"><input className="input" name="target_value" maxLength={500} /></Field>
                  <Field label="担当"><PersonSelect name="owner_user_id" people={data.people} placeholder="未定" /></Field>
                  <Field label="期限"><input className="input" name="due_date" type="date" /></Field>
                  <Field label="説明"><textarea className="input" name="description" rows={2} maxLength={4000} /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">保存</button></div>
                </form>
              </details>
            )}
          </section>

          {/* ---- Supplier evaluation ---- */}
          <section id="vendors" className="card p-5">
            <h2 className="text-[16px] font-semibold">委託先評価（A.5.19〜5.22）</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">
              委託先ごとの最新の評価と次回の期限。委託先そのものは
              <Link className="underline underline-offset-2" href={`/operations/external-resources?mode=${mode}`}>外部リソース</Link>
              で登録します。担当に割り当てられたメンバーも評価を書けます。
            </p>
            {data.vendors.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">委託先がまだありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[720px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">委託先</th><th className="px-3 py-2 font-medium">重要度</th>
                    <th className="px-3 py-2 font-medium">最新の評価</th><th className="px-3 py-2 font-medium">結果</th>
                    <th className="px-3 py-2 font-medium">次回の期限</th><th className="px-3 py-2 font-medium">評価の回数</th>
                  </tr></thead>
                  <tbody>
                    {data.vendors.map((v) => (
                      <tr key={v.id} className="border-b border-[var(--border)] last:border-0">
                        <td className="px-3 py-2">{v.name}{v.service_name && <div className="text-[11px] text-[var(--muted)]">{v.service_name}</div>}</td>
                        <td className="px-3 py-2">{v.criticality ?? '—'}</td>
                        <td className="px-3 py-2">{v.last_assessed_on ?? <span className="text-[var(--muted)]">未評価</span>}</td>
                        <td className="px-3 py-2">{v.last_result ? VENDOR_RESULT_LABEL[v.last_result] ?? v.last_result : '—'}</td>
                        <td className="px-3 py-2">
                          {v.next_due_on ?? '—'}
                          {v.next_due_on && v.next_due_on < today() && <span className="ms-1 badge badge-danger">期限切れ</span>}
                        </td>
                        <td className="px-3 py-2">{v.assessment_count}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {can(['owner', 'admin', 'manager', 'member']) && data.vendors.length > 0 && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">委託先を評価する</summary>
                <form action={saveVendorAssessment} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="委託先">
                    <select className="input" name="vendor_id" required defaultValue="">
                      <option value="" disabled>選んでください</option>
                      {data.vendors.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
                    </select>
                  </Field>
                  <Field label="評価日"><input className="input" name="assessed_on" type="date" required max={today()} defaultValue={today()} /></Field>
                  <Field label="結果">
                    <select className="input" name="result" defaultValue="acceptable">
                      {Object.entries(VENDOR_RESULT_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                    </select>
                  </Field>
                  <Field label="次回の期限"><input className="input" name="next_due_on" type="date" /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">保存</button></div>
                </form>
              </details>
            )}
          </section>

          {/* ---- Evidence ---- */}
          <section id="evidences" className="card p-5">
            <h2 className="text-[16px] font-semibold">証跡</h2>
            <Truncated shown={data.evidences.length} limit={LIST_LIMIT.evidences} />
            <p className="mt-1 text-[12px] text-[var(--muted)]">
              手作業で集めた証跡の所在（保管場所・URL）と鮮度。ファイルそのものはここに置きません。
              自動の証跡はチェックの実行が作ります。鮮度を過ぎたものは「古い」と出ます。
            </p>
            {data.evidences.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだ証跡の記録がありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[720px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">収集日</th><th className="px-3 py-2 font-medium">証跡</th>
                    <th className="px-3 py-2 font-medium">所在</th><th className="px-3 py-2 font-medium">種類</th>
                    <th className="px-3 py-2 font-medium">鮮度</th>
                  </tr></thead>
                  <tbody>
                    {data.evidences.map((e) => (
                      <tr key={e.id} className="border-b border-[var(--border)] last:border-0">
                        <td className="px-3 py-2">{e.collected_at}</td>
                        <td className="px-3 py-2">{e.title}</td>
                        <td className="px-3 py-2 break-all text-[12px]">{e.object_key ?? '—'}</td>
                        <td className="px-3 py-2">{e.kind === 'manual' ? '手作業' : e.kind === 'auto' ? '自動' : '半自動'}</td>
                        <td className="px-3 py-2">
                          {e.freshness_days} 日
                          {e.stale ? <span className="ms-1 badge badge-danger">古い</span> : e.state === 'valid' ? <span className="ms-1 badge badge-done">有効</span> : <span className="ms-1 badge badge-on-hold">{e.state}</span>}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {can(['owner', 'admin', 'manager']) && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">証跡を追加する</summary>
                <form action={saveEvidence} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="証跡"><input className="input" name="title" required maxLength={300} placeholder="例: 2026 年 9 月のアクセス権棚卸の記録" /></Field>
                  <Field label="所在（保管場所・URL）"><input className="input" name="object_key" required maxLength={1000} /></Field>
                  <Field label="収集日"><input className="input" name="collected_on" type="date" required max={today()} defaultValue={today()} /></Field>
                  <Field label="鮮度（日）"><input className="input" name="freshness_days" type="number" required min={1} max={3650} defaultValue={365} /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">保存</button></div>
                </form>
              </details>
            )}
          </section>

          {/* ---- Exceptions ---- */}
          <section id="exceptions" className="card p-5">
            <h2 className="text-[16px] font-semibold">指摘の例外</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">
              是正せずにリスクとして受け入れる指摘。経営層（最高責任者）だけが承認でき、代わりの統制と 1 年以内の期限が必要です。
              業務の逸脱（規程から外れる運用）は
              <Link className="underline underline-offset-2" href={`/operations?mode=${mode}`}>運用</Link>
              の逸脱のワークフローで扱います。
            </p>
            {data.exceptions.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">例外はありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[760px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">指摘</th><th className="px-3 py-2 font-medium">理由</th>
                    <th className="px-3 py-2 font-medium">代わりの統制</th><th className="px-3 py-2 font-medium">承認</th>
                    <th className="px-3 py-2 font-medium">期限</th>
                  </tr></thead>
                  <tbody>
                    {data.exceptions.map((x) => (
                      <tr key={x.id} className="border-b border-[var(--border)] align-top last:border-0">
                        <td className="px-3 py-2">{x.finding_title}</td>
                        <td className="px-3 py-2">{x.reason}</td>
                        <td className="px-3 py-2">{x.compensating_control}</td>
                        <td className="px-3 py-2">{x.approver_name ?? '—'}<div className="text-[11px] text-[var(--muted)]">{x.approved_at}</div></td>
                        <td className="px-3 py-2">{x.expires_at}{x.expired && <span className="ms-1 badge badge-danger">期限切れ</span>}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {role === 'owner' && data.findings.some((f) => canTakeException(f.status)) && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">例外を承認する</summary>
                <form action={approveException} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="指摘">
                    <select className="input" name="finding_id" required defaultValue="">
                      <option value="" disabled>選んでください</option>
                      {data.findings.filter((f) => canTakeException(f.status))
                        .map((f) => <option key={f.id} value={f.id}>{f.title}</option>)}
                    </select>
                  </Field>
                  <Field label="期限（1 年以内）"><input className="input" name="expires_on" type="date" required min={today()} /></Field>
                  <Field label="受け入れる理由"><textarea className="input" name="reason" required rows={2} maxLength={4000} /></Field>
                  <Field label="代わりの統制"><textarea className="input" name="compensating_control" required rows={2} maxLength={4000} /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">承認する</button></div>
                </form>
              </details>
            )}
          </section>

          {/* ---- Organizational issues (4.1) ---- */}
          <section id="context" className="card p-5">
            <h2 className="text-[16px] font-semibold">組織の課題（4.1）</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">
              ISMS の成果に影響する外部・内部の課題と、それが ISMS にどう効くか。見直したら見直した日を残します。
              使わなくなった課題は消さずに取り下げます（範囲やリスクを決めた経緯になるため）。
            </p>
            {data.contextIssues.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだ課題の記録がありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[820px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">種類</th><th className="px-3 py-2 font-medium">課題</th>
                    <th className="px-3 py-2 font-medium">ISMS への影響</th><th className="px-3 py-2 font-medium">担当</th>
                    <th className="px-3 py-2 font-medium">見直した日</th><th className="px-3 py-2 font-medium">操作</th>
                  </tr></thead>
                  <tbody>
                    {data.contextIssues.map((c) => (
                      <tr key={c.id} className={`border-b border-[var(--border)] align-top last:border-0 ${c.status === 'retired' ? 'text-[var(--muted)]' : ''}`}>
                        <td className="px-3 py-2">{CONTEXT_KIND_LABEL[c.kind] ?? c.kind}</td>
                        <td className="px-3 py-2">
                          {c.title}
                          {c.status === 'retired' && <span className="ms-1 badge badge-archived">取り下げ</span>}
                          {c.description && <div className="text-[11px] text-[var(--muted)]">{c.description}</div>}
                        </td>
                        <td className="px-3 py-2">{c.isms_impact}</td>
                        <td className="px-3 py-2">{c.owner_name ?? '—'}</td>
                        <td className="px-3 py-2">{c.reviewed_on ?? <span className="text-[var(--muted)]">未見直し</span>}</td>
                        <td className="px-3 py-2">
                          {c.status === 'active' && can(['owner', 'admin']) && (
                            <div className="flex flex-col gap-2">
                              <div className="flex gap-2">
                                <form action={reviewContext}>{hidden}
                                  <input type="hidden" name="target" value="issue" /><input type="hidden" name="id" value={c.id} />
                                  <button className="btn px-2 py-1 text-[12px]" type="submit">見直した</button>
                                </form>
                                <form action={retireContext}>{hidden}
                                  <input type="hidden" name="target" value="issue" /><input type="hidden" name="id" value={c.id} />
                                  <button className="btn px-2 py-1 text-[12px]" type="submit">取り下げる</button>
                                </form>
                              </div>
                              <details>
                                <summary className="cursor-pointer text-[12px]">直す</summary>
                                <form action={updateContextIssue} className="mt-2 flex min-w-[260px] flex-col gap-1">{hidden}
                                  <input type="hidden" name="id" value={c.id} />
                                  <select className="input" name="kind" defaultValue={c.kind} aria-label="種類">
                                    <option value="external">外部</option><option value="internal">内部</option>
                                  </select>
                                  <input className="input" name="title" required maxLength={300} defaultValue={c.title} aria-label="課題" />
                                  <textarea className="input" name="isms_impact" required rows={2} maxLength={4000} defaultValue={c.isms_impact} aria-label="ISMS への影響" />
                                  <textarea className="input" name="description" rows={2} maxLength={4000} defaultValue={c.description} aria-label="説明" />
                                  <select className="input" name="owner_user_id" defaultValue={c.owner_user_id ?? ''} aria-label="担当">
                                    <option value="">未定</option>
                                    {data.people.map((u) => <option key={u.id} value={u.id}>{u.display_name}（{u.email}）</option>)}
                                  </select>
                                  <button className="btn px-2 py-1 text-[12px]" type="submit">保存</button>
                                </form>
                              </details>
                            </div>
                          )}
                          {c.status === 'retired' && can(['owner', 'admin']) && (
                            <form action={reactivateContext}>{hidden}
                              <input type="hidden" name="target" value="issue" /><input type="hidden" name="id" value={c.id} />
                              <button className="btn px-2 py-1 text-[12px]" type="submit">戻す</button>
                            </form>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {can(['owner', 'admin']) && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">課題を追加する</summary>
                <form action={saveContextIssue} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="種類">
                    <select className="input" name="kind" defaultValue="external">
                      <option value="external">外部</option><option value="internal">内部</option>
                    </select>
                  </Field>
                  <Field label="課題"><input className="input" name="title" required maxLength={300} placeholder="例: 取引先からのセキュリティ要求の高まり" /></Field>
                  <Field label="ISMS への影響（必須）"><textarea className="input" name="isms_impact" required rows={2} maxLength={4000} /></Field>
                  <Field label="説明"><textarea className="input" name="description" rows={2} maxLength={4000} /></Field>
                  <Field label="担当"><PersonSelect name="owner_user_id" people={data.people} placeholder="未定" /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">保存</button></div>
                </form>
              </details>
            )}
          </section>

          {/* ---- Interested parties (4.2) ---- */}
          <section id="parties" className="card p-5">
            <h2 className="text-[16px] font-semibold">利害関係者（4.2）</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">
              利害関係者と、その情報セキュリティに関する要求。そのうち ISMS で扱うものも決めて書きます（空は「まだ決めていない」）。
            </p>
            {data.interestedParties.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだ利害関係者の記録がありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[860px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">分類</th><th className="px-3 py-2 font-medium">利害関係者</th>
                    <th className="px-3 py-2 font-medium">情報セキュリティに関する要求</th><th className="px-3 py-2 font-medium">ISMS で扱うもの</th>
                    <th className="px-3 py-2 font-medium">担当</th><th className="px-3 py-2 font-medium">見直した日</th>
                    <th className="px-3 py-2 font-medium">操作</th>
                  </tr></thead>
                  <tbody>
                    {data.interestedParties.map((p) => (
                      <tr key={p.id} className={`border-b border-[var(--border)] align-top last:border-0 ${p.status === 'retired' ? 'text-[var(--muted)]' : ''}`}>
                        <td className="px-3 py-2">{PARTY_CATEGORY_LABEL[p.category] ?? p.category}</td>
                        <td className="px-3 py-2">
                          {p.name}
                          {p.status === 'retired' && <span className="ms-1 badge badge-archived">取り下げ</span>}
                        </td>
                        <td className="px-3 py-2">{p.requirements}</td>
                        <td className="px-3 py-2">{p.addressed_in_isms || <span className="text-[var(--muted)]">未決定</span>}</td>
                        <td className="px-3 py-2">{p.owner_name ?? '—'}</td>
                        <td className="px-3 py-2">{p.reviewed_on ?? <span className="text-[var(--muted)]">未見直し</span>}</td>
                        <td className="px-3 py-2">
                          {p.status === 'active' && can(['owner', 'admin']) && (
                            <div className="flex flex-col gap-2">
                              <div className="flex gap-2">
                                <form action={reviewContext}>{hidden}
                                  <input type="hidden" name="target" value="party" /><input type="hidden" name="id" value={p.id} />
                                  <button className="btn px-2 py-1 text-[12px]" type="submit">見直した</button>
                                </form>
                                <form action={retireContext}>{hidden}
                                  <input type="hidden" name="target" value="party" /><input type="hidden" name="id" value={p.id} />
                                  <button className="btn px-2 py-1 text-[12px]" type="submit">取り下げる</button>
                                </form>
                              </div>
                              <details>
                                <summary className="cursor-pointer text-[12px]">直す</summary>
                                <form action={updateInterestedParty} className="mt-2 flex min-w-[260px] flex-col gap-1">{hidden}
                                  <input type="hidden" name="id" value={p.id} />
                                  <input className="input" name="name" required maxLength={300} defaultValue={p.name} aria-label="利害関係者" />
                                  <select className="input" name="category" defaultValue={p.category} aria-label="分類">
                                    {Object.entries(PARTY_CATEGORY_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                                  </select>
                                  <textarea className="input" name="requirements" required rows={2} maxLength={4000} defaultValue={p.requirements} aria-label="情報セキュリティに関する要求" />
                                  <textarea className="input" name="addressed_in_isms" rows={2} maxLength={4000} defaultValue={p.addressed_in_isms} aria-label="そのうち ISMS で扱うもの" />
                                  <select className="input" name="owner_user_id" defaultValue={p.owner_user_id ?? ''} aria-label="担当">
                                    <option value="">未定</option>
                                    {data.people.map((u) => <option key={u.id} value={u.id}>{u.display_name}（{u.email}）</option>)}
                                  </select>
                                  <button className="btn px-2 py-1 text-[12px]" type="submit">保存</button>
                                </form>
                              </details>
                            </div>
                          )}
                          {p.status === 'retired' && can(['owner', 'admin']) && (
                            <form action={reactivateContext}>{hidden}
                              <input type="hidden" name="target" value="party" /><input type="hidden" name="id" value={p.id} />
                              <button className="btn px-2 py-1 text-[12px]" type="submit">戻す</button>
                            </form>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {can(['owner', 'admin']) && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">利害関係者を追加する</summary>
                <form action={saveInterestedParty} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="利害関係者"><input className="input" name="name" required maxLength={300} placeholder="例: 主要顧客" /></Field>
                  <Field label="分類">
                    <select className="input" name="category" defaultValue="customer">
                      {Object.entries(PARTY_CATEGORY_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                    </select>
                  </Field>
                  <Field label="情報セキュリティに関する要求（必須）"><textarea className="input" name="requirements" required rows={2} maxLength={4000} /></Field>
                  <Field label="そのうち ISMS で扱うもの"><textarea className="input" name="addressed_in_isms" rows={2} maxLength={4000} /></Field>
                  <Field label="担当"><PersonSelect name="owner_user_id" people={data.people} placeholder="未定" /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">保存</button></div>
                </form>
              </details>
            )}
          </section>

          {/* ---- Legal, regulatory, and contractual requirements (A.5.31) ---- */}
          <section id="legal" className="card p-5">
            <h2 className="text-[16px] font-semibold">法令・規制・契約上の要求事項（A.5.31）</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">
              情報セキュリティに関係する法令・規制・契約上の要求と、それに応える統制・証跡。
              適合の評価は評価した日と評価者と一緒に残します。次の見直し日を過ぎたものは「見直し期限切れ」と出ます。
            </p>
            {data.legalRequirements.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだ要求事項の記録がありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[980px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">種類</th><th className="px-3 py-2 font-medium">要求事項</th>
                    <th className="px-3 py-2 font-medium">求めていること</th><th className="px-3 py-2 font-medium">応える統制・証跡</th>
                    <th className="px-3 py-2 font-medium">適合</th><th className="px-3 py-2 font-medium">次の見直し</th>
                    <th className="px-3 py-2 font-medium">評価・操作</th>
                  </tr></thead>
                  <tbody>
                    {data.legalRequirements.map((l) => (
                      <tr key={l.id} className={`border-b border-[var(--border)] align-top last:border-0 ${l.status === 'retired' ? 'text-[var(--muted)]' : ''}`}>
                        <td className="px-3 py-2">{LEGAL_KIND_LABEL[l.kind] ?? l.kind}</td>
                        <td className="px-3 py-2">
                          {l.title}
                          {l.status === 'retired' && <span className="ms-1 badge badge-archived">取り下げ</span>}
                          {l.source_ref && <div className="text-[11px] text-[var(--muted)]">{l.source_ref}</div>}
                        </td>
                        <td className="px-3 py-2">{l.requirement}</td>
                        <td className="px-3 py-2">
                          {l.measure_name ? <div>{l.measure_key} {l.measure_name}</div> : <div className="text-[var(--muted)]">統制なし</div>}
                          {l.evidence_title ? <div className="text-[11px]">証跡: {l.evidence_title}</div> : <div className="text-[11px] text-[var(--muted)]">証跡なし</div>}
                        </td>
                        <td className="px-3 py-2">
                          {COMPLIANCE_LABEL[l.compliance_status] ?? l.compliance_status}
                          {l.assessed_on && <div className="text-[11px] text-[var(--muted)]">{l.assessor_name}・{l.assessed_on}</div>}
                        </td>
                        <td className="px-3 py-2">
                          {l.next_review_on ?? '—'}
                          {l.status === 'active' && l.next_review_on && l.next_review_on < today() && (
                            <span className="ms-1 badge badge-danger">見直し期限切れ</span>
                          )}
                        </td>
                        <td className="px-3 py-2">
                          {l.status === 'active' && can(['owner', 'admin', 'manager']) && (
                            <div className="flex flex-col gap-2">
                              <form action={assessLegalRequirement} className="flex flex-col gap-1">{hidden}
                                <input type="hidden" name="id" value={l.id} />
                                {/* Use the current result as the default (so someone meaning to fix only the review date does not overwrite it with another result). If not yet evaluated, make them choose. */}
                                <select className="input" name="compliance_status" required
                                  defaultValue={l.compliance_status === 'not_assessed' ? '' : l.compliance_status}>
                                  <option value="" disabled>結果を選ぶ</option>
                                  <option value="compliant">適合</option>
                                  <option value="partially_compliant">一部適合</option>
                                  <option value="non_compliant">不適合</option>
                                </select>
                                <input className="input" name="next_review_on" type="date" min={tomorrow()} aria-label="次の見直し日" />
                                <button className="btn px-2 py-1 text-[12px]" type="submit">評価する</button>
                              </form>
                              <form action={retireLegalRequirement}>{hidden}
                                <input type="hidden" name="id" value={l.id} />
                                <button className="btn px-2 py-1 text-[12px]" type="submit">取り下げる</button>
                              </form>
                              <details>
                                <summary className="cursor-pointer text-[12px]">直す</summary>
                                <form action={updateLegalRequirement} className="mt-2 flex min-w-[260px] flex-col gap-1">{hidden}
                                  <input type="hidden" name="id" value={l.id} />
                                  <select className="input" name="kind" defaultValue={l.kind} aria-label="種類">
                                    {Object.entries(LEGAL_KIND_LABEL).map(([v, lab]) => <option key={v} value={v}>{lab}</option>)}
                                  </select>
                                  <input className="input" name="title" required maxLength={300} defaultValue={l.title} aria-label="要求事項" />
                                  <textarea className="input" name="requirement" required rows={2} maxLength={4000} defaultValue={l.requirement} aria-label="求めていること" />
                                  <input className="input" name="source_ref" maxLength={500} defaultValue={l.source_ref} aria-label="原文の場所" />
                                  <select className="input" name="measure_id" defaultValue={l.measure_id ?? ''} aria-label="応える統制">
                                    <option value="">結ばない</option>
                                    {data.measures.map((m) => <option key={m.id} value={m.id}>{m.measure_key} {m.name}</option>)}
                                  </select>
                                  <select className="input" name="evidence_id" defaultValue={l.evidence_id ?? ''} aria-label="満たしている証跡">
                                    <option value="">結ばない</option>
                                    {data.evidences.map((e) => <option key={e.id} value={e.id}>{e.title}（{e.collected_at}）</option>)}
                                  </select>
                                  <select className="input" name="owner_user_id" defaultValue={l.owner_user_id ?? ''} aria-label="担当">
                                    <option value="">未定</option>
                                    {data.people.map((u) => <option key={u.id} value={u.id}>{u.display_name}（{u.email}）</option>)}
                                  </select>
                                  <button className="btn px-2 py-1 text-[12px]" type="submit">保存</button>
                                </form>
                              </details>
                            </div>
                          )}
                          {l.status === 'retired' && can(['owner', 'admin', 'manager']) && (
                            <form action={reactivateLegalRequirement}>{hidden}
                              <input type="hidden" name="id" value={l.id} />
                              <button className="btn px-2 py-1 text-[12px]" type="submit">戻す</button>
                            </form>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {can(['owner', 'admin', 'manager']) && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">要求事項を追加する</summary>
                <form action={saveLegalRequirement} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="種類">
                    <select className="input" name="kind" defaultValue="law">
                      {Object.entries(LEGAL_KIND_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                    </select>
                  </Field>
                  <Field label="要求事項（法令名・契約名など）"><input className="input" name="title" required maxLength={300} placeholder="例: 個人情報の保護に関する法律" /></Field>
                  <Field label="求めていること（必須）"><textarea className="input" name="requirement" required rows={2} maxLength={4000} /></Field>
                  <Field label="原文の場所（条項・条番号）"><input className="input" name="source_ref" maxLength={500} placeholder="例: 第 23 条（安全管理措置）" /></Field>
                  <Field label="応える統制">
                    <select className="input" name="measure_id" defaultValue="">
                      <option value="">結ばない</option>
                      {data.measures.map((m) => <option key={m.id} value={m.id}>{m.measure_key} {m.name}</option>)}
                    </select>
                  </Field>
                  <Field label="満たしている証跡">
                    <select className="input" name="evidence_id" defaultValue="">
                      <option value="">結ばない</option>
                      {data.evidences.map((e) => <option key={e.id} value={e.id}>{e.title}（{e.collected_at}）</option>)}
                    </select>
                  </Field>
                  <Field label="担当"><PersonSelect name="owner_user_id" people={data.people} placeholder="未定" /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">保存</button></div>
                </form>
              </details>
            )}
          </section>

          {/* ---- Business continuity plans and tests (A.5.29 / A.5.30) ---- */}
          <section id="continuity" className="card p-5">
            <h2 className="text-[16px] font-semibold">事業継続の計画と試験（A.5.29 / A.5.30）</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">
              中断・障害のときに何をどう続けるかの計画と、その試験。計画を作ったことと試して動いたことは別に残します。
              試験は実施した日が今日までのものだけを記録します（予定は計画の「次の試験期限」に入れます）。
            </p>
            {data.continuityPlans.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだ計画の記録がありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[980px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">計画</th><th className="px-3 py-2 font-medium">何を守るか</th>
                    <th className="px-3 py-2 font-medium">目標復旧時間・時点</th><th className="px-3 py-2 font-medium">最後の試験</th>
                    <th className="px-3 py-2 font-medium">次の試験期限</th><th className="px-3 py-2 font-medium">操作</th>
                  </tr></thead>
                  <tbody>
                    {data.continuityPlans.map((c) => (
                      <tr key={c.id} className={`border-b border-[var(--border)] align-top last:border-0 ${c.status === 'retired' ? 'text-[var(--muted)]' : ''}`}>
                        <td className="px-3 py-2">
                          {c.title}
                          {c.status === 'retired' && <span className="ms-1 badge badge-archived">取り下げ</span>}
                          <div className="break-all text-[11px] text-[var(--muted)]">所在: {c.procedure_location}</div>
                          <div className="text-[11px] text-[var(--muted)]">担当: {c.owner_name ?? '未定'}</div>
                        </td>
                        <td className="px-3 py-2">{c.scope}</td>
                        <td className="px-3 py-2">
                          {c.rto_hours != null ? `${c.rto_hours} 時間以内に復旧` : '復旧時間は未設定'}
                          <div className="text-[11px] text-[var(--muted)]">{c.rpo_hours != null ? `${c.rpo_hours} 時間前の状態まで戻す` : '復旧時点は未設定'}</div>
                        </td>
                        <td className="px-3 py-2">
                          {c.last_tested_on
                            ? <>{c.last_tested_on}<div className="text-[11px]">{CONTINUITY_RESULT_LABEL[c.last_result ?? ''] ?? c.last_result}（{c.test_count} 回）</div></>
                            : <span className="text-[var(--muted)]">未試験</span>}
                        </td>
                        <td className="px-3 py-2">
                          {c.next_test_due ?? '—'}
                          {c.status === 'active' && c.next_test_due && c.next_test_due < today() && (
                            <span className="ms-1 badge badge-danger">期限切れ</span>
                          )}
                        </td>
                        <td className="px-3 py-2">
                          {c.status === 'active' && can(['owner', 'admin', 'manager']) && (
                            <div className="flex flex-col gap-2">
                              <form action={retireContinuityPlan}>{hidden}
                                <input type="hidden" name="id" value={c.id} />
                                <button className="btn px-2 py-1 text-[12px]" type="submit">取り下げる</button>
                              </form>
                              <details>
                                <summary className="cursor-pointer text-[12px]">直す</summary>
                                <form action={updateContinuityPlan} className="mt-2 flex min-w-[260px] flex-col gap-1">{hidden}
                                  <input type="hidden" name="id" value={c.id} />
                                  <input className="input" name="title" required maxLength={300} defaultValue={c.title} aria-label="計画" />
                                  <textarea className="input" name="scope" required rows={2} maxLength={4000} defaultValue={c.scope} aria-label="何を守るか" />
                                  <input className="input" name="procedure_location" required maxLength={1000} defaultValue={c.procedure_location} aria-label="計画の所在" />
                                  <input className="input" name="rto_hours" type="number" min={1} max={8760} defaultValue={c.rto_hours ?? ''} aria-label="目標復旧時間（時間）" />
                                  <input className="input" name="rpo_hours" type="number" min={0} max={8760} defaultValue={c.rpo_hours ?? ''} aria-label="目標復旧時点（時間）" />
                                  <input className="input" name="next_test_due" type="date" defaultValue={c.next_test_due ?? ''} aria-label="次の試験期限" />
                                  <select className="input" name="owner_user_id" defaultValue={c.owner_user_id ?? ''} aria-label="担当">
                                    <option value="">未定</option>
                                    {data.people.map((u) => <option key={u.id} value={u.id}>{u.display_name}（{u.email}）</option>)}
                                  </select>
                                  <button className="btn px-2 py-1 text-[12px]" type="submit">保存</button>
                                </form>
                              </details>
                            </div>
                          )}
                          {c.status === 'retired' && can(['owner', 'admin', 'manager']) && (
                            <form action={reactivateContinuityPlan}>{hidden}
                              <input type="hidden" name="id" value={c.id} />
                              <button className="btn px-2 py-1 text-[12px]" type="submit">戻す</button>
                            </form>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {can(['owner', 'admin', 'manager']) && (
              <div className="mt-4 flex flex-col gap-3">
                <details>
                  <summary className="cursor-pointer text-[13px] font-semibold">計画を追加する</summary>
                  <form action={saveContinuityPlan} className="mt-3 grid gap-3 sm:grid-cols-2">
                    {hidden}
                    <Field label="計画"><input className="input" name="title" required maxLength={300} placeholder="例: 受注・出荷業務の継続計画" /></Field>
                    <Field label="何を守るか（業務・システム）"><textarea className="input" name="scope" required rows={2} maxLength={4000} /></Field>
                    <Field label="計画の所在（保管場所・URL）"><input className="input" name="procedure_location" required maxLength={1000} /></Field>
                    <Field label="次の試験期限"><input className="input" name="next_test_due" type="date" /></Field>
                    <Field label="目標復旧時間（時間）"><input className="input" name="rto_hours" type="number" min={1} max={8760} /></Field>
                    <Field label="目標復旧時点（何時間前の状態まで）"><input className="input" name="rpo_hours" type="number" min={0} max={8760} /></Field>
                    <Field label="担当"><PersonSelect name="owner_user_id" people={data.people} placeholder="未定" /></Field>
                    <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">保存</button></div>
                  </form>
                </details>
                {data.continuityPlans.some((c) => c.status === 'active') && (
                  <details>
                    <summary className="cursor-pointer text-[13px] font-semibold">試験を記録する</summary>
                    <form action={recordContinuityTest} className="mt-3 grid gap-3 sm:grid-cols-2">
                      {hidden}
                      <Field label="計画">
                        <select className="input" name="plan_id" required defaultValue="">
                          <option value="" disabled>選んでください</option>
                          {data.continuityPlans.filter((c) => c.status === 'active')
                            .map((c) => <option key={c.id} value={c.id}>{c.title}</option>)}
                        </select>
                      </Field>
                      <Field label="実施日"><input className="input" name="tested_on" type="date" required max={today()} defaultValue={today()} /></Field>
                      <Field label="方法">
                        <select className="input" name="method" defaultValue="tabletop">
                          {Object.entries(CONTINUITY_METHOD_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                        </select>
                      </Field>
                      <Field label="結果">
                        <select className="input" name="result" defaultValue="passed">
                          {Object.entries(CONTINUITY_RESULT_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                        </select>
                      </Field>
                      <Field label="目標復旧時間を守れたか">
                        <select className="input" name="rto_met" defaultValue="">
                          <option value="">測っていない</option><option value="yes">守れた</option><option value="no">守れなかった</option>
                        </select>
                      </Field>
                      <Field label="証跡">
                        <select className="input" name="evidence_id" defaultValue="">
                          <option value="">結ばない</option>
                          {data.evidences.map((e) => <option key={e.id} value={e.id}>{e.title}（{e.collected_at}）</option>)}
                        </select>
                      </Field>
                      <Field label="気づき・直すこと"><textarea className="input" name="findings_note" rows={2} maxLength={4000} /></Field>
                      <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">記録する</button></div>
                    </form>
                  </details>
                )}
              </div>
            )}
            {data.continuityTests.length > 0 && (
              <div className="mt-4 overflow-x-auto">
                <h3 className="mb-2 text-[13px] font-semibold">試験の記録</h3>
                {data.continuityTests.length >= LIST_LIMIT.continuityTests && (
                  <p className="mb-2 text-[11px] text-[var(--muted)]">
                    新しい順に {LIST_LIMIT.continuityTests} 件だけ表示しています（段階の画面の件数はすべてを数えています）。
                  </p>
                )}
                <table className="w-full min-w-[860px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">実施日</th><th className="px-3 py-2 font-medium">計画</th>
                    <th className="px-3 py-2 font-medium">方法</th><th className="px-3 py-2 font-medium">結果</th>
                    <th className="px-3 py-2 font-medium">目標復旧時間</th><th className="px-3 py-2 font-medium">実施者</th>
                    <th className="px-3 py-2 font-medium">気づき・証跡</th>
                  </tr></thead>
                  <tbody>
                    {data.continuityTests.map((t) => (
                      <tr key={t.id} className="border-b border-[var(--border)] align-top last:border-0">
                        <td className="px-3 py-2">{t.tested_on}{t.tested_on > today() && <span className="ms-1 badge badge-on-hold">予定</span>}</td>
                        <td className="px-3 py-2">{t.plan_title}</td>
                        <td className="px-3 py-2">{CONTINUITY_METHOD_LABEL[t.method] ?? t.method}</td>
                        <td className="px-3 py-2">{CONTINUITY_RESULT_LABEL[t.result] ?? t.result}</td>
                        <td className="px-3 py-2">{t.rto_met == null ? '測っていない' : t.rto_met ? '守れた' : '守れなかった'}</td>
                        <td className="px-3 py-2">{t.performer_name ?? '—'}</td>
                        <td className="px-3 py-2">
                          {t.findings_note || <span className="text-[var(--muted)]">—</span>}
                          {t.evidence_title && <div className="text-[11px]">証跡: {t.evidence_title}</div>}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>

          {/* ---- Technical vulnerabilities (A.8.8) ---- */}
          <section id="vulnerabilities" className="card p-5">
            <h2 className="text-[16px] font-semibold">技術的脆弱性（A.8.8）</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">
              検知した脆弱性と、対応期限・状態。閉じる（対処済み・誤検知）と閉じた日が入り、誤検知には理由が要ります。
              閉じたものは戻さず、再発したら新しく登録します。直さずに受け入れるなら、リスクとして
              <Link className="underline underline-offset-2" href={`/risk-management/risks?mode=${mode}`}>リスク台帳</Link>
              で扱います。
            </p>
            {data.vulnerabilities.length >= LIST_LIMIT.vulnerabilities && (
              <p className="mt-1 text-[11px] text-[var(--muted)]">
                開いているもの・重大度の高いものから {LIST_LIMIT.vulnerabilities} 件だけ表示しています（段階の画面の件数はすべてを数えています）。
              </p>
            )}
            {data.vulnerabilities.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだ脆弱性の記録がありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[960px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">重大度</th><th className="px-3 py-2 font-medium">脆弱性</th>
                    <th className="px-3 py-2 font-medium">資産</th><th className="px-3 py-2 font-medium">検知日・期限</th>
                    <th className="px-3 py-2 font-medium">状態</th><th className="px-3 py-2 font-medium">担当</th>
                    <th className="px-3 py-2 font-medium">操作</th>
                  </tr></thead>
                  <tbody>
                    {data.vulnerabilities.map((v) => {
                      const open = v.status === 'open' || v.status === 'in_progress';
                      return (
                        <tr key={v.id} className={`border-b border-[var(--border)] align-top last:border-0 ${open ? '' : 'text-[var(--muted)]'}`}>
                          <td className="px-3 py-2">{SEVERITY_LABEL[v.severity] ?? v.severity}</td>
                          <td className="px-3 py-2">
                            {v.title}
                            <div className="text-[11px] text-[var(--muted)]">{v.identifier || '識別子なし'}・{VULN_SOURCE_LABEL[v.source] ?? v.source}</div>
                          </td>
                          <td className="px-3 py-2">{v.asset_name ? `${v.asset_key} ${v.asset_name}` : <span className="text-[var(--muted)]">結んでいない</span>}</td>
                          <td className="px-3 py-2">
                            {v.detected_on}
                            <div className="text-[11px]">
                              期限: {v.due_date ?? '—'}
                              {open && v.due_date && v.due_date < today() && <span className="ms-1 badge badge-danger">期限切れ</span>}
                            </div>
                          </td>
                          <td className="px-3 py-2">
                            {VULN_STATUS_LABEL[v.status] ?? v.status}
                            {v.resolved_on && <div className="text-[11px]">{v.resolved_on}</div>}
                            {v.resolution_note && <div className="text-[11px] text-[var(--muted)]">{v.resolution_note}</div>}
                          </td>
                          <td className="px-3 py-2">{v.owner_name ?? '—'}</td>
                          <td className="px-3 py-2">
                            {open && can(['owner', 'admin', 'manager']) && (
                              <form action={progressVulnerability} className="flex min-w-[200px] flex-col gap-1">{hidden}
                                <input type="hidden" name="id" value={v.id} />
                                <select className="input" name="status" required defaultValue="" aria-label="次の状態">
                                  <option value="" disabled>次の状態</option>
                                  {v.status === 'open' && <option value="in_progress">対応中</option>}
                                  <option value="mitigated">対処済み</option>
                                  <option value="false_positive">誤検知</option>
                                </select>
                                <input className="input" name="resolution_note" maxLength={4000} placeholder="対処の内容・誤検知の理由" aria-label="対処の内容・誤検知の理由" />
                                <button className="btn px-2 py-1 text-[12px]" type="submit">更新</button>
                              </form>
                            )}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
            {can(['owner', 'admin', 'manager']) && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">脆弱性を登録する</summary>
                <form action={saveVulnerability} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="脆弱性"><input className="input" name="title" required maxLength={300} placeholder="例: OpenSSL の脆弱性" /></Field>
                  <Field label="識別子（CVE 番号など）"><input className="input" name="identifier" maxLength={100} placeholder="例: CVE-2026-0001" /></Field>
                  <Field label="重大度">
                    <select className="input" name="severity" defaultValue="medium">
                      {Object.entries(SEVERITY_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                    </select>
                  </Field>
                  <Field label="どこで知ったか">
                    <select className="input" name="source" defaultValue="scan">
                      {Object.entries(VULN_SOURCE_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                    </select>
                  </Field>
                  <Field label="資産">
                    <select className="input" name="asset_id" defaultValue="">
                      <option value="">結ばない</option>
                      {data.assets.map((a) => <option key={a.id} value={a.id}>{a.asset_key} {a.name}</option>)}
                    </select>
                  </Field>
                  <Field label="検知日"><input className="input" name="detected_on" type="date" required max={today()} defaultValue={today()} /></Field>
                  <Field label="対応期限"><input className="input" name="due_date" type="date" /></Field>
                  <Field label="担当"><PersonSelect name="owner_user_id" people={data.people} placeholder="未定" /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">登録</button></div>
                </form>
              </details>
            )}
          </section>

          {/* ---- Change requests and approval (A.8.32) ---- */}
          <section id="changes" className="card p-5">
            <h2 className="text-[16px] font-semibold">変更の申請と承認（A.8.32）</h2>
            <p className="mt-1 text-[12px] text-[var(--muted)]">
              情報システムや設備を変える前に申請し、経営層（最高責任者）が承認してから実施します。申請者は自分の申請を判断できません。
              承認すると、その時点の中身が承認の記録に結ばれます。中身を直せるのは申請中だけで、申請は消さずに取りやめます。
            </p>
            {data.changeRequests.length >= LIST_LIMIT.changeRequests && (
              <p className="mt-1 text-[11px] text-[var(--muted)]">
                判断待ち・実施待ちから新しい順に {LIST_LIMIT.changeRequests} 件だけ表示しています（段階の画面の件数はすべてを数えています）。
              </p>
            )}
            {data.changeRequests.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだ変更の申請がありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[1040px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">申請</th><th className="px-3 py-2 font-medium">内容・影響・戻し方</th>
                    <th className="px-3 py-2 font-medium">リスク</th><th className="px-3 py-2 font-medium">資産・予定日</th>
                    <th className="px-3 py-2 font-medium">状態</th><th className="px-3 py-2 font-medium">操作</th>
                  </tr></thead>
                  <tbody>
                    {data.changeRequests.map((c) => {
                      const closed = c.status === 'rejected' || c.status === 'implemented' || c.status === 'cancelled';
                      return (
                        <tr key={c.id} className={`border-b border-[var(--border)] align-top last:border-0 ${closed ? 'text-[var(--muted)]' : ''}`}>
                          <td className="px-3 py-2">
                            {c.title}
                            <div className="text-[11px] text-[var(--muted)]">{c.requester_name ?? '—'}・{c.requested_at}</div>
                          </td>
                          <td className="px-3 py-2">
                            {c.description}
                            <div className="text-[11px]">影響: {c.impact}</div>
                            {c.rollback_plan && <div className="text-[11px] text-[var(--muted)]">戻し方: {c.rollback_plan}</div>}
                          </td>
                          <td className="px-3 py-2">{RISK_LEVEL_LABEL[c.risk_level] ?? c.risk_level}</td>
                          <td className="px-3 py-2">
                            {c.asset_name ? `${c.asset_key} ${c.asset_name}` : <span className="text-[var(--muted)]">結んでいない</span>}
                            <div className="text-[11px]">予定: {c.planned_on ?? '—'}</div>
                          </td>
                          <td className="px-3 py-2">
                            {CHANGE_STATUS_LABEL[c.status] ?? c.status}
                            {c.decided_at && <div className="text-[11px]">判断: {c.decider_name}・{c.decided_at}</div>}
                            {c.decision_note && <div className="text-[11px] text-[var(--muted)]">{c.decision_note}</div>}
                            {c.implemented_at && <div className="text-[11px]">実施: {c.implementer_name}・{c.implemented_at}</div>}
                            {c.result_note && <div className="text-[11px] text-[var(--muted)]">{c.result_note}</div>}
                          </td>
                          <td className="px-3 py-2">
                            <div className="flex min-w-[220px] flex-col gap-2">
                              {c.status === 'requested' && role === 'owner' && c.requested_by !== actorId && (
                                <form action={decideChangeRequest} className="flex flex-col gap-1">{hidden}
                                  <input type="hidden" name="id" value={c.id} />
                                  <select className="input" name="decision" required defaultValue="" aria-label="判断">
                                    <option value="" disabled>判断</option>
                                    <option value="approve">承認する</option>
                                    <option value="reject">却下する</option>
                                  </select>
                                  <input className="input" name="decision_note" maxLength={4000} placeholder="理由・条件（却下は必須）" aria-label="理由・条件" />
                                  <button className="btn px-2 py-1 text-[12px]" type="submit">判断する</button>
                                </form>
                              )}
                              {c.status === 'approved' && can(['owner', 'admin', 'manager', 'member']) && (
                                <form action={implementChange} className="flex flex-col gap-1">{hidden}
                                  <input type="hidden" name="id" value={c.id} />
                                  <input className="input" name="result_note" required maxLength={4000} placeholder="実施した内容・結果" aria-label="実施した内容・結果" />
                                  <button className="btn px-2 py-1 text-[12px]" type="submit">実施した</button>
                                </form>
                              )}
                              {(c.status === 'requested' || c.status === 'approved') && can(['owner', 'admin', 'manager', 'member']) && (
                                <form action={cancelChange}>{hidden}
                                  <input type="hidden" name="id" value={c.id} />
                                  <button className="btn px-2 py-1 text-[12px]" type="submit">取りやめる</button>
                                </form>
                              )}
                              {c.status === 'requested' && can(['owner', 'admin', 'manager', 'member']) && (
                                <details>
                                  <summary className="cursor-pointer text-[12px]">直す</summary>
                                  <form action={updateChangeRequest} className="mt-2 flex flex-col gap-1">{hidden}
                                    <input type="hidden" name="id" value={c.id} />
                                    <input className="input" name="title" required maxLength={300} defaultValue={c.title} aria-label="申請" />
                                    <textarea className="input" name="description" required rows={2} maxLength={4000} defaultValue={c.description} aria-label="何をどう変えるか" />
                                    <textarea className="input" name="impact" required rows={2} maxLength={4000} defaultValue={c.impact} aria-label="影響とリスク" />
                                    <select className="input" name="risk_level" defaultValue={c.risk_level} aria-label="リスク">
                                      {Object.entries(RISK_LEVEL_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                                    </select>
                                    <textarea className="input" name="rollback_plan" rows={2} maxLength={4000} defaultValue={c.rollback_plan} aria-label="戻し方" />
                                    <select className="input" name="asset_id" defaultValue={c.asset_id ?? ''} aria-label="資産">
                                      <option value="">結ばない</option>
                                      {data.assets.map((a) => <option key={a.id} value={a.id}>{a.asset_key} {a.name}</option>)}
                                    </select>
                                    <input className="input" name="planned_on" type="date" defaultValue={c.planned_on ?? ''} aria-label="予定日" />
                                    <button className="btn px-2 py-1 text-[12px]" type="submit">保存</button>
                                  </form>
                                </details>
                              )}
                            </div>
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
            {can(['owner', 'admin', 'manager', 'member']) && (
              <details className="mt-4">
                <summary className="cursor-pointer text-[13px] font-semibold">変更を申請する</summary>
                <form action={requestChange} className="mt-3 grid gap-3 sm:grid-cols-2">
                  {hidden}
                  <Field label="申請（何の変更か）"><input className="input" name="title" required maxLength={300} placeholder="例: ファイアウォール規則の変更" /></Field>
                  <Field label="リスク">
                    <select className="input" name="risk_level" defaultValue="medium">
                      {Object.entries(RISK_LEVEL_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                    </select>
                  </Field>
                  <Field label="何をどう変えるか（必須）"><textarea className="input" name="description" required rows={2} maxLength={4000} /></Field>
                  <Field label="影響とリスク（必須）"><textarea className="input" name="impact" required rows={2} maxLength={4000} /></Field>
                  <Field label="失敗したときの戻し方"><textarea className="input" name="rollback_plan" rows={2} maxLength={4000} /></Field>
                  <Field label="資産">
                    <select className="input" name="asset_id" defaultValue="">
                      <option value="">結ばない</option>
                      {data.assets.map((a) => <option key={a.id} value={a.id}>{a.asset_key} {a.name}</option>)}
                    </select>
                  </Field>
                  <Field label="実施の予定日"><input className="input" name="planned_on" type="date" /></Field>
                  <div className="sm:col-span-2"><button className="btn btn-primary px-3 py-2 text-sm" type="submit">申請する</button></div>
                </form>
              </details>
            )}
          </section>
        </>
      )}
    </div>
  );
}
