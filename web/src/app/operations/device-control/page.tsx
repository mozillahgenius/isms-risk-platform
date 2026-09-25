import Link from 'next/link';
import {
  authorizedActorEmail,
  DEVICE_CONTROL_DEVICES,
  DISPATCH_TEMPLATES,
  getDeviceControlHistory,
  getDeviceBasics,
  getManagementDeviceInventory,
  isDeviceControlConfigured,
} from '@/lib/deviceControl';
import { dispatchDeviceControlAction, recoverDispatchAction } from './actions';
import EnrollmentPanel from './EnrollmentPanel';
import { revokeAgentInstallation } from './distribution-actions';

export const dynamic = 'force-dynamic';

export const metadata = { title: 'デバイス管理' };

// パッチ適用・画面共有ON/OFFを固定テンプレートでのみ実行できる画面。
// 実行そのものはCodzilla(自社の内製自動化基盤)の既存ポリシー評価・監査記録に
// そのまま委ねる。固定テンプレート経路はSlack承認を待たずに実行へ進む。
// ここでは「どのテンプレートを、どの端末に」しか選べない
// (自由入力のコマンド欄は置かない)。
//
// 自社限定の境界: この画面自体は誰でも開けるが、実際にディスパッチ・履歴取得ができるのは
// CODZILLA_ISMS_DISPATCH_URL/TOKEN が設定されたデプロイだけ(自社の内製実行基盤への
// サーバ間トークンのため、他社テナント向けデプロイには配布しない)。
//
// 実行操作(ボタン)・履歴閲覧のどちらも、前段のSSOリバースプロキシとは別にアプリ層で
// 独立して認可する(共有シークレットヘッダ＋ISMS_DEVICE_CONTROL_ALLOWED_EMAILS。
// ヘッダ転送が本番で未確認のためfail-closed。許可されない利用者には履歴も一切見せない)。

const MANAGEMENT_INVENTORY_UNAVAILABLE_LABEL: Record<string, string> = {
  not_configured: 'Managementのテナント接続が設定されていません',
  unauthorized: 'この台帳を閲覧する権限がありません',
  invalid_session: 'Managementのログイン状態を確認できません',
  database_error: 'Managementの端末台帳を読み取れませんでした',
};

const MANAGEMENT_STATUS_LABEL: Record<string, string> = {
  issued: '発行済み',
  sent: '送付済み',
  downloaded: 'ダウンロード済み',
  installed: '導入済み',
  activation_pending: '認証待ち',
  active: '登録済み',
  failed: '失敗',
  expired: '期限切れ',
};

const MANAGEMENT_STATUS_CLASS: Record<string, string> = {
  issued: 'badge',
  sent: 'badge',
  downloaded: 'badge',
  installed: 'badge badge-on-hold',
  activation_pending: 'badge badge-on-hold',
  active: 'badge badge-done',
  failed: 'badge badge-danger',
  expired: 'badge badge-danger',
};

const ERROR_LABEL: Record<string, string> = {
  bad_request: '不正な入力です',
  revoke_already_active: '登録済みの端末の招待は取り消せません',
  revoke_not_found: '取り消す招待が見つかりません',
  revoke_invalid_session: 'セッションが無効です。ページを再読み込みしてください。',
  unauthorized: 'この操作を実行する権限がありません',
  not_configured: 'この経路は設定されていません(CODZILLA_ISMS_DISPATCH_URL/TOKEN未設定)',
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

// 利用者が取り違えない4つの区分（設計書 2026-09-11 §9.4）: 受け付けた／端末で成功した／失敗した／未確定。
// 成功は終了コード0の実行監査がそろったときだけ。人が閉じたもの（手動で閉じた）は成功に数えない。
// pending / unknown は旧版の orchestrator が返す値（配備順が前後したときの受け皿）。
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

// 人の申告であることが文言で分かるようにする（終了コードで決まる「成功」「失敗」と並べて読まれるため）。
const RECOVERY_OUTCOME_LABEL: Record<string, string> = {
  executed_confirmed: '人の確認: 実行されていた',
  not_executed_confirmed: '人の確認: 実行されていなかった',
  undetermined: '人の確認: 分からないまま閉じた',
};

const OS_FAMILY_LABEL: Record<string, string> = { macos: 'macOS', windows: 'Windows', linux: 'Linux' };

function yesNo(value: boolean | null): string {
  return value === null ? '—' : value ? '有効' : '無効';
}

export default async function DeviceControlPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  const selectedDevice = typeof params.device === 'string' && DEVICE_CONTROL_DEVICES.some((d) => d.key === params.device)
    ? params.device
    : DEVICE_CONTROL_DEVICES[0]!.key;
  const dispatched = params.dispatched === '1';
  const recovered = params.recovered === '1';
  const revoked = params.revoked === '1';
  const error = typeof params.error === 'string' ? params.error : null;
  const mode = params.mode === 'isms' ? 'isms' : 'risk';
  const selectedDeviceLabel = DEVICE_CONTROL_DEVICES.find((d) => d.key === selectedDevice)?.label ?? selectedDevice;

  const configured = isDeviceControlConfigured();
  // 認可確認を先に行い、許可されていない利用者へは履歴取得(getDeviceControlHistory)
  // 自体を呼ばない。取得してから表示を隠す実装は、取得処理自体の副作用や
  // タイミングで情報が漏れる余地を残すため避ける。
  const actorEmail = configured ? await authorizedActorEmail() : null;
  const history = actorEmail ? await getDeviceControlHistory(selectedDevice) : null;
  // 登録状態はManagement自身の台帳を読む。Codzilla/Kanameの操作対象一覧とは別物。
  const managementInventory = await getManagementDeviceInventory();
  const deviceBasics = await getDeviceBasics();
  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-[12px] font-medium text-[var(--accent)]">Agent管理（RMM）</p>
          <h1 className="mt-1 text-[22px] font-semibold tracking-tight">デバイス管理</h1>
          <p className="mt-1 max-w-[820px] text-[13px] text-[var(--muted)]">
            Management自身の端末台帳へagentを登録し、Codzillaの固定操作を管理者として実行します。
            Kaname・Codzilla・Managementは独立して登録状態を持ち、不一致は登録完了にせずエラーとして扱います。
          </p>
        </div>
        <Link className="btn px-3 py-1.5 text-[12px]" href={`/operations?mode=${mode}`}>運用に戻る</Link>
      </div>

      <section className="grid gap-3 sm:grid-cols-3" aria-label="管理状態">
        <div className="card p-4">
          <div className="text-[12px] text-[var(--muted)]">登録端末</div>
          <div className="mt-1 text-[24px] font-semibold tabular-nums">
            {managementInventory.state === 'ok' ? managementInventory.items.length : managementInventory.state === 'empty' ? 0 : '確認不可'}
          </div>
        </div>
        <div className="card p-4">
          <div className="text-[12px] text-[var(--muted)]">管理方式</div>
          <div className="mt-1 text-[16px] font-semibold">Codzilla Agent</div>
          <p className="mt-1 text-[11px] text-[var(--muted)]">Apple MDM登録は未実装</p>
        </div>
        <div className="card p-4">
          <div className="text-[12px] text-[var(--muted)]">実行ポリシー</div>
          <div className="mt-1 text-[16px] font-semibold">固定操作のみ</div>
          <p className="mt-1 text-[11px] text-[var(--muted)]">自由入力コマンドは拒否</p>
        </div>
      </section>

      <EnrollmentPanel />

      <section>
        <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 className="mb-1 text-[15px] font-semibold">管理対象</h2>
            <p className="max-w-[900px] text-[12px] text-[var(--muted)]">
              ここはManagement自身の登録台帳です。認証前の送付・導入状態も含め、登録経路の現在状態を表示します。
            </p>
            {revoked && <p className="mt-2 text-[12px] text-[var(--success)]" role="status">招待を取り消しました。</p>}
            {error?.startsWith('revoke_') && (
              <p className="mt-2 text-[12px] text-[var(--danger)]" role="alert">取り消せませんでした: {ERROR_LABEL[error] ?? error}</p>
            )}
          </div>
        </div>
        {managementInventory.state === 'unavailable' ? (
          <div className="card p-4 text-[13px] text-[var(--muted)]">
            台帳を読み取れなかった({MANAGEMENT_INVENTORY_UNAVAILABLE_LABEL[managementInventory.reason] ?? managementInventory.reason})
          </div>
        ) : managementInventory.state === 'empty' ? (
          <div className="card p-4 text-[13px] text-[var(--muted)]">登録されている端末がまだ無い</div>
        ) : (
          <div className="card overflow-x-auto">
            <table className="w-full min-w-[820px] border-collapse text-[13px]">
              <thead>
                <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                  <th className="px-4 py-2 font-medium">端末</th>
                  <th className="px-4 py-2 font-medium">OS</th>
                  <th className="px-4 py-2 font-medium">登録状態</th>
                  <th className="px-4 py-2 font-medium">送付先</th>
                  <th className="px-4 py-2 font-medium">最終更新</th>
                  <th className="px-4 py-2 font-medium">取り消し</th>
                </tr>
              </thead>
              <tbody>
                {managementInventory.items.map((it) => {
                  const deviceLabel = it.target_name || it.hardware_id || it.target_email;
                  const lastUpdated = it.activated_at ?? it.installed_at ?? it.created_at;
                  return (
                    <tr key={it.id} className="border-b border-[var(--border)]">
                      <td className="px-4 py-2">
                        <div>{deviceLabel}</div>
                        {it.hardware_id && <div className="text-[11px] text-[var(--muted)]">機体ID: {it.hardware_id}</div>}
                      </td>
                      <td className="px-4 py-2 text-[12px] text-[var(--muted)]">{it.os_family}</td>
                      <td className="px-4 py-2">
                        {/* 0084: 管理者が取り消した招待は「取り消し済み」と出す（状態は expired、理由 revoked_by_admin）。 */}
                        <span className={MANAGEMENT_STATUS_CLASS[it.status] ?? 'badge'}>
                          {it.failure_code === 'revoked_by_admin' ? '取り消し済み' : MANAGEMENT_STATUS_LABEL[it.status] ?? it.status}
                        </span>
                      </td>
                      <td className="px-4 py-2 text-[12px]">{it.target_email}</td>
                      <td className="px-4 py-2 whitespace-nowrap text-[12px] text-[var(--muted)]">
                        {new Date(lastUpdated).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' })}
                      </td>
                      <td className="px-4 py-2">
                        {it.status !== 'active' && it.failure_code !== 'revoked_by_admin' ? (
                          <form action={revokeAgentInstallation}>
                            <input type="hidden" name="installation_id" value={it.id} />
                            <input type="hidden" name="mode" value={mode} />
                            <button type="submit" className="btn px-2 py-1 text-[11px]">招待を取り消す</button>
                          </form>
                        ) : (
                          <span className="text-[11px] text-[var(--muted)]">—</span>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* PC の基礎情報（2026-09-25）。登録済みの端末ごとに、最新の状態の報告から OS・スペック・保護の状態を出す。 */}
      <section>
        <div className="mb-3">
          <h2 className="mb-1 text-[15px] font-semibold">端末の基礎情報</h2>
          <p className="max-w-[900px] text-[12px] text-[var(--muted)]">
            エージェントの最新の報告から表示します。CPU・コア数・メモリは macOS のエージェント（2026-09-25 版以降）が報告します。
          </p>
        </div>
        {deviceBasics.state === 'unavailable' ? (
          <div className="card p-4 text-[13px] text-[var(--muted)]">
            基礎情報を読み取れなかった({MANAGEMENT_INVENTORY_UNAVAILABLE_LABEL[deviceBasics.reason] ?? deviceBasics.reason})
          </div>
        ) : deviceBasics.state === 'empty' ? (
          <div className="card p-4 text-[13px] text-[var(--muted)]">登録済みの端末がまだ無い</div>
        ) : (
          <div className="card overflow-x-auto">
            <table className="w-full min-w-[980px] border-collapse text-[13px]">
              <thead>
                <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                  <th className="px-4 py-2 font-medium">端末</th>
                  <th className="px-4 py-2 font-medium">OS</th>
                  <th className="px-4 py-2 font-medium">CPU</th>
                  <th className="px-4 py-2 font-medium">コア</th>
                  <th className="px-4 py-2 font-medium">メモリ</th>
                  <th className="px-4 py-2 font-medium">保護の状態</th>
                  <th className="px-4 py-2 font-medium">最終報告</th>
                </tr>
              </thead>
              <tbody>
                {deviceBasics.items.map((d) => (
                  <tr key={d.id} className="border-b border-[var(--border)] align-top">
                    <td className="px-4 py-2">
                      <div>{d.hostname}</div>
                      {d.model && <div className="text-[11px] text-[var(--muted)]">{d.model}</div>}
                    </td>
                    <td className="px-4 py-2 text-[12px]">{OS_FAMILY_LABEL[d.os_family] ?? d.os_family}{d.os_version ? ` ${d.os_version}` : ''}</td>
                    <td className="px-4 py-2 text-[12px]">{d.cpu ?? '—'}</td>
                    <td className="px-4 py-2 text-[12px]">{d.cores ?? '—'}</td>
                    <td className="px-4 py-2 text-[12px]">{d.memory ?? '—'}</td>
                    <td className="px-4 py-2 text-[11px] leading-5">
                      <div>ディスク暗号化: {yesNo(d.disk_encrypted)}</div>
                      <div>画面ロック: {yesNo(d.screen_lock_enabled)}</div>
                      <div>ファイアウォール: {yesNo(d.firewall_enabled)}</div>
                      <div>OS の更新: {d.patch_current === null ? '—' : d.patch_current ? '最新' : '未適用あり'}</div>
                    </td>
                    <td className="px-4 py-2 whitespace-nowrap text-[12px] text-[var(--muted)]">
                      {d.last_seen_at ? new Date(d.last_seen_at).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' }) : 'まだ無い'}
                      {d.agent_version && <div className="text-[11px]">agent {d.agent_version}</div>}
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
            Codzillaの実行経路が利用できません。端末台帳の閲覧には影響しませんが、操作は管理者が接続設定を確認するまで停止します。
          </p>
          <details className="mt-3 text-[11px] text-[var(--muted)]">
            <summary className="cursor-pointer">管理者向け詳細</summary>
            <p className="mt-2">サーバ側の実行URL、実行用S2S資格情報、テナント文脈のいずれかが未設定です。</p>
          </details>
        </section>
      ) : (
        <>
          {dispatched && (
            <section className="card border-[var(--success)] bg-[var(--success-weak)] p-4" role="status">
              <p className="text-sm font-semibold text-[var(--badge-success-fg)]">実行を要求した</p>
              <p className="mt-1 text-xs text-[var(--fg-2)]">固定テンプレートはSlack承認なしで実行へ進む。下の履歴で状態を確認できる。</p>
            </section>
          )}
          {recovered && (
            <section className="card border-[var(--border)] bg-[var(--surface-2)] p-4" role="status">
              {/* 成功色にしない。閉じたことは端末での成功を意味しない（成功は終了コードでしか言わない）。 */}
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
              {DEVICE_CONTROL_DEVICES.map((d) => (
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
                    <input type="hidden" name="device_key" value={selectedDevice} />
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
              直近{' '}20{' '}件。Codzilla側の実行監査(tool_calls)に加え、実行監査の終了コードから結果を表示する。
              <span className="ml-1">終了コード0だけを「成功」とし、「executed」だけでは成功扱いにしない。</span>
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
