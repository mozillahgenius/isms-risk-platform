import { getAnalysisWorkspace } from '@/lib/analysisRegister';
import { runSimulation } from '@/app/analysis/actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'AI分析・シミュレーション' };

const ERROR_LABEL: Record<string, string> = {
  invalid_session: 'セッションが無効です。ページを再読み込みしてください。',
  no_token: 'テナントセッションが必要です。',
  invalid_input: '入力内容を確認してください。',
  measure_not_found: '対象の施策が見つかりません。',
  insufficient_data: 'リスク評価データが不足しているため、シミュレーションを実行できません。画面①でこの施策の対策後(after_measure)評価を記録すると利用できるようになります。',
  inconsistent_data: '対策前後のリスク評価値が逆転しており(対策後の方が高い)、シミュレーションを実行できません。画面①のリスク評価記録を確認してください。',
  missing_baseline_data: 'この施策が関わるリスクシナリオの一部に、対策前(before_measure)・固有(inherent)の評価が記録されていないため、シミュレーションを実行できません。画面①でリスク評価を記録すると利用できるようになります。',
};

const SCORE_BADGE: Record<string, string> = {
  高: 'badge badge-danger',
  中: 'badge badge-on-hold',
  低: 'badge badge-lead',
};

export default async function AnalysisPage({ searchParams }: { searchParams: Promise<{ saved?: string; error?: string }> }) {
  const [result, sp] = await Promise.all([getAnalysisWorkspace(), searchParams]);
  const data = result.ok ? result.data : null;
  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-[21px] font-semibold">AI分析・シミュレーション</h1>
        <p className="mt-1 text-[13px] text-[var(--muted)]">
          施策・ルールの重複分析と、施策を外した場合のリスク影響シミュレーションを行います。
        </p>
      </div>
      {sp.saved === '1' && (
        <section className="card border-[var(--success)] bg-[var(--success-weak)] p-4" role="status">
          <p className="text-sm font-semibold text-[var(--badge-success-fg)]">実行しました</p>
        </section>
      )}
      {sp.error && (
        <section className="card border-[var(--danger)] bg-[var(--danger-weak)] p-4" role="alert">
          <p className="text-sm font-semibold text-[var(--badge-danger-fg)]">実行できませんでした</p>
          <p className="mt-1 text-xs text-[var(--fg-2)]">{ERROR_LABEL[sp.error] ?? `原因区分: ${sp.error}`}</p>
        </section>
      )}
      {!data ? <div className="card p-5 text-[13px] text-[var(--muted)]">テナントセッションが必要です。</div> : <>
        <section className="card p-4">
          <h2 className="text-[15px] font-semibold">施策・ルールの重複分析</h2>
          <p className="mt-1 text-[12px] text-[var(--muted)]">
            現在有効な対応(取消・失効・改定前の版を除く)のうち、同一リスクまたは同一資産をカバーしている施策の組を機械的に検出します(サンプル値ではなく、登録済みの施策・リスク・資産データからの算出)。
          </p>
          {data.duplicatePairs.length === 0 ? (
            <p className="mt-3 text-[13px] text-[var(--muted)]">
              重複は検出されていません(施策・リスク・資産の登録が少ない場合、または実際に重複が無い場合の両方があり得ます)。
            </p>
          ) : (
            <div className="mt-3 overflow-x-auto">
              <table className="min-w-[640px] w-full border-collapse text-[13px]">
                <thead>
                  <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">施策A</th>
                    <th className="px-3 py-2 font-medium">施策B</th>
                    <th className="px-3 py-2 font-medium">共有リスク数</th>
                    <th className="px-3 py-2 font-medium">共有資産数</th>
                    <th className="px-3 py-2 font-medium">重複度</th>
                  </tr>
                </thead>
                <tbody>
                  {data.duplicatePairs.map((p) => (
                    <tr key={`${p.measure_a_id}-${p.measure_b_id}`} className="border-b border-[var(--border)] last:border-0">
                      <td className="px-3 py-2">{p.measure_a_key} {p.measure_a_name}</td>
                      <td className="px-3 py-2">{p.measure_b_key} {p.measure_b_name}</td>
                      <td className="px-3 py-2 text-[var(--muted)]">{p.shared_risk_count}</td>
                      <td className="px-3 py-2 text-[var(--muted)]">{p.shared_asset_count}</td>
                      <td className="px-3 py-2"><span className={SCORE_BADGE[p.overlap_score]}>{p.overlap_score}</span></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        <section className="card p-4">
          <h2 className="text-[15px] font-semibold">施策除外シミュレーション</h2>
          <p className="mt-1 text-[12px] text-[var(--muted)]">
            画面①のリスク評価スナップショット(対策前/対策後)にもとづき、指定した施策を除外した場合のリスク値を再計算します。除外後のリスク値は、その施策が無い状態(対策前、無ければ固有リスク)の評価と同じです。
          </p>
          <p className="mt-1 text-[11px] text-[var(--warning)]">
            対策前(before_measure)・固有(inherent)の評価はリスクシナリオ単位の記録です。1つのリスクシナリオに複数の施策が紐づいている場合、この計算は「対象施策だけを外す」ではなく「そのシナリオに紐づく施策すべてを外す」場合の値になります(下表で「他施策と共通」と表示されます)。
          </p>
          {data.simulatableMeasures.length === 0 ? (
            <div className="mt-3 card border-[var(--warning)] bg-[var(--warning-weak)] p-3" role="status">
              <p className="text-[12px] font-medium text-[var(--badge-warning-fg)]">
                {data.hasAnyAfterMeasureCandidate
                  ? '対策後(after_measure)の評価がある施策はあるものの、比較に必要な対策前(before_measure)・固有(inherent)の評価が記録されていないため、この機能は無効化されています。不確かな数値を表示しないための措置です。画面①でリスク評価を記録すると利用できます。'
                  : '対策後(after_measure)のリスク評価が記録されている施策が無いため、この機能は無効化されています。不確かな数値を表示しないための措置です。画面①でリスク評価(対策前・対策後)を記録すると利用できます。'}
              </p>
            </div>
          ) : (
            <>
              <p className="mt-2 text-[11px] text-[var(--muted)]">
                すべての実行結果は「実データに基づく推定」です(サンプル値は使用していません)。
              </p>
              <form action={runSimulation} className="mt-3 flex flex-wrap items-end gap-2">
                <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">
                  除外する施策
                  <select className="input" name="excluded_measure_id" required>
                    <option value="">選択してください</option>
                    {data.simulatableMeasures.map((m) => <option key={m.id} value={m.id}>{m.measure_key} {m.name}</option>)}
                  </select>
                </label>
                <button className="btn btn-primary" type="submit">シミュレーション実行</button>
              </form>
            </>
          )}
          <div className="mt-4 overflow-x-auto">
            <table className="min-w-[720px] w-full border-collapse text-[13px]">
              <thead>
                <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                  <th className="px-3 py-2 font-medium">実行日時</th>
                  <th className="px-3 py-2 font-medium">除外した施策</th>
                  <th className="px-3 py-2 font-medium">対象シナリオ数</th>
                  <th className="px-3 py-2 font-medium">現状(施策あり)リスク値合計</th>
                  <th className="px-3 py-2 font-medium">除外後リスク値合計</th>
                  <th className="px-3 py-2 font-medium">実行者</th>
                  <th className="px-3 py-2 font-medium">備考</th>
                </tr>
              </thead>
              <tbody>
                {data.simulationRuns.map((r) => (
                  <tr key={r.id} className="border-b border-[var(--border)] last:border-0">
                    <td className="px-3 py-2 text-[var(--muted)]">{r.run_at}</td>
                    <td className="px-3 py-2">{r.excluded_measure_name}</td>
                    <td className="px-3 py-2 text-[var(--muted)]">{r.scenario_count}</td>
                    <td className="px-3 py-2 text-[var(--muted)]">{r.after_measure_risk_level_sum}</td>
                    <td className="px-3 py-2 text-[var(--muted)]">{r.without_measure_risk_level_sum}</td>
                    <td className="px-3 py-2 text-[var(--muted)]">{r.run_by_name ?? '—'}</td>
                    <td className="px-3 py-2 flex flex-wrap gap-1">
                      {r.has_shared_measures && <span className="badge badge-on-hold">他施策と共通</span>}
                      {r.has_stale_baseline && <span className="badge badge-on-hold">評価時点が不揃い</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {data.simulationRuns.length === 0 && (
              <p className="mt-2 text-[13px] text-[var(--muted)]">まだ実行履歴がありません。</p>
            )}
          </div>
        </section>

        <section className="card p-4">
          <h2 className="text-[15px] font-semibold">参考: 施策別インシデント紐づけ</h2>
          <p className="mt-1 text-[12px] text-[var(--muted)]">
            画面⑦のインシデント実績(現在{data.totalIncidentCount}件)のうち、各施策に紐づいている件数の実測です。施策を外した場合の増減を予測するものではありません。
          </p>
          {data.measureIncidentLinks.length === 0 ? (
            <p className="mt-3 text-[13px] text-[var(--muted)]">いずれの施策にもインシデントが紐づいていません。</p>
          ) : (
            <div className="mt-3 overflow-x-auto">
              <table className="min-w-[480px] w-full border-collapse text-[13px]">
                <thead>
                  <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">施策</th>
                    <th className="px-3 py-2 font-medium">紐づくインシデント件数</th>
                  </tr>
                </thead>
                <tbody>
                  {data.measureIncidentLinks.map((m) => (
                    <tr key={m.measure_id} className="border-b border-[var(--border)] last:border-0">
                      <td className="px-3 py-2">{m.measure_key} {m.measure_name}</td>
                      <td className="px-3 py-2 text-[var(--muted)]">{m.linked_incident_count}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      </>}
    </div>
  );
}
