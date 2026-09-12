import { getCurrentDom, getRiskCriteria } from '@/lib/catalog';

export const dynamic = 'force-dynamic';

export const metadata = { title: 'リスク基準' };

type Band = 'top_priority' | 'action' | 'consider' | 'accept' | 'unknown';

const BAND_STYLE: Record<Band, { label: string; bg: string; fg: string }> = {
  top_priority: { label: '最優先', bg: 'var(--danger-weak)', fg: 'var(--badge-danger-fg)' },
  action: { label: '対応', bg: 'var(--warning-weak)', fg: 'var(--badge-warning-fg)' },
  consider: { label: '検討', bg: 'var(--accent-weak)', fg: 'var(--accent)' },
  accept: { label: '受容', bg: 'var(--success-weak)', fg: 'var(--badge-success-fg)' },
  unknown: { label: '未定義', bg: 'var(--surface-3)', fg: 'var(--muted)' },
};

export default async function CriteriaPage() {
  const [criteria, dom] = await Promise.all([getRiskCriteria(), getCurrentDom()]);

  if (!criteria) {
    return (
      <div className="card p-6 text-[13px] text-[var(--muted)]">
        現行 DOM のリスク基準が投入されていません（make seed を実行してください）。
      </div>
    );
  }

  const bandOf = (v: number): Band => {
    if (criteria.band_top_priority.includes(v)) return 'top_priority';
    if (criteria.band_action.includes(v)) return 'action';
    if (criteria.band_consider.includes(v)) return 'consider';
    if (criteria.band_accept.includes(v)) return 'accept';
    return 'unknown';
  };

  const levels = [5, 4, 3, 2, 1]; // Vertical axis (likelihood): higher at the top
  // Number of "distinct values" in the band. Summing array lengths would show 14 even if the same value
  // appeared twice, which would not prove that "all possible values are defined".
  const defined = new Set([
    ...criteria.band_top_priority,
    ...criteria.band_action,
    ...criteria.band_consider,
    ...criteria.band_accept,
  ]).size;
  // Products actually possible on 5x5 (14 distinct). Any gap in the definitions shows up as a difference here.
  const reachable = new Set([1, 2, 3, 4, 5].flatMap((a) => [1, 2, 3, 4, 5].map((b) => a * b)));
  const undefinedValues = [...reachable].filter((v) => bandOf(v) === 'unknown').sort((a, b) => a - b);

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-[20px] font-semibold tracking-tight">リスク基準（5×5）</h1>
        <p className="mt-1 max-w-[860px] text-[13px] text-[var(--muted)]">
          発生可能性 × 影響度 の積で帯を決める。帯は<b>取りうる 14 通りの値を集合として持つ</b>ので、
          境界の解釈が揺れない（{'>='} で書くと「10 は対応か検討か」で毎回もめる）。
          {dom && <>　DOM {dom.version}。</>}
        </p>
      </div>

      <section className="card p-4">
        <div className="overflow-x-auto">
          <table className="border-collapse text-[13px]">
            <thead>
              <tr>
                <th className="px-2 py-1 text-[11px] font-medium text-[var(--muted)]">発生↓ / 影響→</th>
                {[1, 2, 3, 4, 5].map((i) => (
                  <th key={i} className="w-[92px] px-2 py-1 text-center text-[12px] font-medium">
                    {i}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {levels.map((l) => (
                <tr key={l}>
                  <th className="px-2 py-1 text-center text-[12px] font-medium">{l}</th>
                  {[1, 2, 3, 4, 5].map((i) => {
                    const v = l * i;
                    const b = bandOf(v);
                    const st = BAND_STYLE[b];
                    return (
                      <td
                        key={i}
                        className="h-[58px] border border-[var(--border)] px-2 py-1 text-center align-middle"
                        style={{ background: st.bg, color: st.fg }}
                      >
                        <div className="text-[16px] font-semibold">{v}</div>
                        <div className="text-[11px]">{st.label}</div>
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="mt-3 text-[11px] text-[var(--muted)]">
          定義済みの値: {defined} 通り（5×5 で取りうる相異なる積は {reachable.size} 通り）。
          {undefinedValues.length > 0 && (
            <span className="ms-1 text-[var(--danger)]">
              未定義: {undefinedValues.join(', ')}
            </span>
          )}
        </p>
      </section>

      <section className="card p-4">
        <h2 className="mb-3 text-[13px] font-semibold">帯と期限</h2>
        <dl className="grid gap-3 text-[13px] sm:grid-cols-2">
          <div>
            <dt className="text-[12px] text-[var(--muted)]">最優先の是正期限</dt>
            <dd className="mt-0.5 text-[16px] font-semibold">{criteria.due_days_top_priority} 日</dd>
          </div>
          <div>
            <dt className="text-[12px] text-[var(--muted)]">対応の是正期限</dt>
            <dd className="mt-0.5 text-[16px] font-semibold">{criteria.due_days_action} 日</dd>
          </div>
          <div className="sm:col-span-2">
            <dt className="text-[12px] text-[var(--muted)]">機密性・完全性・可用性の合成</dt>
            <dd className="mt-0.5">
              {criteria.impact_sec_formula === 'max_cia' ? '3 つのうち最大値を採る（max_cia）' : criteria.impact_sec_formula}
            </dd>
          </div>
        </dl>
        <div className="mt-4 grid gap-2 text-[12px] sm:grid-cols-4">
          {(['top_priority', 'action', 'consider', 'accept'] as Band[]).map((b) => (
            <div
              key={b}
              className="rounded-[var(--radius)] px-3 py-2"
              style={{ background: BAND_STYLE[b].bg, color: BAND_STYLE[b].fg }}
            >
              <div className="font-semibold">{BAND_STYLE[b].label}</div>
              <div className="mt-0.5 font-[family-name:var(--font-geist-mono)]">
                {(b === 'top_priority'
                  ? criteria.band_top_priority
                  : b === 'action'
                    ? criteria.band_action
                    : b === 'consider'
                      ? criteria.band_consider
                      : criteria.band_accept
                ).join(', ')}
              </div>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
}
