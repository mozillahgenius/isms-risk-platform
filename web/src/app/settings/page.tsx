import Link from 'next/link';
import {
  getConnectorManifests,
  getIntegrationSettings,
  type ConnectorManifestRow,
  type IntegrationResourceRunRow,
  type IntegrationRunRow,
} from '@/lib/integrations';
import { summarizeManifest, summarizeRunError } from '@/lib/integrationPresentation';
import { saveIntegration } from './actions';

export const dynamic = 'force-dynamic';

export const metadata = { title: '収集設定' };

// Connector settings screen of the external connector hub. Differs per deployment, so read from env (design doc 2026-09-11 §9.2).
// Writing a specific URL as the default would show links to that domain in other deployments. If unset, the button is not shown.
function connectorHubUrl(): string | null {
  const configured = process.env.ISMS_CONNECTOR_HUB_URL;
  return configured && /^https:\/\//.test(configured) ? configured : null;
}

const STATUS_LABEL: Record<string, string> = {
  active: '有効',
  paused: '一時停止',
  error: 'エラー',
  revoked: '失効',
};

const RUN_STATUS_LABEL: Record<string, string> = {
  success: '成功',
  partial: '一部取得',
  failed: '失敗',
};

const COLLECTION_STATE_LABEL: Record<string, string> = {
  collected: '取得済み',
  unreadable: '読めない',
  gone: '消失',
  not_collected: '未取得',
};

function dateLabel(value: string | null): string {
  return value
    ? new Date(value).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' })
    : '—';
}

function coverageLabel(value: string | null): string {
  if (value === null) return '未計測';
  const ratio = Number(value);
  return Number.isFinite(ratio) ? `${(ratio * 100).toFixed(1)}%` : '判定不能';
}

function statusClass(status: string): string {
  if (status === 'active' || status === 'success' || status === 'collected') return 'badge badge-done';
  if (status === 'error' || status === 'failed' || status === 'unreadable') return 'badge badge-danger';
  return 'badge badge-on-hold';
}

function manifestTitle(manifest: ConnectorManifestRow): string {
  return `${manifest.connector} v${manifest.version}`;
}

function latestRunsByResource(runs: IntegrationRunRow[]): IntegrationRunRow[] {
  const seen = new Set<string>();
  return runs.filter((run) => {
    const key = `${run.integration_id}:${run.resource_name}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function resourcesForRun(runId: string, resourceRuns: IntegrationResourceRunRow[]): IntegrationResourceRunRow[] {
  return resourceRuns.filter((run) => run.integration_run_id === runId);
}

export default async function SettingsPage({
  searchParams,
}: {
  searchParams: Promise<{ saved?: string; error?: string; mode?: string }>;
}) {
  const params = await searchParams;
  const mode = params.mode === 'isms' || params.mode === 'risk' ? params.mode : null;
  const hubUrl = connectorHubUrl();
  const [manifests, settings] = await Promise.all([getConnectorManifests(), getIntegrationSettings()]);
  const data = settings.ok
    ? { manifests, ...settings.data }
    : { manifests, integrations: [], runs: [], resourceRuns: [] };
  const writeEnabled = process.env.ISMS_SETTINGS_WRITE_ENABLED === '1' && Boolean(process.env.ISMS_WRITE_DATABASE_URL);

  return (
    <div className="flex flex-col gap-6">
      <header>
        <div className="flex flex-wrap items-center gap-2">
          <span className="badge badge-note">設定</span>
          <span className="text-xs text-[var(--muted)]">自動収集と証跡</span>
        </div>
        <h1 className="mt-2 text-[22px] font-semibold tracking-tight">収集設定</h1>
        <p className="mt-1 max-w-[900px] text-[13px] leading-6 text-[var(--muted)]">
          外部サービスの接続は外部のコネクタハブで行い、ここでは ISMS 側の収集定義と実行証跡を確認します。
          接続済み・設定済み・取得成功は別の状態として表示します。
        </p>
      </header>

      {params.saved === '1' && (
        <section className="card border-[var(--success)] bg-[var(--success-weak)] p-4" role="status">
          <p className="text-sm font-semibold text-[var(--badge-success-fg)]">収集設定を保存しました</p>
          <p className="mt-1 text-xs text-[var(--fg-2)]">
            実収集の橋渡しと接続テストが完了するまで、成功とは表示しません。
          </p>
        </section>
      )}

      {params.error && (
        <section className="card border-[var(--danger)] bg-[var(--danger-weak)] p-4" role="alert">
          <p className="text-sm font-semibold text-[var(--badge-danger-fg)]">収集設定を読み書きできませんでした</p>
          <p className="mt-1 text-xs text-[var(--fg-2)]">原因区分: {params.error}</p>
        </section>
      )}

      <section className="card border-[var(--accent-line)] bg-[var(--accent-weak)] p-5">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <span className="badge badge-note">コネクタハブ</span>
            <h2 className="mt-3 text-[16px] font-semibold">接続と自動取得はコネクタハブで管理</h2>
            <p className="mt-1 max-w-[760px] text-[13px] leading-6 text-[var(--fg-2)]">
              Google／Slack の認証情報、接続テスト、取得スケジュールはコネクタハブ側を正本にします。
              この画面にトークンや OAuth の値を入力しないでください。
            </p>
          </div>
          {hubUrl ? (
            <a
              href={hubUrl}
              target="_blank"
              rel="noreferrer"
              className="btn btn-primary shrink-0 px-3 py-2 text-sm"
            >
              コネクタハブの設定を開く ↗
            </a>
          ) : (
            <span className="shrink-0 text-[12px] text-[var(--muted)]">
              コネクタハブの URL が未設定です（ISMS_CONNECTOR_HUB_URL）
            </span>
          )}
        </div>
        <p className="mt-4 text-[12px] text-[var(--muted)]">
          コネクタハブの取得結果を ISMS ポスチャへ反映する橋渡しは、別の実行ワーカー/API連携として扱います。
          ここで設定を保存しただけでは、実データ取得済みとは判定しません。
        </p>
      </section>

      {!settings.ok && (
        <section className="card border-[var(--warning)] p-5">
          <h2 className="text-[15px] font-semibold text-[var(--badge-warning-fg)]">
            {settings.reason === 'no_token'
              ? 'この画面からはテナント設定を読めない（テナント文脈が無い）'
              : settings.reason === 'invalid_session'
                ? 'テナントセッションが無効（期限切れ・失効・停止のいずれか）'
                : 'テナント設定の読み取りに失敗した'}
          </h2>
          <p className="mt-2 text-[13px] text-[var(--fg-2)]">
            未設定 0 件ではありません。テナント文脈を確立できないため、設定と実行履歴が読める状態にありません。
          </p>
        </section>
      )}

      <section>
            <div className="flex flex-wrap items-end justify-between gap-3 border-b border-[var(--border)] pb-2">
              <div>
                <h2 className="text-[16px] font-semibold">ISMS側の収集定義</h2>
                <p className="mt-1 text-[12px] text-[var(--muted)]">
                  共有カタログのマニフェストと、このテナントの設定を分けて表示します。
                </p>
              </div>
              <Link className="text-[12px] text-[var(--accent)] underline" href={mode ? `/catalog?mode=${mode}` : '/catalog'}>
                カタログを見る
              </Link>
            </div>

            <div className="mt-3 grid gap-3 lg:grid-cols-2">
              {data.manifests.map((manifest) => {
                const summary = summarizeManifest(manifest.manifest);
                const integration = data.integrations.find(
                  (item) => item.connector === manifest.connector && item.manifest_version === manifest.version,
                );
                const runs = integration
                  ? latestRunsByResource(data.runs.filter((run) => run.integration_id === integration.id))
                  : [];
                return (
                  <article key={`${manifest.connector}:${manifest.version}`} className="card p-4">
                    <div className="flex flex-wrap items-start justify-between gap-2">
                      <div>
                        <h3 className="text-[14px] font-semibold">{manifestTitle(manifest)}</h3>
                        <p className="mt-1 text-[12px] text-[var(--muted)]">
                          {manifest.kind} · {summary.authType ?? '認証方式未定義'} · スコープ {summary.scopes} 件
                        </p>
                      </div>
                      <span className={integration ? statusClass(integration.status) : 'badge badge-on-hold'}>
                        {integration ? STATUS_LABEL[integration.status] ?? integration.status : '未設定'}
                      </span>
                    </div>
                    <div className="mt-3 flex flex-wrap gap-1.5">
                      {summary.resources.map((resource) => (
                        <span key={resource.name} className="badge">
                          {resource.name}{resource.mapTo ? ` → ${resource.mapTo}` : ''}
                        </span>
                      ))}
                    </div>
                    <div className="mt-3 grid gap-1 text-[12px] text-[var(--muted)] sm:grid-cols-2">
                      <div>全量: <span className="text-[var(--fg-2)]">{summary.fullSchedule ?? '未定義'}</span></div>
                      <div>差分: <span className="text-[var(--fg-2)]">{summary.incrementalSchedule ?? '未定義'}</span></div>
                    </div>
                    {integration && (
                      <div className="mt-3 border-t border-[var(--border)] pt-3 text-[12px] text-[var(--muted)]">
                        <div>資格情報: <span className="text-[var(--fg-2)]">参照名のみ保存（値は非表示）</span></div>
                        <div className="mt-1">最終設定更新: <span className="text-[var(--fg-2)]">{dateLabel(integration.updated_at)}</span></div>
                        <div className="mt-1">実行証跡: <span className="text-[var(--fg-2)]">{runs.length ? `${runs.length} 資源` : '未取得'}</span></div>
                      </div>
                    )}
                  </article>
                );
              })}
              {data.manifests.length === 0 && (
                <p className="card p-5 text-sm text-[var(--muted)]">カタログに収集定義が投入されていません。</p>
              )}
            </div>
      </section>

      {settings.ok && (
        <>
          <section className="card p-5">
            <h2 className="text-[15px] font-semibold">ISMS側の設定を登録</h2>
            <p className="mt-1 max-w-[820px] text-[12px] leading-5 text-[var(--muted)]">
              ここで入力するのは資格情報の値ではなく、コネクタハブの保管先を指す参照名だけです。
              状態を「有効」にしても、接続テストと橋渡しワーカーが実際に成功するまで自動取得済みとは扱いません。
            </p>
            {!writeEnabled ? (
              <p className="mt-4 rounded-[var(--radius)] bg-[var(--surface-2)] p-3 text-[12px] text-[var(--muted)]">
                保存操作は現在無効です。SSOで利用者を識別し、管理者権限を確認できる書き込み経路と、明示的な書込DB接続を設定してから有効化します。
              </p>
            ) : data.manifests.length > 0 ? (
              <form action={saveIntegration} className="mt-4 grid gap-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)_10rem_auto] md:items-end">
                {mode ? <input type="hidden" name="mode" value={mode} /> : null}
                <div>
                  <label className="mb-1.5 block text-[12px] font-medium text-[var(--fg-2)]" htmlFor="manifest-key">
                    コネクタ定義
                  </label>
                  <select id="manifest-key" name="manifest_key" required className="input w-full">
                    {data.manifests.map((manifest) => (
                      <option key={`${manifest.connector}:${manifest.version}`} value={`${manifest.connector}:${manifest.version}`}>
                        {manifestTitle(manifest)}
                      </option>
                    ))}
                  </select>
                </div>
                <div>
                  <label className="mb-1.5 block text-[12px] font-medium text-[var(--fg-2)]" htmlFor="secret-ref">
                    コネクタハブ参照URI
                  </label>
                  <input
                    id="secret-ref"
                    name="secret_ref"
                    required
                    maxLength={200}
                    autoComplete="off"
                    placeholder="connector-hub://connector/<UUID>"
                    className="input w-full font-mono"
                  />
                </div>
                <div>
                  <label className="mb-1.5 block text-[12px] font-medium text-[var(--fg-2)]" htmlFor="integration-status">
                    運用状態
                  </label>
                  <select id="integration-status" name="status" defaultValue="paused" className="input w-full">
                    <option value="paused">一時停止</option>
                    <option value="active">有効</option>
                  </select>
                </div>
                <button className="btn btn-primary justify-center px-4 py-2.5">設定を保存</button>
              </form>
            ) : (
              <p className="mt-4 text-[12px] text-[var(--muted)]">定義が無いため、設定フォームは表示しません。</p>
            )}
          </section>

          <section>
            <div className="border-b border-[var(--border)] pb-2">
              <h2 className="text-[16px] font-semibold">最新の収集証跡</h2>
              <p className="mt-1 text-[12px] text-[var(--muted)]">
                「設定済み」と「取得成功」を混同しないため、資源ごとの状態とカバレッジを表示します。
              </p>
            </div>
            {data.integrations.length === 0 ? (
              <p className="card mt-3 p-5 text-sm text-[var(--muted)]">このテナントの収集設定はまだありません。</p>
            ) : (
              <div className="mt-3 flex flex-col gap-3">
                {data.integrations.map((integration) => {
                  const runs = latestRunsByResource(data.runs.filter((run) => run.integration_id === integration.id));
                  return (
                    <article key={integration.id} className="card overflow-hidden">
                      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--border)] px-4 py-3">
                        <div>
                          <h3 className="text-[14px] font-semibold">{integration.connector}</h3>
                          <p className="mt-0.5 text-[11px] text-[var(--muted)]">マニフェスト v{integration.manifest_version}</p>
                        </div>
                        <span className={statusClass(integration.status)}>{STATUS_LABEL[integration.status] ?? integration.status}</span>
                      </div>
                      {runs.length === 0 ? (
                        <p className="px-4 py-4 text-[12px] text-[var(--muted)]">実行証跡なし（未取得）</p>
                      ) : (
                        <div className="overflow-x-auto">
                          <table className="w-full min-w-[760px] border-collapse text-[12px]">
                            <thead>
                              <tr className="border-b border-[var(--border)] text-left text-[11px] text-[var(--muted)]">
                                <th className="px-4 py-2 font-medium">資源</th>
                                <th className="px-4 py-2 font-medium">結果</th>
                                <th className="px-4 py-2 font-medium">カバレッジ</th>
                                <th className="px-4 py-2 font-medium">件数</th>
                                <th className="px-4 py-2 font-medium">実行</th>
                              </tr>
                            </thead>
                            <tbody>
                              {runs.map((run) => {
                                const details = resourcesForRun(run.id, data.resourceRuns);
                                const states = new Map<string, number>();
                                for (const detail of details) states.set(detail.collection_state, (states.get(detail.collection_state) ?? 0) + 1);
                                const errorLabel = summarizeRunError(run.error_detail);
                                return (
                                  <tr key={run.id} className="border-b border-[var(--border)] align-top last:border-0">
                                    <td className="px-4 py-2 font-medium">{run.resource_name}</td>
                                    <td className="px-4 py-2">
                                      <span className={statusClass(run.status)}>{RUN_STATUS_LABEL[run.status] ?? run.status}</span>
                                      {errorLabel && <div className="mt-1 text-[11px] text-[var(--danger)]">{errorLabel}</div>}
                                    </td>
                                    <td className="px-4 py-2">{coverageLabel(run.coverage_ratio)}</td>
                                    <td className="px-4 py-2 text-[var(--muted)]">
                                      取得 {run.collected ?? '—'} / 未読 {run.unreadable ?? '—'} / 消失 {run.gone ?? '—'} / 未取得 {run.not_collected ?? '—'}
                                      {states.size > 0 && (
                                        <div className="mt-1 flex flex-wrap gap-1">
                                          {[...states.entries()].map(([state, count]) => (
                                            <span key={state} className={statusClass(state)}>{COLLECTION_STATE_LABEL[state] ?? state} {count}</span>
                                          ))}
                                        </div>
                                      )}
                                    </td>
                                    <td className="whitespace-nowrap px-4 py-2 text-[var(--muted)]">{dateLabel(run.finished_at ?? run.started_at)}</td>
                                  </tr>
                                );
                              })}
                            </tbody>
                          </table>
                        </div>
                      )}
                    </article>
                  );
                })}
              </div>
            )}
          </section>
        </>
      )}
    </div>
  );
}
