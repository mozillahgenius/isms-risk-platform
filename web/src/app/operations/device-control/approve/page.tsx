import { cookies } from 'next/headers';
import Link from 'next/link';

import { withTenantActor } from '@/lib/tenant';
import {
  formatManagementUserCode,
  hashManagementUserCode,
  managementLoginEnabled,
  normalizeManagementUserCode,
} from '@/lib/managementEnrollment';

import {
  decideManagementLoginRequest,
  enterManagementLoginCode,
} from '../enrollment-actions';

export const dynamic = 'force-dynamic';
const APPROVAL_COOKIE = 'management_device_approval';

const errors: Record<string, string> = {
  closed: 'GWSメール認証方式は現在停止しています。',
  format: 'コードの形式が違います。端末に表示された8文字を入力してください。',
  invalid: 'コードが見つかりません。期限切れまたは入力間違いです。',
  forbidden: 'この操作を承認する権限がありません。',
  not_pending: 'この要求はすでに処理済みです。',
  failed: '承認記録を書き込めませんでした。',
  no_token: 'Managementのセッションが確認できません。',
  invalid_session: 'GWS/OAuthのログイン状態が無効です。',
  error: 'Management DBを読み取れませんでした。',
};

type RequestView = {
  request_id: string;
  status: string;
  hostname: string;
  model: string;
  os_family: string;
  hardware_id: string;
  created_at: string;
  expires_at: string;
};

function formatDate(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? '—' : date.toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' });
}

export default async function ManagementDeviceApprovePage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  const enabled = managementLoginEnabled();
  const done = typeof params.done === 'string' ? params.done : null;
  const error = typeof params.error === 'string' ? errors[params.error] ?? errors.failed : null;
  const code = enabled && !done ? normalizeManagementUserCode((await cookies()).get(APPROVAL_COOKIE)?.value) : null;
  let view: RequestView | null = null;
  let lookupError: string | null = null;
  if (code) {
    const result = await withTenantActor(async (sql) => {
      const rows = await sql<{ result: RequestView & { ok?: boolean; reason?: string } }[]>`
        SELECT app.lookup_device_login_enrollment(${hashManagementUserCode(code)}) AS result
      `;
      return rows[0]?.result ?? { ok: false, reason: 'invalid' };
    });
    if (!result.ok) lookupError = errors[result.detail ?? result.reason] ?? errors.failed;
    else if (result.data.ok === true) view = result.data;
    else lookupError = errors[String(result.data.reason ?? 'invalid')] ?? errors.invalid;
  }

  return (
    <div className="mx-auto flex w-full max-w-[720px] flex-col gap-6">
      <div>
        <h1 className="text-xl font-bold tracking-tight">Managementの端末登録を承認</h1>
        <p className="mt-1 text-sm text-[var(--muted)]">
          GWS/OAuthで認証されたManagement管理者だけが、端末に表示されたコードを確認して承認できます。
          承認しても端末台帳への登録は、端末が署名付きで受け取った時点で完了します。
        </p>
      </div>

      <p className="card border-2 border-[var(--accent)] p-4 text-sm leading-6" role="note">
        配布リンクからGWS方式で導入した端末は、この画面を使いません。導入ページの「対象機器のGmailでアクティベートを開く」から、送付先アカウントで専用アクティベートを実行してください。この画面は配布リンクを使わない手動登録専用です。
      </p>

      {!enabled && <p className="card p-5 text-sm text-[var(--muted)]">{errors.closed}</p>}
      {done && <p className="card p-5 text-sm font-semibold" role="status">{done === 'approved' ? '承認しました。端末の受け取り後にManagement台帳へ登録されます。' : '断りました。この端末は登録されません。'}</p>}
      {(error || lookupError) && <p className="card p-4 text-sm text-[var(--danger)]" role="alert">{error ?? lookupError}</p>}

      {enabled && view && code && (
        <section className="card flex flex-col gap-4 p-4" aria-label="承認する端末">
          <p className="text-sm">端末の表示と以下の内容が一致することを確認してください。</p>
          <dl className="grid gap-3 sm:grid-cols-2">
            <div><dt className="text-xs text-[var(--muted)]">端末名</dt><dd className="text-lg font-semibold break-all">{view.hostname}</dd></div>
            <div><dt className="text-xs text-[var(--muted)]">機種</dt><dd className="text-lg font-semibold break-all">{view.model}</dd></div>
            <div><dt className="text-xs text-[var(--muted)]">OS</dt><dd className="text-lg font-semibold">{view.os_family}</dd></div>
            <div><dt className="text-xs text-[var(--muted)]">コード</dt><dd className="font-mono text-lg font-semibold">{formatManagementUserCode(code)}</dd></div>
            <div><dt className="text-xs text-[var(--muted)]">機体ID</dt><dd className="font-mono text-sm break-all">{view.hardware_id}</dd></div>
            <div><dt className="text-xs text-[var(--muted)]">期限</dt><dd className="text-sm">{formatDate(view.expires_at)}</dd></div>
          </dl>
          <form action={decideManagementLoginRequest} className="flex flex-wrap gap-3">
            <input type="hidden" name="request_id" value={view.request_id} />
            <button className="btn btn-primary" type="submit" name="decision" value="approve">承認する</button>
            <button className="btn" type="submit" name="decision" value="deny">断る</button>
          </form>
        </section>
      )}

      {enabled && (
        <form action={enterManagementLoginCode} className="card flex flex-col gap-3 p-4">
          <label className="text-sm">端末に表示されたコード
            <input className="input mt-1 w-full font-mono text-2xl tracking-widest" name="user_code" required autoComplete="off" autoCapitalize="characters" spellCheck={false} maxLength={32} placeholder="XXXX-XXXX" />
          </label>
          <p className="text-xs text-[var(--muted)]">メール・チャットで受け取ったコードではなく、登録する端末自身に表示されたコードを入力してください。</p>
          <div><button className="btn btn-primary" type="submit">端末を確認</button></div>
        </form>
      )}
      <p className="text-sm"><Link href="/operations/device-control" className="underline">デバイス管理へ戻る</Link></p>
    </div>
  );
}
