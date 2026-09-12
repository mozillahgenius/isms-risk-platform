import Link from 'next/link';
import {
  getCounts,
  getTenantOperations,
  type CheckRunRow,
  type ControlImplementationStatus,
} from '@/lib/catalog';
import { frameworkForMode } from '@/lib/navigation';
import { firstParam, type RawParam } from '@/lib/searchParams';

export const dynamic = 'force-dynamic';

export const metadata = { title: '運用' };

// Screen for operations (the tenant's actual data).
// What matters is "not presenting an empty dashboard with the face of a working one".
// Write 0 only when it is known to be 0. If it could not be read, say it could not be read.

const PLANNED: { title: string; detail: string }[] = [
  { title: '逸脱と是正', detail: '検出 → 是正 → 閉じたことの再確認まで' },
  { title: '年間カレンダーの進捗', detail: '行事ごとの予定日と完了' },
];

const CONTROL_STATUS_ITEMS: { key: ControlImplementationStatus; label: string }[] = [
  { key: 'not_started', label: '未着手' },
  { key: 'designing', label: '設計中' },
  { key: 'operating', label: '運用中' },
  { key: 'verified', label: '検証済み' },
];

const RESULT_STYLE: Record<string, { label: string; cls: string }> = {
  pass: { label: '合格', cls: 'badge badge-done' },
  fail: { label: '違反あり', cls: 'badge badge-danger' },
  inconclusive: { label: '判定できない', cls: 'badge badge-on-hold' },
  error: { label: '実行できない', cls: 'badge badge-danger' },
};

type SearchParams = Promise<Record<string, RawParam>>;

function hrefForMode(pathname: string, mode: string | undefined): string {
  if (!mode) return pathname;
  const target = new URL(pathname, 'https://management.invalid');
  target.searchParams.set('mode', mode);
  return `${target.pathname}?${target.searchParams.toString()}`;
}

function ResultCell({ run }: { run: CheckRunRow }) {
  if (!run.result) {
    return <span className="badge">未実行</span>;
  }
  const st = RESULT_STYLE[run.result] ?? { label: run.result, cls: 'badge' };
  return (
    <div className="flex flex-col gap-1">
      <span className={st.cls}>{st.label}</span>
      {run.result === 'fail' && (
        <span className="text-[11px] text-[var(--danger)]">違反 {run.row_count} 件</span>
      )}
      {run.result === 'inconclusive' && run.error_detail && (
        <span className="text-[11px] text-[var(--muted)]">{run.error_detail}</span>
      )}
    </div>
  );
}

export default async function OperationsPage({ searchParams }: { searchParams: SearchParams }) {
  const sp = await searchParams;
  const requestedMode = firstParam(sp.mode);
  const mode = requestedMode === 'isms' || requestedMode === 'risk' ? requestedMode : undefined;
  const framework = firstParam(frameworkForMode('RISK-MANAGEMENT', mode));
  const [ops, counts] = await Promise.all([getTenantOperations(framework), getCounts()]);

  return (
    <div className="flex flex-col gap-5">
      <div>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <h1 className="text-[20px] font-semibold tracking-tight">運用</h1>
          <div className="flex flex-wrap justify-end gap-2">
            <Link className="btn px-3 py-1.5 text-[12px]" href={hrefForMode('/operations/device-control', mode)}>デバイス管理</Link>
            <Link className="btn px-3 py-1.5 text-[12px]" href={hrefForMode('/operations/passwords', mode)}>パスワード管理</Link>
            <Link className="btn px-3 py-1.5 text-[12px]" href={hrefForMode('/operations/identity-access', mode)}>ID・ライセンス管理</Link>
            <Link className="btn px-3 py-1.5 text-[12px]" href={hrefForMode('/settings', mode)}>収集設定を開く</Link>
          </div>
        </div>
        <p className="mt-1 max-w-[900px] text-[13px] text-[var(--muted)]">
          ルール（カタログ）ではなく、それを当てはめた<b>実際の運用データ</b>。
          チェックの実行結果と、外部サービスの収集証跡を確認できます。接続設定は収集設定から行います。
        </p>
      </div>

      {!ops.ok ? (
        <section className="card border-[var(--warning)] p-5">
          <h2 className="text-[15px] font-semibold text-[var(--badge-warning-fg)]">
            {ops.reason === 'no_token'
              ? 'この画面からは運用データを読めない（テナント文脈が無い）'
              : ops.reason === 'invalid_session'
                ? 'セッションが無効（期限切れ・失効・停止のいずれか）'
                : '運用データの読み取りに失敗した'}
          </h2>
          <p className="mt-2 max-w-[820px] text-[13px] text-[var(--fg-2)]">
            運用データ（<code className="font-[family-name:var(--font-geist-mono)]">app</code> スキーマ）は
            行レベルセキュリティで守られていて、<b>テナント文脈を確立しないと 1 行も読めない</b>。
            <b>0 件なのではなく、読める状態にない。</b>
          </p>
          {ops.reason === 'no_token' && (
            <div className="mt-3 rounded-[var(--radius)] bg-[var(--surface-2)] p-3 text-[12px] text-[var(--fg-2)]">
              <p className="mb-2">読めるようにするには、テナントを作ってトークンを渡す。</p>
              <pre className="overflow-x-auto">{`make tenant NAME="自社" DOMAIN=example.com \\
  EMAIL=admin@example.com ADMIN="管理者"

# 出たトークンを web/.env.local へ（サーバ側だけで読む）
ISMS_WEB_TENANT_TOKEN=<トークン>`}</pre>
            </div>
          )}
          <p className="mt-3 text-[11px] text-[var(--muted)]">
            SSO はまだ無い。これは 127.0.0.1 に閉じたローカル閲覧用の経路で、
            トークンはサーバ側の環境変数からしか読まない。
          </p>
        </section>
      ) : (
        <>
          {ops.data.summary && (
            <section className="card p-4">
              <div className="flex flex-wrap items-baseline gap-x-6 gap-y-2 text-[13px]">
                <div>
                  <span className="text-[12px] text-[var(--muted)]">テナント</span>
                  <div className="text-[15px] font-semibold">{ops.data.summary.tenant_name}</div>
                </div>
                <div>
                  <span className="text-[12px] text-[var(--muted)]">ドメイン</span>
                  <div>{ops.data.summary.tenant_domain}</div>
                </div>
                <div>
                  <span className="text-[12px] text-[var(--muted)]">DOM 版</span>
                  <div>{ops.data.summary.dom_version}</div>
                </div>
                <div>
                  <span className="text-[12px] text-[var(--muted)]">展開済みの規程</span>
                  <div><Link className="underline underline-offset-2" href={hrefForMode('/policies', mode)}>{ops.data.summary.policies} 本</Link></div>
                </div>
                <div>
                  <span className="text-[12px] text-[var(--muted)]">有効な役割</span>
                  <div>{ops.data.summary.members} 件</div>
                </div>
              </div>
            </section>
          )}

          <section>
            <h2 className="mb-1 text-[15px] font-semibold">テナントの運用データ</h2>
            <p className="mb-3 max-w-[900px] text-[12px] text-[var(--muted)]">
              テナント文脈を確立して読み取った実測値です。0 件も省略せず、未投入と読めない状態を分けて表示します。
            </p>
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              {[
                {
                  label: 'リスク台帳',
                  value: ops.data.register.risks,
                  detail: '有効なリスク',
                  href: hrefForMode(`/risk-management/risks?framework=${encodeURIComponent(framework ?? 'RISK-MANAGEMENT')}`, mode),
                },
                {
                  label: '情報資産',
                  value: ops.data.register.assets,
                  detail: '有効な資産',
                  href: hrefForMode(`/risk-management/assets?framework=${encodeURIComponent(framework ?? 'RISK-MANAGEMENT')}`, mode),
                },
                {
                  label: '施策',
                  value: ops.data.register.measures,
                  detail: '退役以外の施策',
                  href: hrefForMode(`/risk-management/measures?framework=${encodeURIComponent(framework ?? 'RISK-MANAGEMENT')}`, mode),
                },
                {
                  label: '評価履歴',
                  value: ops.data.register.risk_snapshots,
                  detail: 'リスク評価スナップショット',
                  href: hrefForMode(`/risk-management/risks?framework=${encodeURIComponent(framework ?? 'RISK-MANAGEMENT')}`, mode),
                },
              ].map((item) => (
                <Link key={item.label} className="card card-hover p-4" href={item.href}>
                  <div className="text-[12px] text-[var(--muted)]">{item.label}</div>
                  <div className="mt-1 text-[26px] font-semibold tabular-nums">{item.value}</div>
                  <div className="mt-1 text-[11px] text-[var(--muted)]">{item.detail}</div>
                </Link>
              ))}
            </div>

            <section id="control-implementations" className="card mt-3 p-4">
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <div>
                  <h3 className="text-[14px] font-semibold">統制の実施状況</h3>
                  <p className="mt-1 text-[12px] text-[var(--muted)]">
                    現行の実施記録 <b className="text-[var(--fg)]">{ops.data.register.control_implementations}</b> 件、
                    根拠の紐付け <b className="text-[var(--fg)]">{ops.data.register.control_evidence_links}</b> 件
                  </p>
                </div>
                {ops.data.register.control_implementations === 0 && (
                  <span className="badge badge-on-hold">0 件・未投入</span>
                )}
              </div>
              <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
                {CONTROL_STATUS_ITEMS.map((item) => (
                  <div key={item.key} className="rounded-[var(--radius-sm)] bg-[var(--surface-2)] p-3">
                    <div className="text-[11px] text-[var(--muted)]">{item.label}</div>
                    <div className="mt-1 text-[20px] font-semibold tabular-nums">
                      {ops.data.register.control_status[item.key]}
                    </div>
                  </div>
                ))}
              </div>
              <p className="mt-3 text-[12px] text-[var(--muted)]">
                {ops.data.register.control_implementations === 0
                  ? '統制の実施記録はまだ投入されていません。統制カタログの件数を実施済みとは扱いません。'
                  : '現行記録だけを数えています。過去版・期限切れの記録はこの件数に含めていません。'}
              </p>
            </section>
          </section>

          <section>
            <h2 className="mb-1 text-[15px] font-semibold">チェックの最新結果</h2>
            <p className="mb-3 max-w-[900px] text-[12px] text-[var(--muted)]">
              「確認」の欄は、<b>そのチェックを壊して落ちることを確かめたか</b>。
              確かめていないチェックは合格として記録できない（DB の制約が拒否する）。
              実行は <code className="font-[family-name:var(--font-geist-mono)]">make checker</code>。
            </p>
            <div className="card overflow-x-auto">
              <table className="w-full min-w-[860px] border-collapse text-[13px]">
                <thead>
                  <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-4 py-2 font-medium">チェック</th>
                    <th className="px-4 py-2 font-medium">深刻度</th>
                    <th className="px-4 py-2 font-medium">周期</th>
                    <th className="px-4 py-2 font-medium">結果</th>
                    <th className="px-4 py-2 font-medium">確認</th>
                    <th className="px-4 py-2 font-medium">実行</th>
                  </tr>
                </thead>
                <tbody>
                  {ops.data.runs.map((r) => (
                    <tr key={r.check_key} className="border-b border-[var(--border)] align-top">
                      <td className="px-4 py-2">
                        {r.title_ja}
                        <div className="font-[family-name:var(--font-geist-mono)] text-[11px] text-[var(--muted)]">
                          {r.check_key}
                        </div>
                      </td>
                      <td className="px-4 py-2">{r.severity}</td>
                      <td className="px-4 py-2">{r.cadence}</td>
                      <td className="px-4 py-2">
                        <ResultCell run={r} />
                      </td>
                      <td className="px-4 py-2">
                        {!r.negative_verified ? (
                          <span className="badge badge-on-hold">未確認</span>
                        ) : r.digest_current === true ? (
                          <span
                            className="badge badge-done"
                            title={`確認した中身の指紋: ${r.verified_digest?.slice(0, 12)}…`}
                          >
                            落ちることを確認済み
                          </span>
                        ) : r.digest_current === false ? (
                          <span
                            className="badge badge-danger"
                            title="確認したあとにチェックの中身が変わった。確認し直しが要る"
                          >
                            確認後に中身が変わった
                          </span>
                        ) : (
                          // It claims to be verified but has no fingerprint. Currently the 0022 trigger
                          // prevents this state, but we do not assert that "it changed".
                          // Report what cannot be determined as undeterminable.
                          <span
                            className="badge badge-on-hold"
                            title="確認済みとされているが指紋が無く、いまの定義と照らせない"
                          >
                            確認の記録が不完全
                          </span>
                        )}
                      </td>
                      <td className="px-4 py-2 whitespace-nowrap text-[12px] text-[var(--muted)]">
                        {r.started_at
                          ? new Date(r.started_at).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' })
                          : '未記録'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="mt-2 text-[12px] text-[var(--muted)]">
              カタログに入っているチェックは {counts.checks} 本。
              設計書が想定する 66 本のうち、外部連携を必要としないものだけを入れている。
            </p>
          </section>
        </>
      )}

      <section>
        <h2 className="mb-2 text-[15px] font-semibold">ここに載る予定のもの</h2>
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {PLANNED.map((p) => (
            <div key={p.title} className="card p-4 opacity-80">
              <div className="flex items-center gap-2">
                <span className="badge">未実装</span>
                <h3 className="text-[14px] font-semibold">{p.title}</h3>
              </div>
              <p className="mt-1.5 text-[12px] text-[var(--muted)]">{p.detail}</p>
            </div>
          ))}
        </div>
      </section>

      <section className="card p-4">
        <h2 className="mb-2 text-[13px] font-semibold">ルールの側</h2>
        <p className="text-[13px] text-[var(--fg-2)]">
          カタログは投入済みで、
          <Link className="underline" href={hrefForMode('/graph', mode)}>
            図
          </Link>
          からも一覧からも辿れる（統制 {counts.controls} / リスク雛形 {counts.risk_scenario_templates} / 規程{' '}
          {counts.policies}）。
        </p>
      </section>
    </div>
  );
}
