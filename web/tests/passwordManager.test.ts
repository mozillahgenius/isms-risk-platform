import { describe, expect, it, vi } from 'vitest';

vi.mock('server-only', () => ({}));

import {
  clientSyncState,
  evidenceState,
  getPasswordManagerStatus,
  integrationConnectionState,
  isAllowedPasswordManagerUrl,
  isPublicIpAddress,
  readPasswordManagerConfig,
  readVaultwardenStatusEvidence,
  VAULTWARDEN_PRODUCT_NAME,
} from '../src/lib/passwordManager';

function trustedStatusFile(body: string, overrides: Record<string, unknown> = {}) {
  return {
    isFile: () => true,
    isSymbolicLink: () => false,
    uid: 1001,
    mode: 0o100600,
    parentIsDirectory: () => true,
    parentIsSymbolicLink: () => false,
    parentUid: 1001,
    parentMode: 0o40700,
    size: body.length,
    body,
    ...overrides,
  };
}

describe('パスワード管理の非秘密設定', () => {
  it('認証情報を含むURLやHTTP URLを拒否する', () => {
    expect(isAllowedPasswordManagerUrl('https://vault.example.com')).toBe(true);
    expect(isAllowedPasswordManagerUrl('http://vault.example.com')).toBe(false);
    expect(isAllowedPasswordManagerUrl('https://token@vault.example.com')).toBe(false);
    expect(isAllowedPasswordManagerUrl('https://vault.example.com/alive?token=value')).toBe(false);
    expect(isAllowedPasswordManagerUrl('not-a-url')).toBe(false);
    expect(isAllowedPasswordManagerUrl('https://127.0.0.1')).toBe(false);
    expect(isAllowedPasswordManagerUrl('https://[::1]')).toBe(false);
    expect(isPublicIpAddress('8.8.8.8')).toBe(true);
    expect(isPublicIpAddress('10.0.0.1')).toBe(false);
  });

  it('証跡と同期状態は未記録・不正を成功に丸めない', () => {
    expect(evidenceState(null)).toBe('not_recorded');
    expect(evidenceState('not-a-date')).toBe('invalid');
    expect(evidenceState('2026-09-04T00:00:00Z')).toBe('recorded');
    expect(clientSyncState(null)).toBe('not_recorded');
    expect(clientSyncState('unexpected')).toBe('invalid');
    expect(clientSyncState('attention')).toBe('attention');
    expect(integrationConnectionState(null, 'unimplemented')).toBe('unimplemented');
    expect(integrationConnectionState('connected', 'planned')).toBe('connected');
    expect(integrationConnectionState('claimed', 'planned')).toBe('invalid');
  });

  it('URLまたは非秘密ステータスが不正ならinvalid_configになる', async () => {
    const fetcher = vi.fn();
    const status = await getPasswordManagerStatus({
      PASSWORD_MANAGER_URL: 'http://vault.example.com',
      PASSWORD_MANAGER_CLIENT_SYNC_STATUS: 'synced',
    }, fetcher);
    expect(status.state).toBe('invalid_config');
    expect(fetcher).not.toHaveBeenCalled();
    await expect(getPasswordManagerStatus({
      PASSWORD_MANAGER_URL: 'https://vault.example.com',
      PASSWORD_MANAGER_ALLOWED_ORIGIN: 'https://vault.example.com',
      PASSWORD_MANAGER_HEALTH_URL: 'https://unrelated.example.com/alive',
    }, fetcher)).resolves.toMatchObject({ state: 'invalid_config' });
  });

  it('URL未設定はunconfigured、Vaultwardenは既定の/aliveを確認する', async () => {
    await expect(getPasswordManagerStatus({}, vi.fn())).resolves.toMatchObject({ state: 'unconfigured' });
    await expect(getPasswordManagerStatus({
      PASSWORD_MANAGER_URL: 'https://vault.example.com',
      PASSWORD_MANAGER_ALLOWED_ORIGIN: 'https://vault.example.com',
    }, vi.fn().mockResolvedValue(true), async () => [{ address: '8.8.8.8', family: 4 }]))
      .resolves.toMatchObject({ state: 'available', vaultUrl: 'https://vault.example.com' });
  });

  it('ヘルス失敗を利用可能にしない', async () => {
    const status = await getPasswordManagerStatus({
      PASSWORD_MANAGER_URL: 'https://vault.example.com',
      PASSWORD_MANAGER_ALLOWED_ORIGIN: 'https://vault.example.com',
      PASSWORD_MANAGER_HEALTH_URL: 'https://vault.example.com/alive',
    }, vi.fn().mockResolvedValue(false), async () => [{ address: '8.8.8.8', family: 4 }]);
    expect(status.state).toBe('unavailable');
  });

  it('ヘルス確認は資格情報とリダイレクトを送らない', async () => {
    const fetcher = vi.fn().mockResolvedValue(true);
    const status = await getPasswordManagerStatus({
      PASSWORD_MANAGER_URL: 'https://vault.example.com',
      PASSWORD_MANAGER_ALLOWED_ORIGIN: 'https://vault.example.com',
      PASSWORD_MANAGER_HEALTH_URL: 'https://vault.example.com/alive',
    }, fetcher, async () => [{ address: '8.8.8.8', family: 4 }]);
    expect(status.state).toBe('available');
    expect(fetcher).toHaveBeenCalledWith(
      'https://vault.example.com/alive',
      { address: '8.8.8.8', family: 4 },
    );
  });

  it('有効な非秘密設定だけを読み取る', () => {
    const config = readPasswordManagerConfig({
      PASSWORD_MANAGER_URL: 'https://vault.example.com',
      PASSWORD_MANAGER_ALLOWED_ORIGIN: 'https://vault.example.com',
      PASSWORD_MANAGER_LAST_BACKUP_AT: '2026-09-04T00:00:00Z',
      PASSWORD_MANAGER_LAST_RESTORE_TEST_AT: '2026-09-03T00:00:00Z',
      PASSWORD_MANAGER_CLIENT_SYNC_STATUS: 'synced',
    });
    expect(config).toMatchObject({ productName: VAULTWARDEN_PRODUCT_NAME, valid: true, clientSyncState: 'synced' });
  });

  it('プロバイダー・製品・ヘルスパスは許可リストからだけ選択する', () => {
    expect(readPasswordManagerConfig({
      PASSWORD_MANAGER_PROVIDER: 'vaultwarden-derived',
      PASSWORD_MANAGER_PRODUCT: 'vaultwarden-derived',
      PASSWORD_MANAGER_HEALTH_PATH: '/alive',
      PASSWORD_MANAGER_URL: 'https://vault.example.com',
      PASSWORD_MANAGER_ALLOWED_ORIGIN: 'https://vault.example.com',
    })).toMatchObject({
      provider: 'vaultwarden-derived',
      productId: 'vaultwarden-derived',
      healthPath: '/alive',
      valid: true,
    });
    expect(readPasswordManagerConfig({ PASSWORD_MANAGER_PROVIDER: 'unknown-provider' }))
      .toMatchObject({ valid: false });
    expect(readPasswordManagerConfig({ PASSWORD_MANAGER_PRODUCT: 'unreviewed-product' }))
      .toMatchObject({ productId: null, valid: false });
    expect(readPasswordManagerConfig({ PASSWORD_MANAGER_HEALTH_PATH: '/internal/health' }))
      .toMatchObject({ healthPath: null, valid: false });
  });

  it('自社派生版は切替証跡が無ければ利用可能にしない', async () => {
    const request = vi.fn().mockResolvedValue(true);
    const status = await getPasswordManagerStatus({
      PASSWORD_MANAGER_PROVIDER: 'vaultwarden-derived',
      PASSWORD_MANAGER_PRODUCT: 'vaultwarden-derived',
      PASSWORD_MANAGER_URL: 'https://vault.example.com',
      PASSWORD_MANAGER_ALLOWED_ORIGIN: 'https://vault.example.com',
    }, request, async () => [{ address: '8.8.8.8', family: 4 }]);
    expect(status).toMatchObject({ state: 'configured', cutoverReady: false });
    expect(request).not.toHaveBeenCalled();
  });

  it('自社派生版はstatus値が整形式でもreview済みrelease lockが空なら利用可能にしない', async () => {
    const body = JSON.stringify({
      product_id: 'vaultwarden-derived',
      upstream_ref: '1.37.2',
      upstream_commit: '46d71107f5094460dd5ecbe1dbac6e6c71e5189a',
      fork_commit: '1111111111111111111111111111111111111111',
      image_digest: `sha256:${'2'.repeat(64)}`,
      compatibility_gate: 'passed',
      migration_gate: 'passed',
      recovery_gate: 'passed',
      last_backup_at: '2026-09-04T00:00:00Z',
      last_restore_test_at: '2026-09-04T01:00:00Z',
      client_sync_status: 'synced',
    });
    const status = await getPasswordManagerStatus({
      PASSWORD_MANAGER_PROVIDER: 'vaultwarden-derived',
      PASSWORD_MANAGER_PRODUCT: 'vaultwarden-derived',
      PASSWORD_MANAGER_URL: 'https://vault.example.com',
      PASSWORD_MANAGER_ALLOWED_ORIGIN: 'https://vault.example.com',
      PASSWORD_MANAGER_STATUS_FILE: '/var/lib/vaultwarden/status/management-status.json',
    }, vi.fn().mockResolvedValue(true), async () => [{ address: '8.8.8.8', family: 4 }], async () => trustedStatusFile(body));
    expect(status).toMatchObject({ state: 'configured', cutoverReady: false, evidenceSource: 'status_file' });
  });

  it('MDMと証跡連携は未実装・予定を既定にし、未知状態を拒否する', () => {
    expect(readPasswordManagerConfig({})).toMatchObject({
      mdmIntegrationState: 'unimplemented',
      evidenceIntegrationState: 'planned',
      valid: true,
    });
    expect(readPasswordManagerConfig({
      PASSWORD_MANAGER_MDM_INTEGRATION_STATE: 'connected',
      PASSWORD_MANAGER_EVIDENCE_INTEGRATION_STATE: 'unknown',
    })).toMatchObject({ valid: false, mdmIntegrationState: 'connected', evidenceIntegrationState: 'invalid' });
  });

  it('DNS解決後に内部アドレスへ向くヘルス確認を拒否する', async () => {
    const fetcher = vi.fn();
    const status = await getPasswordManagerStatus({
      PASSWORD_MANAGER_URL: 'https://vault.example.com',
      PASSWORD_MANAGER_ALLOWED_ORIGIN: 'https://vault.example.com',
      PASSWORD_MANAGER_HEALTH_URL: 'https://vault.example.com/alive',
    }, fetcher, async () => [{ address: '192.168.1.10', family: 4 }]);
    expect(status.state).toBe('unavailable');
    expect(fetcher).not.toHaveBeenCalled();
  });

  it('限定ネットワーク接続は明示設定した場合だけ許可する', async () => {
    const request = vi.fn().mockResolvedValue(true);
    const status = await getPasswordManagerStatus({
      PASSWORD_MANAGER_URL: 'https://10.0.0.8',
      PASSWORD_MANAGER_ALLOWED_ORIGIN: 'https://10.0.0.8',
      PASSWORD_MANAGER_HEALTH_URL: 'https://10.0.0.8/alive',
      PASSWORD_MANAGER_ALLOW_PRIVATE_NETWORK: 'true',
    }, request, async () => [{ address: '10.0.0.8', family: 4 }]);
    expect(status.state).toBe('available');
    expect(request).toHaveBeenCalledWith('https://10.0.0.8/alive', { address: '10.0.0.8', family: 4 });
  });

  it('Vaultwardenのローカルstatus JSONを手動env値より優先する', async () => {
    const status = await getPasswordManagerStatus({
      PASSWORD_MANAGER_URL: 'https://vault.example.com',
      PASSWORD_MANAGER_ALLOWED_ORIGIN: 'https://vault.example.com',
      PASSWORD_MANAGER_LAST_BACKUP_AT: '2020-01-01T00:00:00Z',
      PASSWORD_MANAGER_STATUS_FILE: '/var/lib/vaultwarden/status/management-status.json',
    }, vi.fn().mockResolvedValue(true), async () => [{ address: '8.8.8.8', family: 4 }], async () => trustedStatusFile(
      '{"last_backup_at":"2026-09-04T00:00:00Z","last_restore_test_at":"2026-09-03T00:00:00Z","client_sync_status":"synced"}',
    ));
    expect(status).toMatchObject({ evidenceSource: 'status_file', lastBackup: { at: '2026-09-04T00:00:00Z' } });
  });

  it('危険なVaultwarden status fileをfail-closedにする', async () => {
    const environment = {
      PASSWORD_MANAGER_URL: 'https://vault.example.com',
      PASSWORD_MANAGER_ALLOWED_ORIGIN: 'https://vault.example.com',
      PASSWORD_MANAGER_STATUS_FILE: '/var/lib/vaultwarden/status/management-status.json',
    };
    await expect(getPasswordManagerStatus(environment, vi.fn(), async () => [], async () => trustedStatusFile('{}', {
      isSymbolicLink: () => true,
    }))).resolves.toMatchObject({ state: 'invalid_config' });
    await expect(getPasswordManagerStatus(environment, vi.fn(), async () => [], async () => trustedStatusFile('{}', {
      uid: 501,
      mode: 0o100666,
    }))).resolves.toMatchObject({ state: 'invalid_config' });
    await expect(getPasswordManagerStatus(environment, vi.fn(), async () => [], async () => trustedStatusFile('{}', {
      parentUid: 0,
      parentMode: 0o40777,
    }))).resolves.toMatchObject({ state: 'invalid_config' });
    await expect(readVaultwardenStatusEvidence('/var/lib/vaultwarden/status/management-status.json', async () => trustedStatusFile('{}', {
      size: 8_193,
    }))).rejects.toThrow('unsafe Vaultwarden status file');
    await expect(readVaultwardenStatusEvidence('/var/lib/vaultwarden/status/management-status.json', async () => trustedStatusFile('{}')))
      .resolves.toMatchObject({ clientSyncState: 'not_recorded' });
  });

  it('初回Vaultwarden statusのnullまたは省略を未記録として受理する', async () => {
    await expect(readVaultwardenStatusEvidence('/var/lib/vaultwarden/status/management-status.json', async () => trustedStatusFile(
      '{"last_backup_at":null,"last_restore_test_at":null,"client_sync_status":null}',
    ))).resolves.toMatchObject({
      lastBackupAt: null,
      lastRestoreTestAt: null,
      clientSyncState: 'not_recorded',
    });
    await expect(readVaultwardenStatusEvidence('/var/lib/vaultwarden/status/management-status.json', async () => trustedStatusFile('{}')))
      .resolves.toMatchObject({ clientSyncState: 'not_recorded' });
  });

  it('Vaultwarden status JSONの未知キーは拒否する', async () => {
    await expect(readVaultwardenStatusEvidence('/var/lib/vaultwarden/status/management-status.json', async () => trustedStatusFile(
      '{"last_backup_at":null,"provider":"x"}',
    ))).rejects.toThrow('invalid Vaultwarden status JSON');
  });

  it('status fileは正規化後も固定ファイル以外を許可しない', () => {
    const config = readPasswordManagerConfig({
      PASSWORD_MANAGER_URL: 'https://vault.example.com',
      PASSWORD_MANAGER_ALLOWED_ORIGIN: 'https://vault.example.com',
      PASSWORD_MANAGER_STATUS_FILE: '/var/lib/vaultwarden/status/../../etc/passwd',
    });
    expect(config).toMatchObject({ statusFile: null, valid: false });
  });
});
