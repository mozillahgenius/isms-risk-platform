import type { SnapshotStage } from '@/lib/riskRegister';

// 「最新レベル」は、いちばん新しい評価の数字でしかない。
// 台帳の初期案では施策後（after_measure）が最新になるので、数字だけを出すと
// **まだ実施していない施策の効果を、現在の水準として読ませてしまう**。
// どの段階の数字なのかを必ず添える。
const STAGE_LABEL: Record<SnapshotStage, string> = {
  inherent: '固有',
  before_measure: '施策前',
  after_measure: '施策後',
};

export function LatestRiskLevel({
  level,
  stage,
}: {
  level: number | null;
  stage: SnapshotStage | null;
}) {
  if (level === null) return <span className="text-[var(--muted)]">未評価</span>;
  return (
    <span className="inline-flex flex-col gap-0.5">
      <span className="tabular-nums">{level}</span>
      <span className="text-[11px] text-[var(--muted)]">
        {stage ? STAGE_LABEL[stage] : '段階不明'}
        {stage === 'after_measure' ? '（施策の実施状況は施策マスタを見る）' : ''}
      </span>
    </span>
  );
}
