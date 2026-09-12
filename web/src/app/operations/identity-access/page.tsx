import Link from 'next/link';
import { getIdentityAccessOverview, isIdentityProvisioningConfigured } from '@/lib/identityAccess';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'ID・ライセンス管理' };

const REQUEST_LABEL: Record<string, string> = {
  'identity.create': 'アカウント発行',
  'identity.suspend': 'アカウント停止',
  'identity.restore': 'アカウント再開',
  'license.assign': 'ライセンス付与',
  'license.revoke': 'ライセンス解除',
  'group.add': 'グループ追加',
  'group.remove': 'グループ解除',
  'session.revoke': 'セッション失効',
};

const STATUS_LABEL: Record<string, string> = {
  draft: '下書き',
  approved: '承認済み',
  dispatched: '実行中',
  succeeded: '成功',
  failed: '失敗',
  cancelled: '取消',
};

function dateLabel(value: string | null): string {
  return value ? new Date(value).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' }) : '未記録';
}

export default async function IdentityAccessPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const [params, overview] = await Promise.all([searchParams, getIdentityAccessOverview()]);
  const mode = params.mode === 'isms' ? 'isms' : 'risk';
  const dispatchConfigured = isIdentityProvisioningConfigured();

  return (
    <div className="flex flex-col gap-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <span className="badge badge-note">Google Workspace IdP</span>
            <span className={dispatchConfigured ? 'badge badge-note' : 'badge badge-on-hold'}>
              {dispatchConfigured ? 'API実行面 設定値あり・疎通未検証' : 'API実行面 未接続'}
            </span>
          </div>
          <h1 className="mt-2 text-[22px] font-semibold tracking-tight">ID・ライセンス管理</h1>
          <p className="mt-1 max-w-[820px] text-[13px] leading-6 text-[var(--muted)]">
            Google Workspaceを本人・所属の基準にし、各システムのアカウント発行、停止、ライセンス付与と解除を同じrequest IDで追跡します。
          </p>
        </div>
        <Link className="btn px-3 py-1.5 text-[12px]" href={`/operations?mode=${mode}`}>運用に戻る</Link>
      </header>

      {!overview.ok ? (
        <section className="card border-[var(--warning)] p-5">
          <h2 className="text-[15px] font-semibold text-[var(--badge-warning-fg)]">ID・ライセンス台帳を読み取れません</h2>
          <p className="mt-2 text-[13px] leading-6 text-[var(--fg-2)]">
            {overview.reason === 'no_token'
              ? 'テナント文脈がありません。0件ではなく、読める状態にありません。'
              : overview.reason === 'invalid_session'
                ? 'テナントセッションが期限切れ、失効、または停止状態です。'
                : '台帳の準備またはデータベース接続を確認してください。'}
          </p>
        </section>
      ) : (
        <>
          <section className="grid gap-3 sm:grid-cols-3" aria-label="ID・ライセンスの概要">
            <article className="card p-4">
              <div className="text-[12px] text-[var(--muted)]">利用者</div>
              <div className="mt-1 text-[24px] font-semibold tabular-nums">{overview.data.summary.activePrincipals}</div>
              <div className="text-[11px] text-[var(--muted)]">登録 {overview.data.summary.principals} 件</div>
            </article>
            <article className="card p-4">
              <div className="text-[12px] text-[var(--muted)]">割当済みライセンス</div>
              <div className="mt-1 text-[24px] font-semibold tabular-nums">{overview.data.summary.assignedEntitlements}</div>
              <div className="text-[11px] text-[var(--muted)]">対象システム {overview.data.summary.applications} 件</div>
            </article>
            <article className="card p-4">
              <div className="text-[12px] text-[var(--muted)]">処理待ち</div>
              <div className="mt-1 text-[24px] font-semibold tabular-nums">{overview.data.summary.openRequests}</div>
              <div className="text-[11px] text-[var(--muted)]">失敗 {overview.data.summary.failedRequests} 件</div>
            </article>
          </section>

          <section>
            <h2 className="mb-1 text-[16px] font-semibold">システムとライセンス</h2>
            <p className="mb-3 text-[12px] text-[var(--muted)]">任意URLや任意コマンドではなく、登録済みproviderとSKUだけを実行対象にします。</p>
            {overview.data.applications.length === 0 ? (
              <div className="card p-5 text-[13px] text-[var(--muted)]">対象システムは未登録です。Google Workspaceの読み取り同期結果を確認してから登録します。</div>
            ) : (
              <div className="card overflow-x-auto">
                <table className="w-full min-w-[680px] border-collapse text-[13px]">
                  <thead>
                    <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                      <th className="px-4 py-2 font-medium">システム</th>
                      <th className="px-4 py-2 font-medium">Provider</th>
                      <th className="px-4 py-2 font-medium">発行方式</th>
                      <th className="px-4 py-2 font-medium">SKU</th>
                      <th className="px-4 py-2 font-medium">割当済み</th>
                      <th className="px-4 py-2 font-medium">状態</th>
                    </tr>
                  </thead>
                  <tbody>
                    {overview.data.applications.map((app) => (
                      <tr key={app.id} className="border-b border-[var(--border)]">
                        <td className="px-4 py-2 font-medium">{app.name}</td>
                        <td className="px-4 py-2">{app.provider}</td>
                        <td className="px-4 py-2">{app.provisioning_mode}</td>
                        <td className="px-4 py-2 tabular-nums">{app.licenses}</td>
                        <td className="px-4 py-2 tabular-nums">{app.assigned}</td>
                        <td className="px-4 py-2"><span className="badge">{app.status}</span></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>

          <section>
            <h2 className="mb-1 text-[16px] font-semibold">発行・変更履歴</h2>
            <p className="mb-3 text-[12px] text-[var(--muted)]">要求受付と外部API上の成功を分け、秘密値を台帳や画面へ保存しません。</p>
            {overview.data.requests.length === 0 ? (
              <div className="card p-5 text-[13px] text-[var(--muted)]">発行・変更要求はまだありません。</div>
            ) : (
              <div className="card overflow-x-auto">
                <table className="w-full min-w-[920px] border-collapse text-[13px]">
                  <thead>
                    <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                      <th className="px-4 py-2 font-medium">操作</th>
                      <th className="px-4 py-2 font-medium">対象</th>
                      <th className="px-4 py-2 font-medium">システム・SKU</th>
                      <th className="px-4 py-2 font-medium">状態</th>
                      <th className="px-4 py-2 font-medium">要求者・理由</th>
                      <th className="px-4 py-2 font-medium">要求日時</th>
                    </tr>
                  </thead>
                  <tbody>
                    {overview.data.requests.map((request) => (
                      <tr key={request.request_id} className="border-b border-[var(--border)] align-top">
                        <td className="px-4 py-2">{REQUEST_LABEL[request.action] ?? request.action}</td>
                        <td className="px-4 py-2">{request.primary_email}</td>
                        <td className="px-4 py-2">{[request.application_name, request.license_name].filter(Boolean).join(' / ') || 'Google Workspace'}</td>
                        <td className="px-4 py-2">
                          <span className={request.status === 'failed' ? 'badge badge-danger' : request.status === 'succeeded' ? 'badge badge-done' : 'badge badge-on-hold'}>
                            {STATUS_LABEL[request.status] ?? request.status}
                          </span>
                          {request.error_code ? <div className="mt-1 text-[11px] text-[var(--danger)]">{request.error_code}</div> : null}
                        </td>
                        <td className="max-w-[300px] px-4 py-2">
                          <div>{request.requested_by_email}</div>
                          <div className="mt-1 text-[11px] text-[var(--muted)]">{request.reason}</div>
                        </td>
                        <td className="whitespace-nowrap px-4 py-2 text-[12px] text-[var(--muted)]">
                          {dateLabel(request.requested_at)}
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

      <section className="card p-5">
        <h2 className="text-[16px] font-semibold">実行境界</h2>
        <div className="mt-3 grid gap-4 text-[13px] leading-6 text-[var(--fg-2)] md:grid-cols-3">
          <div><b className="text-[var(--fg)]">リソースマネジメント</b><br />対象、操作、理由、状態と監査参照を管理します。</div>
          <div><b className="text-[var(--fg)]">Google Workspace</b><br />本人、所属、停止状態をIdPの基準にします。</div>
          <div><b className="text-[var(--fg)]">型付き実行面</b><br />外部API資格情報を短時間だけ受け取り、固定操作だけを冪等に実行します。</div>
        </div>
        {!dispatchConfigured ? (
          <p className="mt-4 text-[12px] text-[var(--warning)]">書き込み用DWDスコープ、専用資格情報、承認済みprovider workerが未接続のため、外部アカウントやライセンスはまだ変更しません。</p>
        ) : null}
      </section>
    </div>
  );
}
