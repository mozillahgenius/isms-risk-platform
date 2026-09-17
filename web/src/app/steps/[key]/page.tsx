import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft, ArrowRight, Info } from '@phosphor-icons/react/dist/ssr';
import { getStepBundle } from '@/lib/catalog';
import {
  ISO_STEPS,
  PHASE_LABEL,
  assessStep,
  getStep,
  policyBodyState,
  stepNeighbors,
  type Clause,
} from '@/lib/isoSteps';
import {
  MissingLine,
  PolicyBodyBadge,
  StatusBadge,
  ToolRow,
  UnreadableBadge,
} from '@/components/StepStatus';
import { IsmsStepRail } from '@/components/IsmsStepRail';

export const dynamic = 'force-dynamic';

// 段階ごとに違うページなので、ブラウザのタブでも見分けられるようにする。
// 未知のキーでは DB を読まずに既定へ落とす（ここで 404 にはしない。本体側で notFound する）。
export async function generateMetadata({ params }: { params: Promise<{ key: string }> }) {
  const { key } = await params;
  const step = getStep(key);
  return { title: step ? `${step.ordinal}. ${step.title}` : '段階が見つかりません' };
}


function ClauseList({ clauses }: { clauses: Clause[] }) {
  return (
    <ul className="flex flex-col divide-y divide-[var(--border)]">
      {clauses.map((c) => (
        <li key={c.ref} className="flex flex-col gap-0.5 py-2 sm:flex-row sm:gap-3">
          <span className="w-[70px] shrink-0 font-[family-name:var(--font-geist-mono)] text-[12px] text-[var(--fg-2)]">
            {c.ref}
          </span>
          <span className="min-w-0 flex-1">
            <span className="text-[13px]">{c.title}</span>
            {c.scope === 'cross' && (
              <span className="ml-2 badge badge-lead">この段階だけのものではない</span>
            )}
            {c.note && <span className="mt-0.5 block text-[12px] text-[var(--muted)]">{c.note}</span>}
          </span>
        </li>
      ))}
    </ul>
  );
}

export default async function StepPage({ params }: { params: Promise<{ key: string }> }) {
  const { key } = await params;

  // **DB を読む前にキーを検証する。**
  // 先に DB を読むと、DB が落ちているときに未知のキーまで 500 になり、
  // 「そんなページは無い」と「いま読めない」が区別できなくなる。
  const step = getStep(key);
  if (!step) notFound();

  // 判定用と表示用で同じ表を二度読まない。1 回で両方を取る。
  const { facts, policies, calendar, roles } = await getStepBundle();

  const a = assessStep(step, facts);
  const { prev, next } = stepNeighbors(step.key);

  const stepPolicies = policies.filter((p) => step.policyKeys.includes(p.key));
  const stepCalendar = calendar.filter((e) => step.calendarKeys.includes(e.key));
  const stepRoles = roles.filter((r) => (step.roleKeys as string[]).includes(r.key));
  // 割り当て表にあるのに DB に無いものは、黙って落とさず名前を出す。
  const missingPolicyKeys = step.policyKeys.filter((k) => !policies.some((p) => p.key === k));
  const missingCalendarKeys = step.calendarKeys.filter((k) => !calendar.some((e) => e.key === k));
  const missingRoleKeys = step.roleKeys.filter((k) => !roles.some((r) => r.key === k));

  const references = a.tools.filter((t) => t.tool.role === 'reference');
  const records = a.tools.filter((t) => t.tool.role === 'record');
  const nextRequiredTool = a.missingRequired[0];
  const firstActionExample = step.actions[0];
  const assessmentByKey = new Map(ISO_STEPS.map((item) => [item.key, assessStep(item, facts)]));

  return (
    // 読むための画面なので幅を詰める（トップと同じ理由）。
    <div className="grid max-w-[1040px] gap-7 lg:grid-cols-[minmax(0,1fr)_126px] lg:items-start">
      <div className="flex min-w-0 flex-col gap-7">
      {/* パンくずに置くのは、行き先のある先祖と現在地だけ。
          フェーズ（計画・実施・点検・改善）には専用のページが無いので、
          ここに挟むと「戻れない階層」ができる。フェーズは下の見出し側で出す。 */}
      <nav aria-label="現在位置" className="text-[12px] text-[var(--muted)]">
        <Link className="underline" href="/">
          ISMS の進め方
        </Link>
        <span aria-hidden className="mx-1.5">
          /
        </span>
        <span aria-current="page">{step.title}</span>
      </nav>

      <header className="max-w-[860px]">
        <div className="flex flex-wrap items-center gap-3">
          <span className="text-[13px] font-semibold tabular-nums text-[var(--muted)]">
            {PHASE_LABEL[step.phase]}・段階 {step.ordinal} / 12
          </span>
          <StatusBadge assessment={a} />
          {a.hasUnreadable && <UnreadableBadge />}
        </div>
        <h1 className="mt-1.5 text-[24px] font-semibold tracking-tight">{step.title}</h1>
        <p className="mt-2 text-[13px] leading-relaxed text-[var(--fg-2)]">{step.purpose}</p>
        {step.caveat && (
          <p className="mt-3 flex items-start gap-2 rounded-[var(--radius)] bg-[var(--surface-2)] p-3 text-[12px] leading-relaxed text-[var(--fg-2)]">
            <Info size={15} weight="bold" className="mt-[2px] shrink-0 text-[var(--muted)]" aria-hidden />
            <span>{step.caveat}</span>
          </p>
        )}
        <div className="mt-3">
          <MissingLine missing={a.missingRequired} />
        </div>
      </header>

      <section>
        <div className="card border-[var(--border-strong)] p-4">
          <p className="text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--muted)]">最初の作業例</p>
          <p className="mt-1 text-[14px] font-medium">{firstActionExample}</p>
          {nextRequiredTool && (
            <p className="mt-2 text-[12px] text-[var(--muted)]">
              先にそろえるもの: {nextRequiredTool.label}
              {nextRequiredTool.href ? (
                <Link className="ml-2 underline" href={nextRequiredTool.href}>
                  開く
                </Link>
              ) : (
                '（この仕組みには記録機能がありません）'
              )}
            </p>
          )}
        </div>
      </section>

      <section>
        <h2 className="mb-1 text-[15px] font-semibold">この段階で行うこと</h2>
        <ol className="ml-4 list-decimal text-[13px] leading-relaxed marker:text-[var(--muted)]">
          {step.actions.map((s) => (
            <li key={s} className="py-0.5">
              {s}
            </li>
          ))}
        </ol>
      </section>

      <section>
        <h2 className="mb-1 text-[15px] font-semibold">規格が求めていること</h2>
        <p className="mb-2 max-w-[860px] text-[12px] text-[var(--muted)]">
          JIS Q 27001:2023（ISO/IEC 27001:2022）の箇条。番号は規格の側の呼び方で、
          どの段階へ割り当てるかはこの画面が決めている。
        </p>
        <div className="card px-4 py-1">
          <ClauseList clauses={step.clauses} />
        </div>
      </section>

      <section>
        <h2 className="mb-1 text-[15px] font-semibold">参照できる下敷き</h2>
        <p className="mb-2 max-w-[860px] text-[12px] text-[var(--muted)]">
          カタログ側にあるもの。参照できるだけで、ISMS を回した証拠にはならない。
        </p>
        <ul className="card divide-y divide-[var(--border)] px-4 py-1 text-[13px]">
          {references.map(({ tool, state }) => (
            <ToolRow key={tool.key} tool={tool} state={state} />
          ))}
        </ul>
      </section>

      <section>
        <h2 className="mb-1 text-[15px] font-semibold">必須記録・証跡</h2>
        <p className="mb-2 max-w-[860px] text-[12px] text-[var(--muted)]">
          審査で証拠になるのはこちら。<b>「機能が無い」は 0 件とは違う</b>ので分けて出す。
        </p>
        <ul className="card divide-y divide-[var(--border)] px-4 py-1 text-[13px]">
          {records.map(({ tool, state }) => (
            <ToolRow key={tool.key} tool={tool} state={state} />
          ))}
        </ul>
      </section>

      {(stepPolicies.length > 0 || missingPolicyKeys.length > 0) && (
        <section>
          <h2 className="mb-1 text-[15px] font-semibold">この段階に効く規程</h2>
          <ul className="card divide-y divide-[var(--border)] px-4 py-1 text-[13px]">
            {stepPolicies.map((p) => (
              <li key={p.key} className="flex flex-wrap items-baseline gap-x-3 gap-y-1 py-3">
                <Link
                  className="underline decoration-[var(--border-strong)] underline-offset-2"
                  href={`/catalog/policies/${p.key}`}
                >
                  {p.title_ja}
                </Link>
                <span className="font-[family-name:var(--font-geist-mono)] text-[11px] text-[var(--muted)]">
                  {p.key}
                </span>
                <PolicyBodyBadge state={policyBodyState(facts, p.key)} />
              </li>
            ))}
            {missingPolicyKeys.map((k) => (
              <li key={k} className="py-3 text-[var(--danger)]">
                割り当て表にあるのに DB に無い規程: {k}
              </li>
            ))}
          </ul>
        </section>
      )}

      {(stepCalendar.length > 0 || missingCalendarKeys.length > 0) && (
        <section>
          <h2 className="mb-1 text-[15px] font-semibold">この段階に効く年間行事</h2>
          <ul className="card divide-y divide-[var(--border)] px-4 py-1 text-[13px]">
            {stepCalendar.map((e) => (
              <li key={e.key} className="flex flex-wrap items-baseline gap-x-3 gap-y-1 py-3">
                <Link
                  className="underline decoration-[var(--border-strong)] underline-offset-2"
                  href="/catalog/calendar"
                >
                  {e.name_ja}
                </Link>
                <span className="text-[12px] text-[var(--muted)]">{e.cadence}</span>
                <span className="text-[12px] text-[var(--muted)]">担当 {e.owner_role}</span>
              </li>
            ))}
            {missingCalendarKeys.map((k) => (
              <li key={k} className="py-3 text-[var(--danger)]">
                割り当て表にあるのに DB に無い年間行事: {k}
              </li>
            ))}
          </ul>
        </section>
      )}

      {(stepRoles.length > 0 || missingRoleKeys.length > 0) && (
        <section>
          <h2 className="mb-1 text-[15px] font-semibold">関わる役割</h2>
          <ul className="card divide-y divide-[var(--border)] px-4 py-1 text-[13px]">
            {missingRoleKeys.map((k) => (
              <li key={k} className="py-3 text-[var(--danger)]">
                割り当て表にあるのに DB に無い役割: {k}
              </li>
            ))}
            {stepRoles.map((r) => (
              <li key={r.key} className="py-3">
                <Link
                  className="font-medium underline decoration-[var(--border-strong)] underline-offset-2"
                  href="/catalog/org"
                >
                  {r.name_ja}
                </Link>
                <div className="mt-0.5 text-[12px] text-[var(--muted)]">{r.description}</div>
              </li>
            ))}
          </ul>
        </section>
      )}

      {/* 矢印は装飾なので、方向は言葉でも書く（読み上げでは矢印が読まれない）。 */}
      <nav aria-label="前後の段階" className="flex flex-wrap gap-3 border-t border-[var(--border)] pt-5">
        {prev && (
          <Link href={`/steps/${prev.key}`} className="btn">
            <ArrowLeft size={14} weight="bold" aria-hidden />
            前の段階: {prev.ordinal}. {prev.title}
          </Link>
        )}
        {next && (
          <Link href={`/steps/${next.key}`} className="btn">
            次の段階: {next.ordinal}. {next.title}
            <ArrowRight size={14} weight="bold" aria-hidden />
          </Link>
        )}
      </nav>
      </div>

      {/* 本文のフローに入れると、この長い導線が次の節を押し下げる。
          デスクトップでは独立した sticky aside とし、狭い画面では従来どおり非表示にする。 */}
      <aside className="hidden lg:sticky lg:top-[92px] lg:block">
        <IsmsStepRail assessments={assessmentByKey} currentKey={step.key} compact />
      </aside>
    </div>
  );
}
