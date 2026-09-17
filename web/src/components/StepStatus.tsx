import Link from 'next/link';
import {
  BookOpen,
  CheckCircle,
  Circle,
  EyeSlash,
  Warning,
} from '@phosphor-icons/react/dist/ssr';
import {
  TOOL_STATE_LABEL,
  statusLabel,
  type PolicyBodyState,
  type StepAssessment,
  type StepStatus,
  type StepTool,
  type ToolState,
} from '@/lib/isoSteps';

// 段階と道具の状態を出すところ。表示のためだけの部品で、判定は一切しない
// （判定は lib/isoSteps.ts。画面ごとに判定を書くと、画面ごとに違う嘘をつき始める）。

const STATUS_STYLE: Record<StepStatus, { cls: string; Icon: typeof CheckCircle }> = {
  usable: { cls: 'badge badge-done', Icon: CheckCircle },
  partial: { cls: 'badge badge-active', Icon: BookOpen },
  none: { cls: 'badge badge-lead', Icon: Circle },
};

export function StatusBadge({ assessment }: { assessment: StepAssessment }) {
  const { cls, Icon } = STATUS_STYLE[assessment.status];
  return (
    <span className={cls}>
      <Icon size={13} weight="bold" aria-hidden />
      {statusLabel(assessment)}
    </span>
  );
}

export function UnreadableBadge() {
  return (
    <span
      className="badge badge-on-hold"
      title="読める状態にない項目がある（テナント文脈が無い・セッションが無効・権限が足りない・件数が数として読めない、のいずれか）"
    >
      <EyeSlash size={13} weight="bold" aria-hidden />
      読めない項目あり
    </span>
  );
}

const TOOL_STATE_STYLE: Record<ToolState['kind'], string> = {
  present: 'badge badge-done',
  placeholder: 'badge badge-on-hold',
  malformed: 'badge badge-danger',
  empty: 'badge badge-on-hold',
  unbuilt: 'badge badge-lead',
  unreadable: 'badge badge-on-hold',
};

/** 状態の中身を、数を丸めずに一言にする。 */
export function toolStateDetail(state: ToolState): string {
  switch (state.kind) {
    case 'present':
      return `${state.count} 件`;
    case 'placeholder':
      return `${state.total} 件のうち中身があるのは ${state.count} 件`;
    case 'malformed':
      return `${state.total} 件のうち形式が合っているのは ${state.wellFormed} 件`;
    case 'empty':
      return '0 件';
    case 'unbuilt':
      return 'この仕組みに機能が無い';
    case 'unreadable':
      return '読める状態にない（0 件と決まったわけではない）';
  }
}

export function ToolStateBadge({ state }: { state: ToolState }) {
  return <span className={TOOL_STATE_STYLE[state.kind]}>{TOOL_STATE_LABEL[state.kind]}</span>;
}

/** 規程 1 本の本文の状態。判定は isoSteps 側で行い、ここは出すだけ。 */
export function PolicyBodyBadge({ state }: { state: PolicyBodyState }) {
  if (state === 'substantive') return null;
  return (
    <span className="badge badge-on-hold">
      {state === 'placeholder' ? '本文が仮置き' : 'DB に無い'}
    </span>
  );
}

/** 段階の詳細に並べる道具 1 件。 */
export function ToolRow({ tool, state }: { tool: StepTool; state: ToolState }) {
  const title = (
    <span className="font-medium">
      {tool.label}
      {tool.required && (
        <span className="ml-1.5 text-[11px] font-normal text-[var(--muted)]">要る</span>
      )}
    </span>
  );
  return (
    <li className="flex flex-col gap-1 py-3 sm:flex-row sm:items-baseline sm:gap-4">
      <div className="flex min-w-0 flex-1 flex-col gap-0.5">
        {tool.href ? (
          <Link className="underline decoration-[var(--border-strong)] underline-offset-2" href={tool.href}>
            {title}
          </Link>
        ) : (
          title
        )}
        <span className="text-[12px] text-[var(--muted)]">{tool.note}</span>
      </div>
      <div className="flex shrink-0 items-center gap-2">
        <span className="text-[12px] text-[var(--muted)]">{toolStateDetail(state)}</span>
        <ToolStateBadge state={state} />
      </div>
    </li>
  );
}

/**
 * 要るのにそろっていない道具を、名前で挙げる。
 *
 * span で返す。段階一覧では 1 行が丸ごとリンク（a 要素）なので、
 * p で返すと a > span > p という不正な入れ子になる。
 */
export function MissingLine({ missing }: { missing: StepTool[] }) {
  if (missing.length === 0) return null;
  return (
    <span className="flex items-start gap-1.5 text-[12px] text-[var(--fg-2)]">
      <Warning size={14} weight="bold" className="mt-[2px] shrink-0 text-[var(--warning)]" aria-hidden />
      <span>そろっていないもの: {missing.map((m) => m.label).join('、')}</span>
    </span>
  );
}
