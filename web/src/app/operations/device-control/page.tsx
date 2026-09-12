import Link from 'next/link';
import {
  authorizedActorEmail,
  deviceControlDevices,
  DISPATCH_TEMPLATES,
  getDeviceControlHistory,
  getDeviceInventory,
  isDeviceControlConfigured,
} from '@/lib/deviceControl';
import { dispatchDeviceControlAction, recoverDispatchAction } from './actions';

export const dynamic = 'force-dynamic';

export const metadata = { title: 'デバイス管理' };

// Screen that can run patch application and screen sharing ON/OFF only via fixed templates.
// Execution itself is delegated as-is to the existing policy evaluation and audit logging of the external device dispatcher (orchestrator).
// The fixed-template path proceeds to execution without waiting for additional approval.
// Here you can only choose "which template, on which device"
// (no free-form command field is provided).
//
// Own-organization boundary: anyone can open this screen, but only deployments where
// ISMS_DEVICE_DISPATCH_URL/ISMS_DEVICE_DISPATCH_TOKEN are set can actually dispatch or fetch history (since it is a server-to-server token
// for the organization's own execution platform, it is not distributed to deployments for other organizations' tenants).
//
// Both execute operations (buttons) and history viewing are authorized independently at the app layer,
// separately from the upstream SSO reverse proxy (shared-secret header + ISMS_DEVICE_CONTROL_ALLOWED_EMAILS;
// fail-closed because header forwarding is unverified in production. Unauthorized users see no history at all).

const INVENTORY_UNAVAILABLE_LABEL: Record<string, string> = {
  not_configured: 'この経路は設定されていません(ISMS_DEVICE_DISPATCH_URL/ISMS_DEVICE_DISPATCH_VIEW_TOKEN未設定)',
  unauthorized: 'この台帳を閲覧する権限がありません(ISMS_DEVICE_CONTROL_VIEW_ALLOWED_EMAILSに許可された利用者のみ)',
  http_error: '台帳の取得に失敗しました',
  network_error: '接続できませんでした',
  upstream_unavailable: 'ディスパッチャ側の端末台帳が未設定、または応答が得られませんでした',
};

const ERROR_LABEL: Record<string, string> = {
  bad_request: '不正な入力です',
  unauthorized: 'この操作を実行する権限がありません',
  not_configured: 'この経路は設定されていません(ISMS_DEVICE_DISPATCH_URL/ISMS_DEVICE_DISPATCH_TOKEN未設定)',
  timeout: '承認待ちが続いているか、応答がありません。実行自体は継続している可能性があります(下の履歴で確認してください)',
  http_error: 'ディスパッチに失敗しました',
  network_error: '接続できませんでした',
  recover_unauthorized: '未確定の要求を閉じる権限がありません',
  recover_not_configured: 'この経路は設定されていないため、未確定の要求を閉じられません',
  recover_too_early: '受付から間もないため閉じられません。承認待ちまたは実行中の可能性があります',
  recover_not_pending: 'この要求はすでに結果が出ているか、閉じられています',
  recover_still_running: 'この要求はまだ実行中です。閉じると次の操作と二重に実行され得るため閉じられません',
  recover_timeout: '応答が無く、閉じられたかどうか分かりません。もう一度操作する前に、下の履歴で状態を確かめてください',
  recover_http_error: '未確定の要求を閉じられませんでした',
  recover_network_error: '接続できなかったため、未確定の要求を閉じられませんでした',
};

// Four categories users cannot confuse (design doc 2026-09-11 §9.4): accepted / succeeded on device / failed / unconfirmed.
// Success only when an execution audit with exit code 0 is present. Items closed by a person (closed manually) are not counted as success.
// pending / unknown are values returned by older orchestrator versions (a fallback for when deployment order varies).
const EXECUTION_RESULT_LABEL: Record<string, string> = {
  accepted: '受付済み（端末の結果待ち）',
  success: '成功',
  failed: '失敗',
  not_executed: '未実行',
  unconfirmed: '未確定（要確認）',
  closed_manually: '手動で閉じた',
  pending: '処理中／未確定',
  unknown: '結果不明',
};

const EXECUTION_RESULT_CLASS: Record<string, string> = {
  accepted: 'bg-[var(--surface-2)] text-[var(--fg-2)]',
  success: 'bg-[var(--success-weak)] text-[var(--badge-success-fg)]',
  failed: 'bg-[var(--danger-weak)] text-[var(--badge-danger-fg)]',
  not_executed: 'bg-[var(--warning-weak)] text-[var(--badge-warning-fg)]',
  unconfirmed: 'bg-[var(--warning-weak)] text-[var(--badge-warning-fg)]',
  closed_manually: 'bg-[var(--surface-2)] text-[var(--muted)]',
  pending: 'bg-[var(--warning-weak)] text-[var(--badge-warning-fg)]',
  unknown: 'bg-[var(--surface-2)] text-[var(--muted)]',
};

// Make the wording show that it is a human declaration (since it is read alongside "success"/"failure", which are determined by exit code).
const RECOVERY_OUTCOME_LABEL: Record<string, string> = {
  executed_confirmed: '人の確認: 実行されていた',
  not_executed_confirmed: '人の確認: 実行されていなかった',
  undetermined: '人の確認: 分からないまま閉じた',
};

const INVENTORY_STATE_LABEL: Record<string, string> = {
  ok: '正常',
  stale: '応答遅延',
  baseline: '初期確認中',
  paused: '監視停止',
  failed: '要対応',
  unmonitored: '未監視',
  quiet: '長期未応答',
  never: '未接続',
};

const INVENTORY_STATE_CLASS: Record<string, string> = {
  ok: 'badge badge-done',
  stale: 'badge badge-on-hold',
  baseline: 'badge',
  paused: 'badge badge-danger',
  failed: 'badge badge-danger',
  unmonitored: 'badge badge-danger',
  quiet: 'badge badge-danger',
  never: 'badge badge-danger',
};

export default async function DeviceControlPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  // Target devices are read from configuration (ISMS_DEVICE_CONTROL_DEVICES). If unset, zero devices and no operations are shown.
  const devices = deviceControlDevices();
  const selectedDevice: string | null = typeof params.device === 'string' && devices.some((d) => d.key === params.device)
    ? params.device
    : devices[0]?.key ?? null;
  const dispatched = params.dispatched === '1';
  const recovered = params.recovered === '1';
  const error = typeof params.error === 'string' ? params.error : null;
  const mode = params.mode === 'isms' ? 'isms' : 'risk';
  const selectedDeviceLabel = selectedDevice
    ? devices.find((d) => d.key === selectedDevice)?.label ?? selectedDevice
    : '（未設定）';

  const configured = isDeviceControlConfigured();
  // Check authorization first; for unauthorized users, do not call the history fetch (getDeviceControlHistory)
  // at all. Fetching and then hiding the display is avoided because it leaves room for information to leak
  // through side effects or timing of the fetch itself.
  const actorEmail = configured ? await authorizedActorEmail() : null;
  const history = actorEmail && selectedDevice ? await getDeviceControlHistory(selectedDevice) : null;
  // Inventory viewing has authorization and configuration checks independent of the execution side (actorEmail/configured)
  // (getDeviceInventory itself checks authorizedViewerEmail; no guard is needed in the caller).
  const inventory = await getDeviceInventory();

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-[12px] font-medium text-[var(--accent)]">Agent管理（RMM）</p>
          <h1 className="mt-1 text-[22px] font-semibold tracking-tight">デバイス管理</h1>
          <p className="mt-1 max-w-[820px] text-[13px] text-[var(--muted)]">
            端末台帳を確認し、外部ディスパッチャ経由の固定操作を管理者として実行します。
            端末利用者の都度承認は不要ですが、管理者認可と監査は常に必要です。
          </p>
        </div>
        <Link className="btn px-3 py-1.5 text-[12px]" href={`/operations?mode=${mode}`}>運用に戻る</Link>
      </div>

      <section className="grid gap-3 sm:grid-cols-3" aria-label="管理状態">
        <div className="card p-4">
          <div className="text-[12px] text-[var(--muted)]">登録端末</div>
          <div className="mt-1 text-[24px] font-semibold tabular-nums">
            {inventory.state === 'ok' ? inventory.items.length : inventory.state === 'empty' ? 0 : '確認不可'}
          </div>
        </div>
        <div className="card p-4">
          <div className="text-[12px] text-[var(--muted)]">管理方式</div>
          <div className="mt-1 text-[16px] font-semibold">ローカル端末エージェント</div>
          <p className="mt-1 text-[11px] text-[var(--muted)]">Apple MDM登録は未実装</p>
        </div>
        <div className="card p-4">
          <div className="text-[12px] text-[var(--muted)]">実行ポリシー</div>
          <div className="mt-1 text-[16px] font-semibold">固定操作のみ</div>
          <p className="mt-1 text-[11px] text-[var(--muted)]">自由入力コマンドは拒否</p>
        </div>
      </section>

      <section>
        <h2 className="mb-1 text-[15px] font-semibold">管理対象</h2>
        <p className="mb-3 max-w-[900px] text-[12px] text-[var(--muted)]">
          正本はディスパッチャ側の端末台帳です。この画面は読み取り専用で、取得できない状態を0台とは表示しません。
        </p>
        {inventory.state === 'unavailable' ? (
          <div className="card p-4 text-[13px] text-[var(--muted)]">
            台帳を読み取れなかった({INVENTORY_UNAVAILABLE_LABEL[inventory.reason] ?? inventory.reason})
          </div>
        ) : inventory.state === 'empty' ? (
          <div className="card p-4 text-[13px] text-[var(--muted)]">登録されている端末がまだ無い</div>
        ) : (
          <div className="card overflow-x-auto">
            <table className="w-full min-w-[700px] border-collapse text-[13px]">
              <thead>
                <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                  <th className="px-4 py-2 font-medium">端末</th>
                  <th className="px-4 py-2 font-medium">OS</th>
                  <th className="px-4 py-2 font-medium">準拠状態</th>
                  <th className="px-4 py-2 font-medium">管理方式</th>
                  <th className="px-4 py-2 font-medium">最終応答</th>
                </tr>
              </thead>
              <tbody>
                {inventory.items.map((it) => (
                  <tr key={it.device_key} className="border-b border-[var(--border)]">
                    <td className="px-4 py-2">
                      {devices.find((d) => d.key === it.device_key)?.label ?? it.device_key}
                    </td>
                    <td className="px-4 py-2 text-[12px] text-[var(--muted)]">
                      {it.os_family}{it.os_version ? ` ${it.os_version}` : ''}
                    </td>
                    <td className="px-4 py-2">
                      <span className={INVENTORY_STATE_CLASS[it.state] ?? 'badge'}>
                        {INVENTORY_STATE_LABEL[it.state] ?? '判定不能'}
                      </span>
                    </td>
                    <td className="px-4 py-2 text-[12px]">Agent</td>
                    <td className="px-4 py-2 whitespace-nowrap text-[12px] text-[var(--muted)]">
                      {it.last_success_at ? new Date(it.last_success_at).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' }) : '未実測'}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {!configured ? (
        <section className="card border-[var(--warning)] p-5">
          <h2 className="text-[15px] font-semibold text-[var(--badge-warning-fg)]">この画面からは端末操作を実行できない</h2>
          <p className="mt-2 max-w-[820px] text-[13px] text-[var(--fg-2)]">
            ディスパッチャの実行経路が利用できません。端末台帳の閲覧には影響しませんが、操作は管理者が接続設定を確認するまで停止します。
          </p>
          <details className="mt-3 text-[11px] text-[var(--muted)]">
            <summary className="cursor-pointer">管理者向け詳細</summary>
            <p className="mt-2">サーバ側の実行URL、実行用S2S資格情報、テナント文脈、操作対象端末(ISMS_DEVICE_CONTROL_DEVICES)のいずれかが未設定です。</p>
          </details>
        </section>
      ) : (
        <>
          {dispatched && (
            <section className="card border-[var(--success)] bg-[var(--success-weak)] p-4" role="status">
              <p className="text-sm font-semibold text-[var(--badge-success-fg)]">実行を要求した</p>
              <p className="mt-1 text-xs text-[var(--fg-2)]">固定テンプレートは追加の承認なしで実行へ進む。下の履歴で状態を確認できる。</p>
            </section>
          )}
          {recovered && (
            <section className="card border-[var(--border)] bg-[var(--surface-2)] p-4" role="status">
              {/* Not the success color. Being closed does not mean success on the device (success is only stated via exit code). */}
              <p className="text-sm font-semibold text-[var(--fg)]">未確定の要求を閉じた（成功とは扱わない）</p>
              <p className="mt-1 text-xs text-[var(--fg-2)]">再実行はしていない。確認内容は監査に残り、この端末へ次の操作を出せるようになった。</p>
            </section>
          )}
          {error && (
            <section className="card border-[var(--danger)] bg-[var(--danger-weak)] p-4" role="alert">
              <p className="text-sm font-semibold text-[var(--badge-danger-fg)]">{ERROR_LABEL[error] ?? `エラー: ${error}`}</p>
            </section>
          )}

          <section className="card p-5">
            <div>
              <h2 className="text-[15px] font-semibold">管理操作</h2>
              <p className="mt-1 max-w-[760px] text-[12px] text-[var(--muted)]">
                対象端末を選び、配備済みの固定操作だけを実行します。要求受付と端末上の成功は別に判定されます。
              </p>
            </div>
            <nav aria-label="操作対象端末" className="mt-4 flex flex-wrap gap-2">
              {devices.map((d) => (
                <Link
                  key={d.key}
                  href={`/operations/device-control?device=${encodeURIComponent(d.key)}&mode=${mode}`}
                  className={`btn px-3 py-1.5 text-[12px] ${d.key === selectedDevice ? 'btn-primary' : ''}`}
                >
                  {d.label}
                </Link>
              ))}
            </nav>

            {!actorEmail ? (
              <p className="mt-4 text-[12px] text-[var(--muted)]">
                この操作を実行する権限がありません(
                <code className="font-[family-name:var(--font-geist-mono)]">ISMS_DEVICE_CONTROL_ALLOWED_EMAILS</code>
                に許可された利用者のみ)。
              </p>
            ) : (
              <div className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-3">
                {DISPATCH_TEMPLATES.map((t) => (
                  <form key={t.id} action={dispatchDeviceControlAction} className="rounded-[var(--radius)] border border-[var(--border)] p-4">
                    <input type="hidden" name="device_key" value={selectedDevice ?? ''} />
                    <input type="hidden" name="template_id" value={t.id} />
                    <input type="hidden" name="mode" value={mode} />
                    <div className="flex items-center justify-between gap-2">
                      <h3 className="text-[13px] font-semibold">{t.label}</h3>
                      <span className="badge">低リスク</span>
                    </div>
                    <p className="mt-2 min-h-9 text-[12px] leading-relaxed text-[var(--muted)]">{t.description}</p>
                    <p className="mt-2 text-[11px] text-[var(--muted)]">証跡: {t.evidence} / テンプレート版 {t.version}</p>
                    <label className="mt-3 flex flex-col gap-1 text-[11px] text-[var(--muted)]">
                      実行理由（監査記録）
                      <input
                        className="input"
                        name="reason"
                        required
                        maxLength={200}
                        placeholder="例: 月次のセキュリティ更新"
                      />
                    </label>
                    <button type="submit" className="btn btn-primary mt-4 whitespace-nowrap px-3 py-2 text-sm">
                      {t.label}
                    </button>
                  </form>
                ))}
              </div>
            )}
          </section>

          <section>
            <h2 className="mb-1 text-[15px] font-semibold">実行履歴: {selectedDeviceLabel}</h2>
            <p className="mb-3 max-w-[900px] text-[12px] text-[var(--muted)]">
              直近{' '}20{' '}件。ディスパッチャ側の実行監査に加え、実行監査の終了コードから結果を表示する。
              <span className="ms-1">終了コード0だけを「成功」とし、「executed」だけでは成功扱いにしない。</span>
            </p>
            {!actorEmail ? (
              <div className="card p-4 text-[13px] text-[var(--muted)]">
                この操作を実行する権限がありません(
                <code className="font-[family-name:var(--font-geist-mono)]">ISMS_DEVICE_CONTROL_ALLOWED_EMAILS</code>
                に許可された利用者のみ履歴を閲覧できる)。
              </div>
            ) : history?.ok !== true ? (
              <div className="card p-4 text-[13px] text-[var(--muted)]">
                履歴を読み取れなかった({history?.reason ?? 'unknown'})
              </div>
            ) : history.items.length === 0 ? (
              <div className="card p-4 text-[13px] text-[var(--muted)]">この端末の実行履歴はまだ無い</div>
            ) : (
              <div className="card overflow-x-auto">
                <table className="w-full min-w-[700px] border-collapse text-[13px]">
                  <thead>
                    <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                      <th className="px-4 py-2 font-medium">日時</th>
                      <th className="px-4 py-2 font-medium">判定</th>
                      <th className="px-4 py-2 font-medium">状態</th>
                      <th className="px-4 py-2 font-medium">結果</th>
                      <th className="px-4 py-2 font-medium">終了コード</th>
                      <th className="px-4 py-2 font-medium">根拠</th>
                    </tr>
                  </thead>
                  <tbody>
                    {history.items.map((it) => (
                      <tr key={it.id} className="border-b border-[var(--border)]">
                        <td className="px-4 py-2 whitespace-nowrap text-[12px] text-[var(--muted)]">
                          {new Date(it.created_at).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' })}
                        </td>
                        <td className="px-4 py-2">{it.policy_decision}</td>
                        <td className="px-4 py-2">{it.status}</td>
                        <td className="px-4 py-2">
                          <span className={`inline-flex rounded-full px-2 py-0.5 text-[11px] font-semibold ${EXECUTION_RESULT_CLASS[it.execution_result] ?? EXECUTION_RESULT_CLASS.unknown}`}>
                            {EXECUTION_RESULT_LABEL[it.execution_result] ?? EXECUTION_RESULT_LABEL.unknown}
                          </span>
                          {it.recovery && (
                            <p className="mt-1 max-w-[280px] text-[11px] text-[var(--muted)]">
                              {RECOVERY_OUTCOME_LABEL[it.recovery.outcome] ?? it.recovery.outcome}（{it.recovery.resolved_actor_email}）: {it.recovery.note}
                            </p>
                          )}
                          {it.execution_result === 'unconfirmed' && it.request_id && (
                            <details className="mt-2 text-[12px]">
                              <summary className="cursor-pointer text-[var(--fg-2)]">端末を確かめて閉じる</summary>
                              <form action={recoverDispatchAction} className="mt-2 flex max-w-[320px] flex-col gap-2">
                                <input type="hidden" name="mode" value={mode} />
                                <input type="hidden" name="device_key" value={selectedDevice ?? ''} />
                                <input type="hidden" name="request_id" value={it.request_id} />
                                <select className="input" name="outcome" required defaultValue="">
                                  <option value="" disabled>確認した結果</option>
                                  {Object.entries(RECOVERY_OUTCOME_LABEL).map(([value, label]) => (
                                    <option key={value} value={value}>{label}</option>
                                  ))}
                                </select>
                                <input
                                  className="input"
                                  name="note"
                                  required
                                  maxLength={1000}
                                  placeholder="何を確かめたか（例: 端末の更新履歴に記録なし）"
                                />
                                <p className="text-[11px] text-[var(--muted)]">閉じても再実行はしない。「成功」とは表示されない。</p>
                                <button type="submit" className="btn px-3 py-1.5 text-[12px]">閉じる</button>
                              </form>
                            </details>
                          )}
                        </td>
                        <td className="px-4 py-2 font-[family-name:var(--font-geist-mono)] text-[12px]">
                          {typeof it.exit_code === 'number' ? it.exit_code : '未記録'}
                        </td>
                        <td className="px-4 py-2 font-[family-name:var(--font-geist-mono)] text-[11px] text-[var(--muted)]">
                          {it.matched_rule}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
        </>
      )}
    </div>
  );
}
