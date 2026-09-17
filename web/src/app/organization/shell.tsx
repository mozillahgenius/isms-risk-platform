import 'server-only';
import Link from 'next/link';
import { MANAGEMENT_ROLE_LABEL, type ManagementRole } from '@/lib/organizationRegister';

/**
 * 組織管理の 4 タブで共通の枠（見出し・タブ・保存結果の通知）。
 *
 * layout.tsx にしなかったのは、Next の layout が searchParams を受け取れないため。
 * 保存結果（?saved=1 / ?error=...）とモード（?mode=isms|risk）はどちらも
 * クエリで来るので、枠を出す側がページでないと表示できない。
 */

export const ORGANIZATION_TABS = [
  { key: 'members', href: '/organization', label: 'メンバーマスタ' },
  { key: 'departments', href: '/organization/departments', label: '部門マスタ' },
  { key: 'systems', href: '/organization/systems', label: '利用システムマスタ' },
  { key: 'profile', href: '/organization/profile', label: '組織情報' },
] as const;

export type OrganizationTabKey = (typeof ORGANIZATION_TABS)[number]['key'];

export const ERROR_LABEL: Record<string, string> = {
  invalid_session: 'セッションが無効です。ページを再読み込みしてください。',
  no_token: 'テナントセッションが必要です。',
  duplicate_membership: 'この対象者は既に同じ役割を持っています。',
  duplicate_email: 'このメールアドレスの利用者は既に登録されています。名簿から権限を変更してください。',
  inactive_user: '対象者が見つからないか、無効化されています。',
  inactive_owner: '責任者が見つからないか、無効化されています。',
  department_cycle: '上位部門の指定が循環しています。別の部門を選んでください。',
  last_owner: 'オーナーが 0 人になる変更はできません。先に別のメンバーをオーナーにしてください。',
  self_status: '自分自身の在籍状態は変更できません。別のオーナー・管理者に依頼してください。',
  not_found: '対象が見つかりませんでした。画面を再読み込みしてください。',
  duplicate_system: '同じ名前のシステムが多すぎます。名称を変えてください。',
  system_in_use: 'このシステムを所在場所にしている情報資産があります。先に資産の所在を移してください。',
  invalid_input: '入力内容を確認してください。',
};

export const STATUS_LABEL: Record<string, string> = {
  active: '在籍', suspended: '停止', left: '退職',
};

export const SYSTEM_STATUS_LABEL: Record<string, string> = {
  active: '利用中', planned: '導入予定', paused: '停止中', retired: '廃止',
};

export function dash(value: string | null): string {
  return value ?? '—';
}

export function first(value: string | string[] | undefined): string {
  return Array.isArray(value) ? value[0] ?? '' : value ?? '';
}

export type SearchParams = Promise<Record<string, string | string[] | undefined>>;

/** ?mode= を保ったままリンクを作る。タブ移動でモードが落ちるとナビの並びが入れ替わる。 */
export function withMode(href: string, mode: string): string {
  return mode ? `${href}?mode=${encodeURIComponent(mode)}` : href;
}

/**
 * 保存後の戻り先をアクション側が決めるので（actions.ts の ORG_TAB）、
 * フォームには今のモードだけを渡す。これが無いと保存のたびにモードが落ちる。
 */
export function ModeField({ mode }: { mode: string }) {
  if (!mode) return null;
  return <input type="hidden" name="_mode" value={mode} />;
}

export function OrganizationShell({
  active, mode, saved, error, role, title, description, children,
}: {
  active: OrganizationTabKey;
  mode: string;
  saved: string;
  error: string;
  role: ManagementRole | null;
  title: string;
  description: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <div className="flex flex-col gap-5">
      <header>
        <div className="flex flex-wrap items-center gap-2">
          <span className="badge badge-note">組織管理</span>
          {role ? <span className="badge">現在の権限: {MANAGEMENT_ROLE_LABEL[role]}</span> : null}
        </div>
        <h1 className="mt-2 text-[22px] font-semibold tracking-tight">{title}</h1>
        <p className="mt-1 max-w-[900px] text-[13px] leading-6 text-[var(--muted)]">{description}</p>
      </header>

      <nav className="flex flex-wrap gap-2" aria-label="組織管理のマスタ">
        {ORGANIZATION_TABS.map((tab) => (
          <Link
            key={tab.key}
            href={withMode(tab.href, mode)}
            aria-current={tab.key === active ? 'page' : undefined}
            className={`btn px-3 py-1.5 text-[12px] ${tab.key === active ? 'btn-primary' : ''}`}
          >
            {tab.label}
          </Link>
        ))}
      </nav>

      {saved === '1' && (
        <section className="card border-[var(--success)] bg-[var(--success-weak)] p-4" role="status">
          <p className="text-sm font-semibold text-[var(--badge-success-fg)]">保存しました</p>
        </section>
      )}
      {error && (
        <section className="card border-[var(--danger)] bg-[var(--danger-weak)] p-4" role="alert">
          <p className="text-sm font-semibold text-[var(--badge-danger-fg)]">保存できませんでした</p>
          <p className="mt-1 text-xs text-[var(--fg-2)]">{ERROR_LABEL[error] ?? `原因区分: ${error}`}</p>
        </section>
      )}

      {children}
    </div>
  );
}

export function NoSession() {
  return (
    <div className="card p-5 text-[13px] text-[var(--muted)]">
      テナントセッションまたは信頼済みの利用者識別が必要です。
    </div>
  );
}
