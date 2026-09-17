import type { SnapshotRow } from '@/lib/riskRegister';

const LABELS = {
  inherent: '固有リスク',
  before_measure: '施策前',
  after_measure: '施策後',
} as const;

const MAP_MARK = { inherent: '固', before_measure: '前', after_measure: '後' } as const;

// SnapshotRow.assessed_on は SQL側で ::text 済みなので常に "YYYY-MM-DD" 文字列。
// toISOString()経由のDate変換はUTC化されJSTでの現状/目標判定がずれうるため、
// Dateを受け付ける分岐は持たない(Codexレビュー2026-09-02指摘)。
function dateText(value: string): string {
  return value;
}

function levelClass(level: number): string {
  if (level >= 16) return 'bg-[var(--danger-weak)] text-[var(--badge-danger-fg)]';
  if (level >= 9) return 'bg-[var(--warning-weak)] text-[var(--badge-warning-fg)]';
  return 'bg-[var(--success-weak)] text-[var(--badge-success-fg)]';
}

// today() はサーバー側でのみレンダリングする(このコンポーネントは 'use client' を
// 持たない)前提で、Hydrationのずれは起きない。
// toISOString()はUTC基準になるため使わない。DB側(riskRegister.tsのLATERAL JOIN)は
// Asia/Tokyo基準でCURRENT_DATE相当を計算しており、ここがUTCのままだと日付境界で
// 「目標」判定と一覧の「現状」判定が1日ずれうる(Codexレビュー2026-09-02指摘)。
export function today(): string {
  return new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Tokyo' }).format(new Date());
}

export function RiskMapTimeline({ snapshots }: { snapshots: SnapshotRow[] }) {
  const cutoff = today();
  // assessed_on <= 今日 を「評価済み(過去/現状)」、それより先を「目標(未到達)」とする。
  // 同じstageの最新1件だけを見る従来ロジックのまま目標を混ぜると、将来日付の
  // 施策後スナップショットが「現在の施策後リスク」として表示され、実際の
  // 現状評価と区別が付かなくなる(2026-09-02 実装時に発見、既存の欠陥)。
  const evaluated = snapshots.filter((s) => dateText(s.assessed_on) <= cutoff);
  const targets = snapshots.filter((s) => dateText(s.assessed_on) > cutoff);

  const latestByStage = new Map<string, SnapshotRow>();
  for (const snapshot of evaluated) latestByStage.set(snapshot.stage, snapshot);
  const latestTargetByStage = new Map<string, SnapshotRow>();
  for (const snapshot of targets) latestTargetByStage.set(snapshot.stage, snapshot);

  const mapSnapshots = [...latestByStage.values()];
  const mapTargets = [...latestTargetByStage.values()];

  return (
    <div className="flex flex-col gap-4">
      <div>
        <h2 className="text-[15px] font-semibold">リスク評価の変化</h2>
        <p className="mt-1 text-[12px] text-[var(--muted)]">
          固有リスク、施策前、施策後を同じ5×5の尺度で比較します。施策後は残余リスクです。
          評価日が未来のスナップショットは「目標」として別に扱い、現状の評価とは区別します。
        </p>
      </div>
      <div className="overflow-x-auto rounded-[var(--radius)] border border-[var(--border)]">
        <table className="min-w-[680px] w-full border-collapse text-[12px]">
          <thead>
            <tr className="border-b border-[var(--border)] text-left text-[var(--muted)]">
              <th className="px-3 py-2 font-medium">評価段階</th>
              <th className="px-3 py-2 font-medium">評価日</th>
              <th className="px-3 py-2 font-medium">発生可能性</th>
              <th className="px-3 py-2 font-medium">影響度</th>
              <th className="px-3 py-2 font-medium">リスクレベル</th>
              <th className="px-3 py-2 font-medium">施策</th>
            </tr>
          </thead>
          <tbody>
            {(['inherent', 'before_measure', 'after_measure'] as const).map((stage) => {
              const snapshot = latestByStage.get(stage);
              return (
                <tr key={stage} className="border-b border-[var(--border)] last:border-0">
                  <td className="px-3 py-2 font-medium">{LABELS[stage]}</td>
                  <td className="px-3 py-2 text-[var(--muted)]">{snapshot ? dateText(snapshot.assessed_on) : '未評価'}</td>
                  <td className="px-3 py-2">{snapshot?.probability ?? '未評価'}</td>
                  <td className="px-3 py-2">{snapshot?.impact ?? '未評価'}</td>
                  <td className="px-3 py-2">
                    {snapshot ? <span className={`badge ${levelClass(snapshot.risk_level)}`}>{snapshot.risk_level}</span> : '未評価'}
                  </td>
                  <td className="px-3 py-2 text-[var(--muted)]">{snapshot?.measure_name ?? 'なし'}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      {mapTargets.length > 0 && (
        <div className="rounded-[var(--radius)] border border-dashed border-[var(--accent)] p-3">
          <h3 className="text-[13px] font-semibold">目標(未到達)</h3>
          <p className="mt-1 text-[11px] text-[var(--muted)]">評価日が未来のスナップショット。到達すれば通常の評価として記録し直します。</p>
          <div className="mt-2 flex flex-col gap-2">
            {mapTargets.map((snapshot) => (
              <div key={snapshot.id} className="flex flex-wrap items-center gap-2 text-[12px]">
                <span className="badge badge-note">{LABELS[snapshot.stage]}</span>
                <span className="text-[var(--muted)]">目標日 {dateText(snapshot.assessed_on)}</span>
                <span className={`badge ${levelClass(snapshot.risk_level)}`}>{snapshot.risk_level}</span>
                <span className="text-[var(--muted)]">{snapshot.measure_name ?? 'なし'}</span>
              </div>
            ))}
          </div>
        </div>
      )}
      <div className="overflow-x-auto rounded-[var(--radius)] border border-[var(--border)] p-3">
        <div className="mb-2 flex items-baseline justify-between gap-3">
          <h3 className="text-[13px] font-semibold">リスクマップ</h3>
          <span className="text-[11px] text-[var(--muted)]">横軸: 発生可能性 / 縦軸: 影響度(塗りつぶし=現状、枠線のみ=目標)</span>
        </div>
        <div className="grid min-w-[420px] grid-cols-[54px_repeat(5,minmax(56px,1fr))] text-center text-[11px]">
          <div />
          {[1, 2, 3, 4, 5].map((probability) => <div key={probability} className="pb-1 text-[var(--muted)]">{probability}</div>)}
          {[5, 4, 3, 2, 1].map((impact) => (
            <div key={impact} className="contents">
              <div className="flex items-center justify-center border-r border-[var(--border)] pr-1 text-[var(--muted)]">{impact}</div>
              {[1, 2, 3, 4, 5].map((probability) => {
                const cell = mapSnapshots.filter((snapshot) => snapshot.probability === probability && snapshot.impact === impact);
                const targetCell = mapTargets.filter((snapshot) => snapshot.probability === probability && snapshot.impact === impact);
                return (
                  <div key={`${probability}-${impact}`} className="flex min-h-[48px] items-center justify-center border-b border-r border-[var(--border)] bg-[var(--surface-2)]">
                    <div className="flex flex-wrap justify-center gap-1">
                      {cell.map((snapshot) => (
                        <span key={snapshot.id} title={`${LABELS[snapshot.stage]} ${snapshot.risk_level}`} className={`h-5 w-5 rounded-full text-[10px] leading-5 ${levelClass(snapshot.risk_level)}`}>
                          {MAP_MARK[snapshot.stage]}
                        </span>
                      ))}
                      {targetCell.map((snapshot) => (
                        <span key={snapshot.id} title={`目標: ${LABELS[snapshot.stage]} ${snapshot.risk_level}(${dateText(snapshot.assessed_on)})`} className="h-5 w-5 rounded-full border-2 border-[var(--accent)] bg-transparent text-[10px] leading-[18px] text-[var(--accent)]">
                          目
                        </span>
                      ))}
                    </div>
                  </div>
                );
              })}
            </div>
          ))}
        </div>
      </div>
      {snapshots.length > 0 && (
        <details className="rounded-[var(--radius)] bg-[var(--surface-2)] p-3 text-[12px]">
          <summary className="cursor-pointer font-medium">評価根拠と出所を確認</summary>
          <div className="mt-3 flex flex-col gap-3">
            {snapshots.map((snapshot) => (
              <div key={snapshot.id} className="border-t border-[var(--border)] pt-2 first:border-0 first:pt-0">
                <div className="font-medium">{LABELS[snapshot.stage]} / {dateText(snapshot.assessed_on)}{dateText(snapshot.assessed_on) > cutoff ? '(目標)' : ''}</div>
                <p className="mt-1 text-[var(--fg-2)]">{snapshot.rationale}</p>
                <p className="mt-1 text-[11px] text-[var(--muted)]">出所: {snapshot.source_note || '未記載'}</p>
              </div>
            ))}
          </div>
        </details>
      )}
    </div>
  );
}
