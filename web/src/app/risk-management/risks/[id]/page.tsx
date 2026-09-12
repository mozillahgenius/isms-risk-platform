import Link from 'next/link';
import {
  acceptRisk,
  addRiskSnapshot,
  approveManagementDeviation,
  closeManagementDeviation,
  requestIsoRemoval,
  requestManagementDeviation,
} from '@/app/risk-management/actions';
import { RiskMapTimeline, today } from '@/components/RiskMapTimeline';
import { frameworkForMode } from '@/lib/navigation';
import { getIsoRemovalContext, getRiskDetail, getRiskViewerContext, getRiskWorkspace, normalizeFrameworkKey } from '@/lib/riskRegister';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'リスク評価履歴' };

type Params = Promise<{ id: string }>;
type SearchParams = Promise<Record<string, string | string[] | undefined>>;

function displayed(value: string | number | null | undefined) {
  return value === null || value === undefined || value === '' ? '未記録' : String(value);
}

export default async function RiskDetailPage({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  const [{ id }, sp] = await Promise.all([params, searchParams]);
  const requestedMode = Array.isArray(sp.mode) ? sp.mode[0] : sp.mode;
  const mode = requestedMode === 'isms' || requestedMode === 'risk' ? requestedMode : undefined;
  const frameworkKey = normalizeFrameworkKey(frameworkForMode(sp.framework, mode));
  const frameworkSearch = `framework=${encodeURIComponent(frameworkKey)}${mode === 'isms' ? '&mode=isms' : ''}`;
  const [detailResult, workspaceResult, isoResult, viewerResult] = await Promise.all([getRiskDetail(id, frameworkKey), getRiskWorkspace(frameworkKey), getIsoRemovalContext(), getRiskViewerContext()]);
  const detail = detailResult.ok ? detailResult.data : null;
  const data = workspaceResult.ok ? workspaceResult.data : null;
  const viewer = viewerResult.ok ? viewerResult.data : null;
  const hasRole = (role: string) => viewer?.role_keys.includes(role) ?? false;
  const canAcceptRisk = hasRole('ciso');
  const canRequestDeviation = hasRole('secretariat') || hasRole('risk_owner');
  const canRequestIsoRemoval = hasRole('ciso') || hasRole('secretariat');
  const isIsoLens = frameworkKey === 'ISO27001:2022';
  const newestSnapshots = detail ? [...detail.snapshots].reverse() : [];
  const evaluationSnapshot = newestSnapshots.find((snapshot) => snapshot.stage === 'after_measure' && snapshot.assessed_on <= today());
  const inherentSnapshot = evaluationSnapshot
    ? newestSnapshots.find((snapshot) => snapshot.stage === 'inherent' && snapshot.assessed_on === evaluationSnapshot.assessed_on)
    : undefined;
  return (
    <div className="flex flex-col gap-5">
      <div><Link className="text-[12px] text-[var(--muted)] underline" href={`/risk-management/risks?${frameworkSearch}`}>← リスク台帳へ戻る</Link>{detail ? <><p className="mt-3 text-[11px] font-[family-name:var(--font-geist-mono)] text-[var(--muted)]">{detail.risk.risk_key} / Phase {detail.risk.phase} / {detail.risk.area}</p><h1 className="mt-1 text-[21px] font-semibold">{detail.risk.summary}</h1><p className="mt-1 text-[13px] text-[var(--muted)]">テーマ: {detail.risk.theme} / 想定施策: {detail.risk.measure} / 観点: {detail.risk.frame}</p></> : <h1 className="mt-3 text-[21px] font-semibold">リスク評価履歴</h1>}</div>
      {!detail ? <div className="card p-5 text-[13px] text-[var(--muted)]">対象リスクが見つからないか、テナントセッションが必要です。</div> : <>
        <section className="card p-4"><RiskMapTimeline snapshots={detail.snapshots} /></section>
        {isIsoLens && <section className="card grid gap-4 p-4 md:grid-cols-2">
          <div className="md:col-span-2"><h2 className="text-[15px] font-semibold">ISMS 実務状態</h2><p className="mt-1 text-[12px] text-[var(--muted)]">ISO/IEC 27001:2022 タグが付いた同じリスクIDの読取専用表示です。指摘は明示的に紐付けたものだけを表示します。</p></div>
          {!detail.isms ? <p className="text-[13px] text-[var(--warning)] md:col-span-2">ISMS読取モデルが利用できません。ISOタグ、migration適用状況、またはテナント文脈を確認してください。</p> : <>
            <div className="rounded border border-[var(--line)] p-3"><h3 className="text-[13px] font-semibold">現行 CIA 評価</h3>
              {detail.isms.current_assessment_id ? <div className="mt-2 grid grid-cols-2 gap-1 text-[12px]"><span>状態: {displayed(detail.isms.current_assessment_status)}</span><span>評価日: {displayed(detail.isms.current_assessed_at)}</span><span>発生可能性: {displayed(detail.isms.current_probability)}</span><span>機密性: {displayed(detail.isms.confidentiality)}</span><span>完全性: {displayed(detail.isms.integrity)}</span><span>可用性: {displayed(detail.isms.availability)}</span><span>情報セキュリティ影響: {displayed(detail.isms.current_security_impact)}</span><span>情報セキュリティレベル: {displayed(detail.isms.current_security_level)}</span></div> : <p className="mt-2 text-[12px] text-[var(--warning)]">現行の有効なCIA評価は未記録です。</p>}
            </div>
            <div className="rounded border border-[var(--line)] p-3"><h3 className="text-[13px] font-semibold">基準逸脱</h3>
              {!detail.isms.current_assessment_id ? <p className="mt-2 text-[12px] text-[var(--muted)]">現行評価がないため、適用基準の逸脱は判定できません。</p> : detail.isms.criterion_deviation_id ? <p className="mt-2 text-[12px]">{detail.isms.criterion_deviation_status} / 期限: {displayed(detail.isms.criterion_deviation_expires_at)}<br />{displayed(detail.isms.criterion_deviation_reason)}</p> : <p className="mt-2 text-[12px] text-[var(--muted)]">この評価基準に紐づく逸脱はありません。</p>}
            </div>
            <div className="rounded border border-[var(--line)] p-3"><h3 className="text-[13px] font-semibold">適用管理策と実装</h3>
              {detail.isms.controls.length === 0 ? <p className="mt-2 text-[12px] text-[var(--warning)]">ISO管理策の紐付けは未記録です。</p> : <ul className="mt-2 space-y-2 text-[12px]">{detail.isms.controls.map((control) => <li key={control.control_id}><b>{control.code}</b> {control.title}<br /><span className="text-[var(--muted)]">実装: {control.implementation_id ? `${displayed(control.status)} / ${displayed(control.applicability)}` : '未記録'}</span></li>)}</ul>}
            </div>
            <div className="rounded border border-[var(--line)] p-3"><h3 className="text-[13px] font-semibold">証跡</h3><p className="mt-2 text-[12px]">重複を除く {detail.isms.evidence_total_count} 件（有効 {detail.isms.evidence_valid_count} / 鮮度切れ {detail.isms.evidence_stale_count} / 期限切れ {detail.isms.evidence_expired_count} / 取得不能 {detail.isms.evidence_unobtainable_count} / 未収集 {detail.isms.evidence_not_collected_count}）</p></div>
            <div className="rounded border border-[var(--line)] p-3"><h3 className="text-[13px] font-semibold">紐付け済み監査・運用指摘</h3>
              {detail.isms.findings.length === 0 ? <p className="mt-2 text-[12px] text-[var(--muted)]">このリスクに明示的に紐付けられた指摘はありません。</p> : <ul className="mt-2 space-y-2 text-[12px]">{detail.isms.findings.map((finding) => <li key={finding.id}><b>{finding.severity}</b> / {finding.status} — {finding.title}<br /><span className="text-[var(--muted)]">{finding.source} / 検出: {displayed(finding.detected_at)} / 期限: {displayed(finding.due_date)}</span></li>)}</ul>}
            </div>
            <div className="rounded border border-[var(--line)] p-3"><h3 className="text-[13px] font-semibold">最新のスナップショット束縛受容</h3>
              {detail.isms.acceptance_freshness === 'missing' ? <p className="mt-2 text-[12px] text-[var(--warning)]">受容記録は未記録です。</p> : <p className="mt-2 text-[12px]">スナップショット束縛の鮮度: <b>{detail.isms.acceptance_freshness === 'current' ? '最新' : '古い（評価履歴または束縛を確認）'}</b><br />受容期限の有効性: <b>{displayed(detail.isms.acceptance_expiry_status)}</b><br />受容日: {displayed(detail.isms.accepted_at)} / 期限: {displayed(detail.isms.acceptance_expires_at)}<br />残余: {displayed(detail.isms.acceptance_residual_level)} / 固有: {displayed(detail.isms.acceptance_inherent_level)}<br />理由: {displayed(detail.isms.acceptance_reason)}</p>}
            </div>
          </>}
        </section>}
        <section className="card grid gap-4 p-4 md:grid-cols-2">
          <div className="md:col-span-2"><h2 className="text-[15px] font-semibold">逸脱管理</h2><p className="mt-1 text-[12px] text-[var(--muted)]">期限、責任者、是正内容をこのリスクIDへ結び付けます。</p></div>
          {detail.deviations.length === 0 ? <p className="text-[12px] text-[var(--muted)] md:col-span-2">登録済みの逸脱はありません。</p> : detail.deviations.map((deviation) => <div key={deviation.id} className="rounded border border-[var(--line)] p-3 text-[12px]"><b>{deviation.title}</b><p className="mt-1">{deviation.description}</p><p className="mt-1 text-[var(--muted)]">状態: {deviation.status} / 是正期限: {deviation.due_at} / 失効: {deviation.expires_at}</p>{deviation.close_note && <p className="mt-1">クローズ結果: {deviation.close_note}</p>}{deviation.status === 'requested' && hasRole('ciso') && viewer?.user_id !== deviation.requested_by && <form action={approveManagementDeviation} className="mt-2">{mode && <input type="hidden" name="mode" value={mode} />}<input type="hidden" name="id" value={deviation.id} /><input type="hidden" name="risk_id" value={detail.risk.id} /><button className="btn btn-primary" type="submit">承認</button></form>}{deviation.status === 'open' && (hasRole('ciso') || viewer?.user_id === deviation.owner_user_id) && <form action={closeManagementDeviation} className="mt-2 grid gap-2">{mode && <input type="hidden" name="mode" value={mode} />}<input type="hidden" name="id" value={deviation.id} /><input type="hidden" name="risk_id" value={detail.risk.id} /><input className="input" name="close_note" placeholder="是正結果" required /><button className="btn btn-primary" type="submit">クローズ</button></form>}</div>)}
          {canRequestDeviation && <form action={requestManagementDeviation} className="grid gap-3 border-t border-[var(--line)] pt-4 md:col-span-2 md:grid-cols-2">
            {mode && <input type="hidden" name="mode" value={mode} />}<input type="hidden" name="id" value={detail.risk.id} />
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">件名<input className="input" name="title" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">責任者<select className="input" name="owner_user_id" required><option value="">選択してください</option>{detail.riskOwners.map((owner) => <option key={owner.id} value={owner.id}>{owner.display_name}</option>)}</select></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">内容<textarea className="input" name="description" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">是正措置<textarea className="input" name="corrective_action" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">是正期限<input className="input" name="due_at" type="datetime-local" required /></label>
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">失効日時<input className="input" name="expires_at" type="datetime-local" required /></label>
            <div className="md:col-span-2"><button className="btn btn-primary" type="submit" disabled={detail.riskOwners.length === 0}>逸脱を申請</button></div>
          </form>}
        </section>
        <form action={addRiskSnapshot} className="card grid gap-3 p-4 md:grid-cols-2">
          {mode && <input type="hidden" name="mode" value={mode} />}
          <input type="hidden" name="id" value={detail.risk.id} />
          <h2 className="text-[15px] font-semibold md:col-span-2">評価スナップショットを追加</h2>
          <p className="text-[12px] text-[var(--muted)] md:col-span-2">履歴は追記型です。固有、施策前、施策後を別レコードで保持し、後から上書きしません。評価日を未来日にすると「目標」として記録され、現状の評価とは区別して表示されます(施策実施後、実際の評価日で記録し直してください)。</p>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">評価段階<select className="input" name="stage" defaultValue="after_measure"><option value="inherent">固有リスク</option><option value="before_measure">施策前</option><option value="after_measure">施策後</option></select></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">評価日<input className="input" type="date" name="assessed_on" defaultValue={today()} required /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">発生可能性<select className="input" name="probability" defaultValue="2"><option>1</option><option>2</option><option>3</option><option>4</option><option>5</option></select></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">影響度<select className="input" name="impact" defaultValue="3"><option>1</option><option>2</option><option>3</option><option>4</option><option>5</option></select></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">紐付け施策<select className="input" name="measure_id" defaultValue={data?.measures[0]?.id ?? ''}><option value="">なし</option>{data?.measures.map((measure) => <option key={measure.id} value={measure.id}>{measure.measure_key} {measure.name}</option>)}</select></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">評価根拠<textarea className="input min-h-20" name="rationale" placeholder="この確率・影響度とした理由" required /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">出所<textarea className="input" name="source_note" defaultValue="評価会議・証跡へのリンクを記載" /></label>
          <div className="md:col-span-2"><button className="btn btn-primary" type="submit">評価を追加</button></div>
        </form>
        {canAcceptRisk && <form action={acceptRisk} className="card grid gap-3 p-4 md:grid-cols-2">
          {mode && <input type="hidden" name="mode" value={mode} />}<input type="hidden" name="id" value={detail.risk.id} />
          <h2 className="text-[15px] font-semibold md:col-span-2">リスク受容（経営責任者のみ）</h2>
          <p className="text-[12px] text-[var(--muted)] md:col-span-2">受容値は入力せず、最新の固有リスクと施策後評価の改変不能なスナップショットへ結び付けます。</p>
          {evaluationSnapshot && inherentSnapshot ? <>
            <input type="hidden" name="evaluation_snapshot_id" value={evaluationSnapshot.id} />
            <input type="hidden" name="evaluation_snapshot_sha256" value={evaluationSnapshot.sha256} />
            <input type="hidden" name="inherent_snapshot_id" value={inherentSnapshot.id} />
            <input type="hidden" name="inherent_snapshot_sha256" value={inherentSnapshot.sha256} />
            <p className="text-[12px]">残余レベル: <b>{evaluationSnapshot.risk_level}</b></p>
            <p className="text-[12px]">固有レベル: <b>{inherentSnapshot.risk_level}</b></p>
          </> : <p className="text-[12px] text-[var(--warning)] md:col-span-2">受容には固有リスクと施策後評価の両方が必要です。</p>}
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">判断根拠の承認済み規程<select className="input" name="policy_version_id" required defaultValue=""><option value="" disabled>選択してください</option>{detail.approvedPolicies.map((policy) => <option key={policy.id} value={policy.id}>{policy.title} v{policy.version}</option>)}</select></label>
          {detail.approvedPolicies.length === 0 && <p className="text-[12px] text-[var(--warning)] md:col-span-2">有効な承認済み規程がないため受容を記録できません。</p>}
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">受容期限<input className="input" name="expires_at" type="datetime-local" required /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">受容理由<textarea className="input" name="reason" required /></label>
          <div className="md:col-span-2"><button className="btn btn-primary" type="submit" disabled={!evaluationSnapshot || !inherentSnapshot || detail.approvedPolicies.length === 0}>受容を記録</button></div>
        </form>}
        {canRequestIsoRemoval && isoResult.ok && isoResult.data.relations.find((row) => row.entity_type === 'risk_scenario' && row.entity_id === detail.risk.id) && (() => { const relation = isoResult.data.relations.find((row) => row.entity_type === 'risk_scenario' && row.entity_id === detail.risk.id)!; return <form action={requestIsoRemoval} className="card grid gap-3 p-4 md:grid-cols-2"><input type="hidden" name="entity_type" value="risk_scenario" /><input type="hidden" name="entity_id" value={detail.risk.id} /><input type="hidden" name="generation_id" value={relation.generation_id} /><h2 className="text-[15px] font-semibold md:col-span-2">ISO対象からの除外申請</h2><label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">理由<textarea className="input" name="reason" required /></label><label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">代替統制<textarea className="input" name="alternate_control" required /></label><label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">期限<input className="input" type="datetime-local" name="expires_at" required /></label><button className="btn btn-primary" type="submit">除外を申請</button></form>; })()}
      </>}
    </div>
  );
}
