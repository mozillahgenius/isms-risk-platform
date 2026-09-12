import Link from 'next/link';
import { getPasswordManagerStatus, type ClientSyncState, type EvidenceState, type IntegrationConnectionState, type PasswordManagerState } from '@/lib/passwordManager';

export const dynamic = 'force-dynamic';

export const metadata = { title: 'パスワード管理' };

const SERVICE_LABEL: Record<PasswordManagerState, string> = {
  unconfigured: '未設定',
  configured: '設定済み（ヘルス未接続）',
  available: '利用可能',
  unavailable: '利用不能',
  invalid_config: '設定不正',
};

const SERVICE_CLASS: Record<PasswordManagerState, string> = {
  unconfigured: 'badge badge-on-hold',
  configured: 'badge badge-on-hold',
  available: 'badge badge-done',
  unavailable: 'badge badge-danger',
  invalid_config: 'badge badge-danger',
};

const EVIDENCE_LABEL: Record<EvidenceState, string> = {
  recorded: '記録あり',
  not_recorded: '未記録',
  invalid: '設定不正',
};

const SYNC_LABEL: Record<ClientSyncState, string> = {
  synced: '同期済み',
  attention: '要確認',
  not_recorded: '未記録',
  invalid: '設定不正',
};

const INTEGRATION_LABEL: Record<IntegrationConnectionState, string> = {
  unimplemented: '未実装',
  planned: '予定',
  connected: '接続済み（設定値）',
  invalid: '設定不正',
};

function syncLabel(state: ClientSyncState, source: 'environment' | 'status_file'): string {
  const label = SYNC_LABEL[state];
  return source === 'environment' && (state === 'synced' || state === 'attention')
    ? `手動設定: ${label}${state === 'synced' ? '（未検証）' : ''}`
    : label;
}

function dateLabel(value: string | null): string {
  if (!value) return '未記録';
  return new Date(value).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' });
}

export default async function PasswordManagerPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  const mode = params.mode === 'isms' ? 'isms' : 'risk';
  const status = await getPasswordManagerStatus();
  const canOpenVault = status.state !== 'unconfigured' && status.state !== 'invalid_config';

  return (
    <div className="flex flex-col gap-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <span className="badge badge-note">ISMS 統制</span>
            <span className="text-xs text-[var(--muted)]">認証情報の保管先</span>
          </div>
          <h1 className="mt-2 text-[22px] font-semibold tracking-tight">パスワード管理</h1>
          <p className="mt-1 max-w-[820px] text-[13px] leading-6 text-[var(--muted)]">
            自社運用のパスワード基盤の入口と運用証跡をまとめます。パスワード、復旧コード、保管庫の暗号文、管理トークンは取得・保存・表示しません。
          </p>
        </div>
        <Link className="btn px-3 py-1.5 text-[12px]" href={`/operations?mode=${mode}`}>運用に戻る</Link>
      </header>

      <section className="card border-[var(--accent-line)] bg-[var(--accent-weak)] p-5">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <span className={SERVICE_CLASS[status.state]}>{SERVICE_LABEL[status.state]}</span>
            <h2 className="mt-3 text-[16px] font-semibold">{status.productName}</h2>
            <p className="mt-1 max-w-[720px] text-[13px] leading-6 text-[var(--fg-2)]">
              {status.provenance} management は保管庫を代理操作せず、接続状態と統制の証跡を分けて表示します。自社派生サーバーへの切替は、互換性・移行・復旧試験が完了するまで完了とは表示しません。
            </p>
          </div>
          {canOpenVault && status.vaultUrl ? (
            <a href={status.vaultUrl} target="_blank" rel="noreferrer" className="btn btn-primary shrink-0 px-3 py-2 text-sm">
              保管庫を開く ↗
            </a>
          ) : null}
        </div>
        {status.state === 'unconfigured' && (
          <p className="mt-4 text-[12px] text-[var(--muted)]">
            パスワード基盤の専用サービスURLが未設定です。保管庫の導入・認証情報の登録はこの画面では行いません。
          </p>
        )}
        {status.state === 'unavailable' && (
          <p className="mt-4 text-[12px] text-[var(--danger)]">
            許可済みヘルスパス <code>{status.healthPath ?? '未設定'}</code> の確認に失敗しました。障害を「利用者なし」や「同期済み」とは扱いません。
          </p>
        )}
        {status.state === 'invalid_config' && (
          <p className="mt-4 text-[12px] text-[var(--danger)]">
            サーバー側の非秘密設定に不正な値があります。許可済みのプロバイダー・製品・ヘルスパスと、認証情報を含まない HTTPS URL を指定してください。
          </p>
        )}
        {status.productId === 'vaultwarden-derived' && !status.cutoverReady && (
          <p className="mt-4 text-[12px] text-[var(--warning)]">
            派生版の上流ref・commit、fork commit、image digest、互換・移行・復旧ゲートの固定証跡が一致していないため、本番利用可能とは判定しません。
          </p>
        )}
      </section>

      <section>
        <h2 className="mb-1 text-[16px] font-semibold">運用状態</h2>
        <p className="mb-3 text-[12px] text-[var(--muted)]">未記録・設定不正・利用不能を、成功や0件に丸めません。{status.evidenceSource === 'status_file' ? 'バックアップ運用が出力したローカル非秘密ステータスを表示しています。' : '接続前の値は監査済み証跡ではなく、手動設定値として表示します。'}</p>
        <div className="card grid sm:grid-cols-2">
          <article className="border-b border-[var(--border)] p-4 sm:border-r">
            <div className="text-[12px] text-[var(--muted)]">サービス</div>
            <div className="mt-2 text-[15px] font-semibold">{SERVICE_LABEL[status.state]}</div>
            <div className="mt-1 text-[11px] text-[var(--muted)]">確認: {dateLabel(status.healthCheckedAt)}</div>
          </article>
          <article className="border-b border-[var(--border)] p-4">
            <div className="text-[12px] text-[var(--muted)]">最終バックアップ</div>
            <div className="mt-2 text-[15px] font-semibold">{status.lastBackup.state === 'recorded' && status.evidenceSource === 'environment' ? '手動設定値あり（未検証）' : EVIDENCE_LABEL[status.lastBackup.state]}</div>
            <div className="mt-1 text-[11px] text-[var(--muted)]">{dateLabel(status.lastBackup.at)}</div>
          </article>
          <article className="border-b border-[var(--border)] p-4 sm:border-b-0 sm:border-r">
            <div className="text-[12px] text-[var(--muted)]">最終復旧試験</div>
            <div className="mt-2 text-[15px] font-semibold">{status.lastRestoreTest.state === 'recorded' && status.evidenceSource === 'environment' ? '手動設定値あり（未検証）' : EVIDENCE_LABEL[status.lastRestoreTest.state]}</div>
            <div className="mt-1 text-[11px] text-[var(--muted)]">{dateLabel(status.lastRestoreTest.at)}</div>
          </article>
          <article className="p-4">
            <div className="text-[12px] text-[var(--muted)]">クライアント同期</div>
            <div className="mt-2 text-[15px] font-semibold">{syncLabel(status.clientSyncState, status.evidenceSource)}</div>
            <div className="mt-1 text-[11px] text-[var(--muted)]">端末側の同期状態のみ</div>
          </article>
        </div>
      </section>

      <section className="card p-5">
        <h2 className="text-[16px] font-semibold">統制境界</h2>
        <p className="mt-1 text-[12px] text-[var(--muted)]">連携の状態は非秘密設定に基づいて表示します。未実装・予定の機能を実施済みとして扱いません。</p>
        <div className="mt-3 grid gap-4 text-[13px] leading-6 text-[var(--fg-2)] md:grid-cols-3">
          <div><b className="text-[var(--fg)]">保管庫</b><br />人が使うパスワードと共有保管庫の管理だけを担当します。</div>
          <div><b className="text-[var(--fg)]">MDM</b><br /><span className="text-[var(--muted)]">{INTEGRATION_LABEL[status.mdmIntegrationState]}</span><br />公式クライアント／拡張機能の配布・稼働確認は、接続済みになるまで実行しません。</div>
          <div><b className="text-[var(--fg)]">証跡連携・運用操作</b><br /><span className="text-[var(--muted)]">{INTEGRATION_LABEL[status.evidenceIntegrationState]}</span><br />証跡連携と固定運用操作は、接続済みになるまで予定として扱います。</div>
        </div>
        <p className="mt-4 text-[12px] text-[var(--muted)]">
          いずれの経路も、人のパスワードやマスターパスワードを読み出しません。秘密値の登録・変更・閲覧は専用保管庫内で完結します。
        </p>
      </section>
    </div>
  );
}
