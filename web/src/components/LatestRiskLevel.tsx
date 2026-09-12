import type { SnapshotStage } from '@/lib/riskRegister';

// "Latest level" is nothing more than the number from the newest assessment.
// In the register's initial draft the post-measure one (after_measure) is the latest, so showing only the number
// **makes the effect of measures not yet implemented read as the current level**.
// Always state which stage the number is from.
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
