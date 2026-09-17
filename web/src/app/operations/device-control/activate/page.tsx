import Link from 'next/link';

import { lookupAgentInstallation } from '@/lib/agentDistributionServer';
import { trustedWebActorEmail } from '@/lib/tenant';

import { activateManagementEnrollmentForTarget } from './actions';

export const dynamic = 'force-dynamic';

const ERROR_TEXT: Record<string, string> = {
  failed: '認証要求を更新できませんでした。時間をおいて再試行してください。',
  invalid_session: 'ManagementのセッションまたはGWSログインを確認できません。GWSにログインした同じブラウザで、導入リンクを開き直してください。',
  trusted_proxy_identity_required: 'Managementが本人確認を取得できませんでした。GWSにログインした同じブラウザで、導入リンクを開き直してください。',
  no_token: 'Managementのサーバーセッション設定が無効です。管理者へ連絡してください。',
  error: 'Managementのデータベース接続に失敗しました。時間をおいて再試行してください。',
  forbidden: 'このGWSアカウントでは認証できません。送付先のアカウントでログインしてください。',
  invalid_target: 'この送付リンクに対応する認証要求が見つかりません。対象機器でインストーラを先に実行してください。',
  invalid_distribution: '送付リンクが不正です。',
  not_pending: 'この認証要求はすでに処理されています。',
};

export default async function ManagementTargetActivationPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  const token = typeof params.token === 'string' ? params.token.trim() : '';
  const manifest = token ? await lookupAgentInstallation(token) : null;
  const actorEmail = await trustedWebActorEmail();
  const done = params.done === 'approved';
  const errorKey = typeof params.error === 'string' ? params.error : '';
  return (
    <main className="mx-auto flex w-full max-w-[640px] flex-col gap-5 p-8">
      <section className="card p-6">
        <h1 className="text-xl font-bold">この機器をGmailでアクティベート</h1>
        {!manifest || manifest.auth_method !== 'gws' ? (
          <p className="mt-3 text-sm text-[var(--danger)]">導入リンクが無効です。管理者へ新しいリンクを依頼してください。</p>
        ) : (
          <>
            <p className="mt-3 text-sm leading-6 text-[var(--fg-2)]">この機器の導入ページから開いた専用画面です。ログイン中のGWS/Gmailアカウントが送付先メールアドレスと一致した場合だけ、この機器の認証要求を承認します。</p>
            <p className="mt-3 text-sm"><span className="text-[var(--muted)]">ログイン中:</span> <b className="break-all">{actorEmail ?? '—'}</b></p>
            <p className="mt-3 rounded-lg bg-[var(--accent-weak)] p-3 text-xs leading-5 text-[var(--fg-2)]">この方式では端末に表示された認証コードを入力しません。送付先アカウントでログインしたまま、下のボタンを押してください。</p>
          </>
        )}
      </section>
      {done && <p className="card p-5 text-sm font-semibold" role="status">Gmail認証を受け付けました。対象機器のAgentが数秒以内に登録を完了します。</p>}
      {errorKey && <p className="card p-4 text-sm text-[var(--danger)]" role="alert">{ERROR_TEXT[errorKey] ?? ERROR_TEXT.failed}</p>}
      {manifest?.auth_method === 'gws' && !done && token && (
        <form action={activateManagementEnrollmentForTarget} className="card flex flex-col gap-4 p-6">
          <input type="hidden" name="token" value={token} />
          <p className="text-sm">この機器で送付先アカウントにログイン済みであることを確認して、認証を実行してください。</p>
          <button className="btn btn-primary w-fit" type="submit">Gmailアカウントで認証してアクティベート</button>
        </form>
      )}
      <p className="text-sm"><Link href={token ? `/agent/install/${encodeURIComponent(token)}` : '/operations/device-control'} className="underline">導入ページへ戻る</Link></p>
    </main>
  );
}
