import Link from 'next/link';
import { CheckCircle, Circle, Warning } from '@phosphor-icons/react/dist/ssr';
import {
  ISO_STEPS,
  PHASE_LABEL,
  PHASE_ORDER,
  statusLabel,
  type StepAssessment,
} from '@/lib/isoSteps';

type IsmsStepRailProps = {
  assessments: ReadonlyMap<string, StepAssessment>;
  currentKey?: string;
  /** On detail screens, use a display that omits stage names so it does not take too much width. */
  compact?: boolean;
};

const STATUS_ICON = {
  usable: CheckCircle,
  partial: Warning,
  none: Circle,
} as const;

/**
 * ISMS progress rail. Computes no state (takes the measured evaluation from isoSteps as is).
 * Replacing this with a separate "completion rate" would make reference-material counts alone read as complete.
 */
export function IsmsStepRail({ assessments, currentKey, compact = false }: IsmsStepRailProps) {
  return (
    <nav aria-label="ISMS の 12 段階" className={compact ? 'card p-2' : 'card p-3'}>
      {!compact && (
        <div className="mb-2 px-1">
          <p className="text-[12px] font-semibold">ISMS の進め方</p>
          <p className="mt-0.5 text-[11px] text-[var(--muted)]">完了数ではなく、必要な証跡の実測を表示</p>
        </div>
      )}
      <ol className="flex flex-col gap-0.5">
        {PHASE_ORDER.map((phase) => (
          <li key={phase}>
            <p className="px-2 pb-1 pt-2 text-[10px] font-semibold uppercase tracking-[0.12em] text-[var(--muted)]">
              {PHASE_LABEL[phase]}
            </p>
            <ol className="flex flex-col gap-0.5">
              {ISO_STEPS.filter((step) => step.phase === phase).map((step) => {
                const assessment = assessments.get(step.key);
                const Icon = assessment ? STATUS_ICON[assessment.status] : Circle;
                const active = currentKey === step.key;
                return (
                  <li key={step.key}>
                    <Link
                      aria-label={compact ? `${step.ordinal}. ${step.title}: ${assessment ? statusLabel(assessment) : '状態未取得'}` : undefined}
                      aria-current={active ? 'step' : undefined}
                      className={`flex items-center gap-2 rounded-[var(--radius-sm)] px-2 py-1.5 text-[12px] transition-colors ${
                        active
                          ? 'bg-[var(--surface-3)] font-semibold text-[var(--fg)]'
                          : 'text-[var(--fg-2)] hover:bg-[var(--surface-2)]'
                      }`}
                      href={`/steps/${step.key}`}
                      title={assessment ? `${step.title}: ${statusLabel(assessment)}` : step.title}
                    >
                      <span className="w-4 shrink-0 text-right font-[family-name:var(--font-geist-mono)] text-[10px] text-[var(--muted)]">
                        {step.ordinal}
                      </span>
                      <Icon
                        size={13}
                        weight={assessment?.status === 'usable' ? 'fill' : 'bold'}
                        className={
                          assessment?.status === 'usable'
                            ? 'shrink-0 text-[var(--success)]'
                            : assessment?.status === 'partial'
                              ? 'shrink-0 text-[var(--warning)]'
                              : 'shrink-0 text-[var(--muted)]'
                        }
                        aria-hidden
                      />
                      {!compact && <span className="min-w-0 truncate">{step.title}</span>}
                    </Link>
                  </li>
                );
              })}
            </ol>
          </li>
        ))}
      </ol>
    </nav>
  );
}
