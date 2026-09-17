import { Fragment } from 'react';
import Link from 'next/link';
import { ArrowRight, Info } from '@phosphor-icons/react/dist/ssr';
import { getCurrentDom, getStepBundle } from '@/lib/catalog';
import {
  CERTIFICATION,
  ISO_STEPS,
  PHASE_LABEL,
  PHASE_NOTE,
  PHASE_ORDER,
  PREPARATION,
  STATUS_BUCKETS,
  assessStep,
  assignedCalendarKeys,
  assignedPolicyKeys,
  assignedRoleKeys,
  diffAssignment,
  statusLabel,
  statusNote,
} from '@/lib/isoSteps';
import { MissingLine, StatusBadge, UnreadableBadge } from '@/components/StepStatus';
import { IsmsStepRail } from '@/components/IsmsStepRail';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'ISMSの進め方' };

export default async function Home() {
  const [dom, bundle] = await Promise.all([getCurrentDom(), getStepBundle()]);
  const { facts } = bundle;

  const assessed = ISO_STEPS.map((step) => ({ step, a: assessStep(step, facts) }));
  // 見出しは statusLabel が決める。集計だけ別の分け方をすると、
  // 一覧に出ている言葉と合計が食い違う。
  // 0 件でも「記録まで残せる」と「まだ何も無い」は必ず出す（消すと 0 が見えなくなる）。
  const tally = STATUS_BUCKETS.map((label) => {
    const rows = assessed.filter((x) => statusLabel(x.a) === label);
    return { label, n: rows.length, note: rows[0] ? statusNote(rows[0].a) : '' };
  }).filter((b) => b.n > 0 || b.label === '記録まで残せる' || b.label === 'まだ何も無い');

  // 割り当ての取りこぼしを双方向で見る。片方向だと設定側のタイポを拾えない。
  const diffs = [
    { label: '規程', d: diffAssignment(assignedPolicyKeys(), Object.keys(facts.policyBodies)) },
    { label: '年間行事', d: diffAssignment(assignedCalendarKeys(), facts.calendarKeys) },
    { label: 'ロール', d: diffAssignment(assignedRoleKeys(), facts.roleKeys) },
  ];
  const unassigned = diffs.reduce(
    (n, x) => n + x.d.inDbOnly.length + x.d.inConfigOnly.length,
    0,
  );
  const assessmentByKey = new Map(assessed.map(({ step, a }) => [step.key, a]));

  return (
    // 読むための画面なので、幅を詰める。1400px いっぱいに広げると、
    // 段階名と状態バッジが視線の端どうしに離れて対応が取れなくなる。
    <div className="flex max-w-[1180px] flex-col gap-8">
      <section className="max-w-[860px]">
        <h1 className="text-[24px] font-semibold tracking-tight">ISMS の進め方</h1>
        <p className="mt-2 text-[13px] leading-relaxed text-[var(--fg-2)]">
          情報セキュリティマネジメントシステムを立ち上げ、回していくまでの流れを、
          実務でよく使われる順に 12 段階へ並べたもの。段階ごとに、この仕組みが
          何を持っていて何を持っていないかを、その場で実測して出す。
        </p>
        <p className="mt-3 flex items-start gap-2 rounded-[var(--radius)] bg-[var(--surface-2)] p-3 text-[12px] leading-relaxed text-[var(--fg-2)]">
          <Info size={15} weight="bold" className="mt-[2px] shrink-0 text-[var(--muted)]" aria-hidden />
          <span>
            ISO/IEC 27001 は<b>導入の手順を段階として規定していない</b>。規格が定めるのは
            要求事項（箇条）であって着手の順番ではないので、この並びは一例。
            各段階に箇条番号を併記してあるので、規格の側と突き合わせて読める。
          </span>
        </p>
        {dom && (
          <p className="mt-2 text-[12px] text-[var(--muted)]">
            判定に使う下敷きは標準運用モデル DOM {dom.version}。
            <Link className="ml-1 underline" href="/catalog">
              カタログの中身と出所を見る
            </Link>
          </p>
        )}
      </section>

      <section>
        <h2 className="text-[13px] font-semibold text-[var(--muted)]">12 段階のいまの状態</h2>
        <div className="mt-2 flex flex-wrap gap-x-8 gap-y-3">
          {tally.map(({ label, n, note }) => (
            <div key={label}>
              <div className="text-[26px] font-semibold tabular-nums">{n}</div>
              <div className="text-[12px] font-medium">{label}</div>
              <div className="max-w-[280px] text-[11px] text-[var(--muted)]">{note}</div>
            </div>
          ))}
        </div>
      </section>

      <section className="grid gap-4 lg:grid-cols-[260px_minmax(0,1fr)] lg:items-start">
        <div className="lg:sticky lg:top-5">
          <IsmsStepRail assessments={assessmentByKey} />
        </div>
        <div className="card p-4">
          <h2 className="text-[14px] font-semibold">次に進める方法</h2>
          <p className="mt-1 text-[12px] leading-relaxed text-[var(--muted)]">
            左の段階を選ぶと、目的、いま不足している証跡、次に行う一つの操作、要求事項、前後の段階を同じ順番で確認できます。
            カタログの件数や雛形の有無だけを、実施済み・完了とは表示しません。
          </p>
          <Link href={`/steps/${ISO_STEPS[0].key}`} className="btn mt-3">
            段階 1 から確認する
            <ArrowRight size={14} weight="bold" aria-hidden />
          </Link>
        </div>
      </section>

      <section className="card border-dashed p-4">
        <h2 className="text-[13px] font-semibold">{PREPARATION.title}</h2>
        <p className="mt-1 max-w-[820px] text-[12px] text-[var(--muted)]">{PREPARATION.detail}</p>
        <p className="mt-1 text-[11px] text-[var(--muted)]">
          規格の要求事項ではないので番号を振っていない。
        </p>
      </section>

      {PHASE_ORDER.map((phase) => {
        const rows = assessed.filter((x) => x.step.phase === phase);
        if (rows.length === 0) return null;
        return (
          <section key={phase}>
            <div className="mb-3 flex items-baseline gap-3 border-b border-[var(--border)] pb-2">
              <h2 className="text-[16px] font-semibold tracking-tight">{PHASE_LABEL[phase]}</h2>
              <p className="text-[12px] text-[var(--muted)]">{PHASE_NOTE[phase]}</p>
            </div>
            <ol className="flex flex-col gap-2">
              {rows.map(({ step, a }) => (
                <li key={step.key}>
                  <Link
                    href={`/steps/${step.key}`}
                    className="card card-hover flex flex-col gap-2 p-4 sm:flex-row sm:items-start sm:gap-4"
                  >
                    <span className="shrink-0 text-[13px] font-semibold tabular-nums text-[var(--muted)] sm:w-8 sm:pt-[3px]">
                      {step.ordinal}
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="flex flex-wrap items-center gap-x-3 gap-y-1">
                        <span className="text-[15px] font-semibold">{step.title}</span>
                        <span className="flex flex-wrap gap-1">
                          {step.clauses
                            .filter((c) => c.scope === 'primary')
                            .map((c) => (
                              <span
                                key={c.ref}
                                className="rounded-[var(--radius-sm)] bg-[var(--surface-2)] px-1.5 py-[1px] font-[family-name:var(--font-geist-mono)] text-[11px] text-[var(--fg-2)]"
                              >
                                {c.ref}
                              </span>
                            ))}
                        </span>
                      </span>
                      <span className="mt-1 block text-[12px] leading-relaxed text-[var(--muted)]">
                        {step.purpose}
                      </span>
                      <span className="mt-1.5 block">
                        <MissingLine missing={a.missingRequired} />
                      </span>
                    </span>
                    <span className="flex shrink-0 flex-wrap items-center gap-1.5 sm:pt-[3px]">
                      <StatusBadge assessment={a} />
                      {a.hasUnreadable && <UnreadableBadge />}
                      <ArrowRight
                        size={14}
                        weight="bold"
                        className="text-[var(--muted)]"
                        aria-hidden
                      />
                    </span>
                  </Link>
                </li>
              ))}
            </ol>
          </section>
        );
      })}

      <section className="card border-dashed p-4">
        <h2 className="text-[13px] font-semibold">{CERTIFICATION.title}</h2>
        <p className="mt-1 max-w-[820px] text-[12px] text-[var(--muted)]">{CERTIFICATION.detail}</p>
      </section>

      <section>
        <h2 className="text-[13px] font-semibold">段階に割り当てていないもの</h2>
        <p className="mt-1 max-w-[860px] text-[12px] text-[var(--muted)]">
          カタログの規程・年間行事・ロールは、それぞれ段階に割り当ててある。
          割り当て表と DB の実測を<b>双方向</b>で突き合わせ、食い違いをここに出す。
          seed に行を足して割り当てを忘れた場合と、存在しないキーを書いた場合の両方がここに出る。
        </p>
        {unassigned === 0 ? (
          <p className="mt-2 text-[13px]">
            食い違いなし（規程 {Object.keys(facts.policyBodies).length} 件・年間行事{' '}
            {facts.calendarKeys.length} 件・ロール {facts.roleKeys.length} 件が、すべてどこかの段階に
            割り当たっている）。
          </p>
        ) : (
          <ul className="mt-2 flex flex-col gap-1 text-[13px] text-[var(--danger)]">
            {diffs.map(({ label, d }) => (
              <Fragment key={label}>
                {d.inDbOnly.length > 0 && (
                  <li key={`${label}-db`}>
                    DB にあるのに割り当てていない{label}: {d.inDbOnly.join('、')}
                  </li>
                )}
                {d.inConfigOnly.length > 0 && (
                  <li key={`${label}-cfg`}>
                    割り当て表にあるのに DB に無い{label}: {d.inConfigOnly.join('、')}
                  </li>
                )}
              </Fragment>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
