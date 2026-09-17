import Link from 'next/link';

import { installerScriptUrl } from '@/lib/agentDistribution';
import { managementTargetActivationUri } from '@/lib/managementEnrollment';
import { lookupAgentInstallation } from '@/lib/agentDistributionServer';

export const dynamic = 'force-dynamic';

function dateText(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? '—' : date.toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' });
}

export default async function AgentInstallPage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const manifest = await lookupAgentInstallation(token);
  const shellUrl = manifest ? installerScriptUrl(token, 'sh') : null;
  const powershellUrl = manifest ? installerScriptUrl(token, 'ps1') : null;
  const targetActivationUrl = manifest?.auth_method === 'gws' ? managementTargetActivationUri(token) : null;
  const runCommandPrefix = manifest?.os_family === 'windows'
    ? 'PowerShell -ExecutionPolicy Bypass -File'
    : 'bash';
  if (!manifest) {
    return <main className="mx-auto max-w-[720px] p-8"><section className="card p-6" role="alert"><h1 className="text-xl font-bold">導入リンクが無効です</h1><p className="mt-3 text-sm text-[var(--muted)]">期限切れ、使用済み、または正しくないリンクです。管理者へ新しいリンクを依頼してください。</p></section></main>;
  }
  return (
    <main className="mx-auto flex max-w-[760px] flex-col gap-5 p-8">
      <section className="card p-6">
        <h1 className="text-xl font-bold">Example Organization エージェントをこの機器へ導入</h1>
        <p className="mt-3 text-sm leading-6 text-[var(--fg-2)]">
          このページを登録対象の機器で開いてください。導入後、対象機器上で
          {manifest.auth_method === 'gws' ? ' 対象機器専用のGmailアクティベート' : ' 登録コードを使った登録'}
          を行います。
        </p>
        <dl className="mt-5 grid gap-3 text-sm sm:grid-cols-2">
          <div><dt className="text-xs text-[var(--muted)]">対象OS</dt><dd className="font-semibold">{manifest.os_family}</dd></div>
          <div><dt className="text-xs text-[var(--muted)]">認証方式</dt><dd className="font-semibold">{manifest.auth_method === 'gws' ? 'GWS/Gmail' : '登録コード'}</dd></div>
          <div><dt className="text-xs text-[var(--muted)]">有効期限</dt><dd>{dateText(manifest.expires_at)}</dd></div>
          <div><dt className="text-xs text-[var(--muted)]">状態</dt><dd>{manifest.status}</dd></div>
        </dl>
      </section>
      <section className="card flex flex-col gap-3 p-6">
        <h2 className="font-semibold">導入スクリプトをダウンロード</h2>
        <p className="text-sm text-[var(--muted)]">ダウンロード後、その機器上で実行してください。リンクとスクリプトは一回限り・期限付きです。</p>
        <div className="flex flex-wrap gap-3">
          {manifest.os_family === 'macos' && shellUrl && <a className="btn btn-primary" href={shellUrl}>macOS用をダウンロード</a>}
          {manifest.os_family === 'linux' && shellUrl && <a className="btn btn-primary" href={shellUrl}>Linux用をダウンロード</a>}
          {manifest.os_family === 'windows' && powershellUrl && <a className="btn btn-primary" href={powershellUrl}>Windows用をダウンロード</a>}
        </div>
        <h3 className="font-semibold">ダウンロード後の操作</h3>
        <p className="text-xs text-[var(--muted)]">このファイルはアプリではなく、対象機器のターミナルまたはPowerShellで実行する導入スクリプトです。FinderやExplorerからダブルクリックして起動しないでください。まず次のコマンドを入力し、末尾に半角スペースを1つ追加してください。その後、ダウンロードしたファイルを同じウィンドウへドラッグ＆ドロップして、Enterを押してください。Management Agentは配布バイナリのため、Pythonは不要です。</p>
        <pre className="overflow-x-auto rounded-lg border border-[var(--border)] bg-[var(--surface-2)] p-3 text-xs leading-5"><code>{runCommandPrefix}</code></pre>
        <p className="text-xs text-[var(--muted)]">ファイルの保存先や、再ダウンロード時に付く別名を自動的に使えるため、現在のファイル名を手入力する必要はありません。</p>
        <p className="text-xs text-[var(--muted)]">ブラウザでリンクを開いた機器と、実際にスクリプトを実行する機器が違う場合は登録を完了できません。</p>
      </section>
      {targetActivationUrl && (
        <section className="card border-2 border-[var(--accent)] p-6" aria-label="GWS方式のアクティベート">
          <h2 className="text-base font-bold">次の操作：この機器のGmailでアクティベート</h2>
          <p className="mt-3 text-sm leading-6 text-[var(--fg-2)]">
            まず上の導入スクリプトを実行し、完了するまで待ってください。その後、同じ機器のブラウザで送付先GWS/Gmailにログインした状態で、下のボタンを押します。
          </p>
          <ol className="mt-3 list-decimal space-y-1 pl-5 text-sm leading-6 text-[var(--fg-2)]">
            <li>導入スクリプトを実行する</li>
            <li>送付先アカウントでGmailにログインする</li>
            <li>下の画面で「Gmailアカウントで認証してアクティベート」を押す</li>
          </ol>
          <p className="mt-3 rounded-lg bg-[var(--accent-weak)] p-3 text-xs leading-5 text-[var(--fg-2)]">
            GWS配布方式では、共通の「認証コード入力」画面や管理者用の手動承認画面は使いません。
          </p>
          <a className="btn btn-primary mt-4 w-fit" href={targetActivationUrl}>対象機器のGmailでアクティベートを開く</a>
        </section>
      )}
      <p className="text-xs text-[var(--muted)]"><Link href="/" className="underline">Managementへ戻る</Link></p>
    </main>
  );
}
