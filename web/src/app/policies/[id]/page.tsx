import Link from 'next/link';
import { getPolicyDetail, type PolicyVersionRow } from '@/lib/policyRegister';
import { lineDiff, diffStats } from '@/lib/simpleDiff';
import { createPolicyDraft, approvePolicyVersion, activatePolicyVersion } from '@/app/policies/actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: '規程文書 版履歴' };

type Params = Promise<{ id: string }>;
type SearchParams = Promise<{ mode?: string }>;

function fmt(value: string | Date | null): string {
  if (!value) return '—';
  return new Date(value).toLocaleString('ja-JP');
}

// effective_from(date型)専用。fmt()は timestamptz(approved_at等、実時刻を持つ)を
// 前提にしており、date型にそのまま使うとtoLocaleString()が実行環境のtimezoneに
// 依存して表示日がずれうる(Codexレビュー2026-09-02指摘)。この値はSQL側で
// ::text済みのYYYY-MM-DD文字列なので、そのまま表示する。
function fmtDate(value: string | null): string {
  return value ?? '—';
}

function VersionBadge({ v }: { v: PolicyVersionRow }) {
  if (v.is_current) return <span className="badge badge-done">現行</span>;
  if (v.superseded_at) return <span className="badge badge-archived">失効</span>;
  if (v.approved_at) return <span className="badge badge-active">承認済み（未有効化）</span>;
  return <span className="badge badge-on-hold">下書き</span>;
}

function DiffView({ before, after, beforeLabel, afterLabel }: {
  before: string;
  after: string;
  beforeLabel: string;
  afterLabel: string;
}) {
  const lines = lineDiff(before, after);
  const stats = diffStats(lines);
  return (
    <div className="rounded-[var(--radius-sm)] border border-[var(--border)]">
      <div className="flex items-center justify-between border-b border-[var(--border)] bg-[var(--surface-2)] px-3 py-1.5 text-[11px] text-[var(--muted)]">
        <span>{beforeLabel} → {afterLabel}</span>
        <span>
          <span className="text-[var(--success,#0a6b48)]">+{stats.added}</span>
          {' / '}
          <span className="text-[var(--danger)]">-{stats.removed}</span>
        </span>
      </div>
      <pre className="max-h-[420px] overflow-auto p-3 text-[12px] leading-[1.6] whitespace-pre-wrap">
        {lines.map((l, idx) => (
          <div
            key={idx}
            className={
              l.kind === 'added'
                ? 'bg-[var(--success-weak)] text-[var(--badge-success-fg)]'
                : l.kind === 'removed'
                  ? 'bg-[var(--danger-weak)] text-[var(--badge-danger-fg)] line-through decoration-1'
                  : ''
            }
          >
            {l.kind === 'added' ? '+ ' : l.kind === 'removed' ? '- ' : '  '}
            {l.text || ' '}
          </div>
        ))}
      </pre>
    </div>
  );
}

export default async function PolicyDetailPage({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  const [{ id }, sp] = await Promise.all([params, searchParams]);
  const result = await getPolicyDetail(id);
  const detail = result.ok ? result.data : null;
  const mode = sp.mode === 'isms' || sp.mode === 'risk' ? sp.mode : null;

  return (
    <div className="flex flex-col gap-5">
      <div>
        <Link className="text-[12px] text-[var(--muted)] underline" href={mode ? `/policies?mode=${mode}` : '/policies'}>
          ← 規程文書一覧へ戻る
        </Link>
        {detail ? (
          <>
            <h1 className="mt-2 text-[21px] font-semibold">{detail.policy.title}</h1>
            {detail.policy.catalog_key && (
              <p className="mt-1 text-[12px] font-[family-name:var(--font-geist-mono)] text-[var(--muted)]">
                {detail.policy.catalog_key}
              </p>
            )}
          </>
        ) : (
          <h1 className="mt-2 text-[21px] font-semibold">規程文書 版履歴</h1>
        )}
      </div>

      {!detail ? (
        <div className="card p-5 text-[13px] text-[var(--muted)]">
          対象の規程が見つからないか、テナントセッションが必要です。
        </div>
      ) : (
        <>
          <section className="card p-4">
            <h2 className="mb-3 text-[15px] font-semibold">版履歴</h2>
            <p className="mb-3 text-[12px] text-[var(--muted)]">
              履歴は追記型です。承認済みの版は本文・版番号を後から書き換えられません（DB が拒否します）。
              内容を変えるときは新しい版を追加し、承認 → 有効化の順に進めます。
            </p>
            <div className="flex flex-col gap-3">
              {detail.versions.map((v, idx) => {
                const prev = detail.versions[idx + 1]; // 一つ古い版（降順表示のため+1）
                const compareBase = prev ?? (detail.catalogBody !== null ? { body_md: detail.catalogBody, version: 0 } : null);
                const compareLabel = prev ? `v${prev.version}` : detail.catalogBody !== null ? '標準規程' : null;
                return (
                  <div key={v.id} className="rounded-[var(--radius-sm)] border border-[var(--border)] p-3">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="text-[13px] font-semibold">version {v.version}</span>
                      <VersionBadge v={v} />
                      {v.is_placeholder && <span className="badge badge-lead">仮置き本文</span>}
                      <span className="ml-auto text-[11px] text-[var(--muted)]">作成: {fmt(v.created_at)}</span>
                    </div>
                    <dl className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-[11px] text-[var(--muted)] md:grid-cols-4">
                      <div><dt className="inline">承認: </dt><dd className="inline">{fmt(v.approved_at)}</dd></div>
                      <div><dt className="inline">有効化: </dt><dd className="inline">{fmtDate(v.effective_from)}</dd></div>
                      <div><dt className="inline">失効: </dt><dd className="inline">{fmt(v.superseded_at)}</dd></div>
                      <div><dt className="inline">標準からの差分条項数: </dt><dd className="inline">{v.diff_clause_count}</dd></div>
                    </dl>

                    <div className="mt-3 flex flex-wrap gap-2">
                      {!v.approved_at && (
                        <form action={approvePolicyVersion}>
                          {mode ? <input type="hidden" name="mode" value={mode} /> : null}
                          <input type="hidden" name="policy_id" value={detail.policy.id} />
                          <input type="hidden" name="version_id" value={v.id} />
                          <button className="btn btn-primary" type="submit">この版を承認する</button>
                        </form>
                      )}
                      {v.approved_at && !v.is_current && (
                        <form action={activatePolicyVersion} className="flex items-center gap-2">
                          {mode ? <input type="hidden" name="mode" value={mode} /> : null}
                          <input type="hidden" name="policy_id" value={detail.policy.id} />
                          <input type="hidden" name="version_id" value={v.id} />
                          <label className="text-[11px] text-[var(--muted)]">
                            有効化日
                            <input
                              className="input ml-1 h-7 w-[140px] text-[12px]"
                              type="date"
                              name="effective_from"
                              defaultValue={new Date().toISOString().slice(0, 10)}
                            />
                          </label>
                          <button className="btn btn-primary" type="submit">この版を有効化する</button>
                        </form>
                      )}
                    </div>

                    {compareBase && compareLabel && (
                      <details className="mt-3">
                        <summary className="cursor-pointer text-[12px] underline underline-offset-2">
                          {compareLabel} との差分を見る
                        </summary>
                        <div className="mt-2">
                          <DiffView
                            before={compareBase.body_md}
                            after={v.body_md}
                            beforeLabel={compareLabel}
                            afterLabel={`v${v.version}`}
                          />
                        </div>
                      </details>
                    )}
                  </div>
                );
              })}
            </div>
          </section>

          <form action={createPolicyDraft} className="card grid gap-3 p-4">
            {mode ? <input type="hidden" name="mode" value={mode} /> : null}
            <input type="hidden" name="policy_id" value={detail.policy.id} />
            <h2 className="text-[15px] font-semibold">新しい下書き版を追加</h2>
            <p className="text-[12px] text-[var(--muted)]">
              現行版・標準規程の本文をコピーして書き換えてから提出してください。保存すると新しい版番号（下書き）として追加されます。
            </p>
            <textarea
              className="input min-h-[240px] font-[family-name:var(--font-geist-mono)] text-[12px]"
              name="body_md"
              defaultValue={detail.versions[0]?.body_md ?? detail.catalogBody ?? ''}
              required
            />
            <div>
              <button className="btn btn-primary" type="submit">下書きとして保存</button>
            </div>
          </form>
        </>
      )}
    </div>
  );
}
