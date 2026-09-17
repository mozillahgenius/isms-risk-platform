'use client';

import { useActionState } from 'react';

import {
  issueManagementEnrollmentCode,
  type EnrollmentActionState,
} from './enrollment-actions';
import {
  issueAgentDistribution,
  type DistributionActionState,
} from './distribution-actions';

const initialState: EnrollmentActionState = { ok: false };
const initialDistributionState: DistributionActionState = {};
const agentOrigin = process.env.NEXT_PUBLIC_ISMS_AGENT_ENROLLMENT_ORIGIN
  || 'https://management.example.invalid';

const ENROLLMENT_STEPS = [
  { title: '送付する', description: '対象機器のGWSメールへ導入リンクを送ります。' },
  { title: '機器で導入する', description: '対象機器自身でリンクを開き、Agentを導入します。' },
  { title: '機器で認証する', description: 'GWS/Gmail、または登録コードで同じ機器を認証します。' },
  { title: '台帳で確認する', description: '認証結果が反映され、Managementの台帳で確認できます。' },
] as const;

export default function EnrollmentPanel() {
  const [state, action] = useActionState(issueManagementEnrollmentCode, initialState);
  const [distribution, distributionAction, distributionPending] = useActionState(issueAgentDistribution, initialDistributionState);
  return (
    <section className="card p-5" aria-label="Managementから端末を登録">
      <div>
        <h2 className="text-[15px] font-semibold">このManagementから端末を登録</h2>
        <p className="mt-1 max-w-[900px] text-[12px] leading-5 text-[var(--muted)]">
          ManagementはGWS/OAuthで管理者を認証し、端末台帳・登録コード・承認記録をManagement自身のDBに保存します。
          KanameやCodzillaへの委譲は行いません。
        </p>
      </div>

      <ol className="mt-4 grid gap-2 sm:grid-cols-4" aria-label="端末登録の流れ">
        {ENROLLMENT_STEPS.map((step, index) => (
          <li key={step.title} className="rounded-[var(--radius)] border border-[var(--border)] bg-[var(--surface-2)] p-3">
            <div className="flex items-center gap-2">
              <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-[var(--accent)] text-[11px] font-semibold text-[var(--accent-step-fg)]" aria-hidden="true">
                {index + 1}
              </span>
              <strong className="text-[12px]">{step.title}</strong>
            </div>
            <p className="mt-2 text-[11px] leading-5 text-[var(--muted)]">{step.description}</p>
          </li>
        ))}
      </ol>

      <div className="mt-1 rounded-[var(--radius)] border border-[var(--accent-line)] bg-[var(--accent-weak)] p-4">
        <h3 className="text-[13px] font-semibold">対象機器へAgentを送付する</h3>
        <p className="mt-2 text-[12px] leading-5 text-[var(--muted)]">
          ここで送付先と認証方式を決めます。メールのリンクは対象機器自身で開き、導入後の認証も同じ機器上で行います。
        </p>
        <form action={distributionAction} className="mt-3 grid gap-3 sm:grid-cols-2">
          <label className="text-[12px]">送付先GWSメール
            <input className="input mt-1 w-full" name="target_email" type="email" required placeholder="user@example.com" />
          </label>
          <label className="text-[12px]">宛名（任意）
            <input className="input mt-1 w-full" name="target_name" maxLength={255} />
          </label>
          <label className="text-[12px]">対象OS
            <select className="input mt-1 w-full" name="os_family" defaultValue="macos">
              <option value="macos">macOS</option>
              <option value="windows">Windows</option>
              <option value="linux">Linux</option>
            </select>
          </label>
          <fieldset className="sm:col-span-2">
            <legend className="text-[12px]">導入後の認証方式</legend>
            <div className="mt-2 grid gap-2 sm:grid-cols-2">
              <label className="cursor-pointer rounded-[var(--radius)] border border-[var(--border)] bg-[var(--surface)] p-3">
                <span className="flex items-start gap-2">
                  <input type="radio" name="auth_method" value="gws" defaultChecked />
                  <span>
                    <strong className="block text-[12px]">GWS / Gmailで認証</strong>
                    <span className="mt-1 block text-[11px] leading-5 text-[var(--muted)]">対象機器のブラウザで対象アカウントにログインし、導入ページの専用アクティベートを押します。共通の認証コード画面は使いません。</span>
                  </span>
                </span>
              </label>
              <label className="cursor-pointer rounded-[var(--radius)] border border-[var(--border)] bg-[var(--surface)] p-3">
                <span className="flex items-start gap-2">
                  <input type="radio" name="auth_method" value="code" />
                  <span>
                    <strong className="block text-[12px]">登録コードで認証</strong>
                    <span className="mt-1 block text-[11px] leading-5 text-[var(--muted)]">導入スクリプトが対象機器上でコードを消費します。</span>
                  </span>
                </span>
              </label>
            </div>
            <p className="mt-2 text-[11px] text-[var(--muted)]">どちらを選んでも、送付後の導入と認証は同じ機器上で行います。</p>
          </fieldset>
          <div className="sm:col-span-2">
            <button className="btn btn-primary" type="submit" disabled={distributionPending}>
              {distributionPending ? '導入リンクを発行中…' : '導入リンクをメール送付'}
            </button>
          </div>
        </form>
        {distribution.error && <p className="mt-3 text-[12px] text-[var(--danger)]" role="alert">送付できませんでした: {distribution.error}</p>}
        {distribution.ok && distribution.installUrl && (
          <div className="mt-3 rounded-[var(--radius)] bg-[var(--surface-2)] p-3" role="status">
            <p className="text-[11px] font-semibold">送付キューへ登録しました</p>
            <p className="mt-1 text-[11px] leading-5 text-[var(--muted)]">メールは送信キューから配信されます。ここではキュー登録完了を表示しています。</p>
            <ol className="mt-2 list-decimal space-y-1 pl-5 text-[11px] leading-5 text-[var(--muted)]">
              <li>対象機器のメールで導入リンクを開く</li>
              <li>対象OSの導入スクリプトを実行する</li>
              {distribution.authMethod === 'gws' ? (
                <>
                  <li>同じ機器の送付先Gmailで導入ページの専用アクティベートを開く</li>
                  <li>「Gmailアカウントで認証してアクティベート」を押す</li>
                </>
              ) : (
                <li>この画面で選んだ登録コード方式を、同じ機器上で完了する</li>
              )}
            </ol>
            <p className="mt-2 text-[11px] text-[var(--muted)]">テスト時の導入リンクはこの画面を閉じると再表示できません。</p>
            <code className="mt-2 block break-all font-[family-name:var(--font-geist-mono)] text-[11px]">{distribution.installUrl}</code>
          </div>
        )}
      </div>

      <details className="rounded-[var(--radius)] border border-[var(--border)] p-4">
        <summary className="cursor-pointer text-[13px] font-semibold">手動登録（配布リンクを使わない場合）</summary>
        <p className="mt-2 text-[12px] leading-5 text-[var(--muted)]">
          新規の端末は上の送付フローを使ってください。配布リンクからGWS方式で導入した端末は、ここではなく導入ページの専用アクティベートを使います。こちらは配布リンクを使わない手動登録だけに使用します。
        </p>
        <div className="mt-4 grid gap-4 lg:grid-cols-2">
          <div className="rounded-[var(--radius)] border border-[var(--border)] p-4">
            <h3 className="text-[13px] font-semibold">登録コードを発行する</h3>
            <p className="mt-2 text-[12px] leading-5 text-[var(--muted)]">
              管理者が一回限り・24時間のコードを発行し、端末上のAgentへ渡します。コードは画面に一度だけ表示されます。
            </p>
            <form action={action} className="mt-3">
              <button className="btn btn-primary" type="submit">Managementの登録コードを発行</button>
            </form>
            {state.error && <p className="mt-3 text-[12px] text-[var(--danger)]" role="alert">発行できませんでした: {state.error}</p>}
            {state.ok && state.token && (
              <div className="mt-3 rounded-[var(--radius)] bg-[var(--surface-2)] p-3">
                <p className="text-[11px] font-semibold text-[var(--badge-warning-fg)]">このコードはこの画面を閉じる前に端末へ渡してください。</p>
                <code className="mt-2 block break-all font-[family-name:var(--font-geist-mono)] text-[12px]">{state.token}</code>
                <p className="mt-3 text-[11px] text-[var(--muted)]">端末で実行する例（端末の値は端末上で入力）</p>
                <pre className="mt-1 overflow-x-auto whitespace-pre-wrap break-all text-[11px]">{`isms-agent enroll --url ${agentOrigin} --enrollment-token ${state.token} --external-id <機体ID> --hostname <端末名> --model <機種> --os-family <macos|windows|linux>`}</pre>
              </div>
            )}
          </div>

          <div className="rounded-[var(--radius)] border border-[var(--border)] p-4">
            <h3 className="text-[13px] font-semibold">端末の認証要求を確認する</h3>
            <p className="mt-2 text-[12px] leading-5 text-[var(--muted)]">
              端末が表示する8文字を、GWS/OAuthでログイン済みのManagement管理者が確認・承認します。
              承認後に端末が署名付きで受け取り、Managementの端末台帳へ登録されます。
            </p>
            <p className="mt-3 text-[11px] text-[var(--muted)]">端末で実行する例（登録コードは不要）</p>
            <pre className="mt-1 overflow-x-auto whitespace-pre-wrap break-all text-[11px]">{`isms-agent enroll --url ${agentOrigin} --external-id <機体ID> --hostname <端末名> --model <機種> --os-family <macos|windows|linux>`}</pre>
            <a className="btn btn-primary mt-4 inline-block" href="/operations/device-control/approve">手動登録の承認画面を開く</a>
          </div>
        </div>
      </details>
    </section>
  );
}
