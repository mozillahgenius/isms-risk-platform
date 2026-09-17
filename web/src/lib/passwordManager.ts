import 'server-only';
import { isIP } from 'node:net';
import { lookup } from 'node:dns/promises';
import { request as httpsRequest } from 'node:https';
import { lstat, open } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { IB_PASSWORD_RELEASE_LOCK, PASSWORD_STATUS_EVIDENCE_LOCK } from './passwordReleaseLock';

export const VAULTWARDEN_PRODUCT_NAME = 'Vaultwarden 1.37.2（Bitwarden互換・非公式サーバー）';
export const VAULTWARDEN_ALIVE_PATH = '/alive';
const DEFAULT_STATUS_FILE = '/var/lib/vaultwarden/status/management-status.json';
const MAX_STATUS_FILE_BYTES = 8_192;

/**
 * The management app is intentionally not a vault implementation.  It can only
 * connect to reviewed, Bitwarden-client-compatible server products.  Adding a
 * provider here is a deliberate security and migration decision, not a free-form
 * environment setting.
 */
const PASSWORD_MANAGER_PRODUCTS = {
  'vaultwarden-1.37.2': {
    provider: 'vaultwarden',
    productName: VAULTWARDEN_PRODUCT_NAME,
    provenance: 'Vaultwardenを利用中です。Bitwardenクライアント互換ですが、Bitwarden社の公式サーバーではありません。',
    healthPaths: [VAULTWARDEN_ALIVE_PATH],
    upstreamRef: '1.37.2',
    upstreamCommit: '46d71107f5094460dd5ecbe1dbac6e6c71e5189a',
    requiresCutoverEvidence: false,
  },
  'intelligent-beast-vaultwarden-derived': {
    provider: 'intelligent-beast-vaultwarden-derived',
    productName: 'Example Organization Password Server（Vaultwarden派生・Bitwardenクライアント互換）',
    provenance: 'Example OrganizationのVaultwarden派生候補です。実行中buildと切替ゲートの証跡が一致するまで、本番派生サーバーとは表示しません。',
    healthPaths: [VAULTWARDEN_ALIVE_PATH],
    upstreamRef: '1.37.2',
    upstreamCommit: '46d71107f5094460dd5ecbe1dbac6e6c71e5189a',
    requiresCutoverEvidence: true,
  },
} as const;

export type PasswordManagerProductId = keyof typeof PASSWORD_MANAGER_PRODUCTS;
export type PasswordManagerProvider = (typeof PASSWORD_MANAGER_PRODUCTS)[PasswordManagerProductId]['provider'];
const DEFAULT_PRODUCT_ID: PasswordManagerProductId = 'vaultwarden-1.37.2'; // gitleaks:allow — product identifier, not a credential

export type PasswordManagerState =
  | 'unconfigured'
  | 'configured'
  | 'available'
  | 'unavailable'
  | 'invalid_config';

export type EvidenceState = 'recorded' | 'not_recorded' | 'invalid';
export type ClientSyncState = 'synced' | 'attention' | 'not_recorded' | 'invalid';
export type IntegrationConnectionState = 'unimplemented' | 'planned' | 'connected' | 'invalid';

export type PasswordManagerConfig = {
  provider: PasswordManagerProvider | null;
  productId: PasswordManagerProductId | null;
  productName: string;
  provenance: string;
  vaultUrl: string | null;
  healthUrl: string | null;
  healthPath: string | null;
  allowedOrigin: string | null;
  lastBackupAt: string | null;
  lastRestoreTestAt: string | null;
  clientSyncState: ClientSyncState;
  allowPrivateNetwork: boolean;
  statusFile: string | null;
  mdmIntegrationState: IntegrationConnectionState;
  evidenceIntegrationState: IntegrationConnectionState;
  valid: boolean;
};

export type PasswordManagerStatus = {
  state: PasswordManagerState;
  provider: PasswordManagerProvider | null;
  productId: PasswordManagerProductId | null;
  productName: string;
  provenance: string;
  vaultUrl: string | null;
  healthPath: string | null;
  healthCheckedAt: string | null;
  lastBackup: { state: EvidenceState; at: string | null };
  lastRestoreTest: { state: EvidenceState; at: string | null };
  clientSyncState: ClientSyncState;
  evidenceSource: 'environment' | 'status_file';
  mdmIntegrationState: IntegrationConnectionState;
  evidenceIntegrationState: IntegrationConnectionState;
  cutoverReady: boolean;
};

type Environment = Record<string, string | undefined>;

function optionalValue(value: string | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

export function isAllowedPasswordManagerUrl(value: string | null, allowPrivateNetwork = false): value is string {
  if (!value) return false;

  try {
    const url = new URL(value);
    const hostname = url.hostname.replace(/^\[|\]$/g, '');
    return url.protocol === 'https:' && Boolean(url.hostname) && !url.username && !url.password && !url.search && !url.hash
      && (isIP(hostname) === 0 || allowPrivateNetwork || isPublicIpAddress(hostname));
  } catch {
    return false;
  }
}

export function isPublicIpAddress(address: string): boolean {
  const version = isIP(address);
  if (version === 4) {
    const [a, b] = address.split('.').map(Number);
    if (a === 0 || a === 10 || a === 127 || a >= 224) return false;
    if (a === 169 && b === 254) return false;
    if (a === 172 && b >= 16 && b <= 31) return false;
    if (a === 192 && b === 168) return false;
    if (a === 100 && b >= 64 && b <= 127) return false;
    return true;
  }
  if (version === 6) {
    const normalized = address.toLowerCase();
    if (normalized === '::' || normalized === '::1') return false;
    if (normalized.startsWith('fc') || normalized.startsWith('fd')) return false;
    if (/^fe[89ab]/.test(normalized)) return false;
    if (normalized.startsWith('::ffff:')) return isPublicIpAddress(normalized.slice(7));
    return true;
  }
  return false;
}

function isOriginOnly(value: string | null, allowPrivateNetwork: boolean): boolean {
  if (!isAllowedPasswordManagerUrl(value, allowPrivateNetwork)) return false;
  const url = new URL(value);
  return url.pathname === '/' && value === url.origin;
}

function sharesOrigin(vaultUrl: string | null, healthUrl: string | null): boolean {
  if (!healthUrl) return true;
  if (!vaultUrl) return false;
  return new URL(vaultUrl).origin === new URL(healthUrl).origin;
}

function healthUrlForPath(vaultUrl: string | null, healthPath: string | null): string | null {
  if (!vaultUrl || !healthPath) return null;
  try {
    return new URL(healthPath, vaultUrl).toString();
  } catch {
    return null;
  }
}

function allowedProduct(value: string | null): PasswordManagerProductId | null {
  if (!value) return DEFAULT_PRODUCT_ID;
  return Object.prototype.hasOwnProperty.call(PASSWORD_MANAGER_PRODUCTS, value)
    ? value as PasswordManagerProductId
    : null;
}

function productFor(provider: string | null, productId: PasswordManagerProductId | null): (typeof PASSWORD_MANAGER_PRODUCTS)[PasswordManagerProductId] | null {
  if (!productId) return null;
  const product = PASSWORD_MANAGER_PRODUCTS[productId];
  return !provider || provider === product.provider ? product : null;
}

function allowedHealthPath(value: string | null, product: (typeof PASSWORD_MANAGER_PRODUCTS)[PasswordManagerProductId] | null): string | null {
  if (!product) return null;
  const path = value ?? product.healthPaths[0];
  return product.healthPaths.includes(path as never) ? path : null;
}

function safeStatusFilePath(value: string | undefined): string | null {
  const configuredPath = optionalValue(value) ?? DEFAULT_STATUS_FILE;
  const expectedPath = resolve(DEFAULT_STATUS_FILE);
  return resolve(/* turbopackIgnore: true */ configuredPath) === expectedPath ? expectedPath : null;
}

export function evidenceState(value: string | null): EvidenceState {
  if (!value) return 'not_recorded';
  return Number.isNaN(Date.parse(value)) ? 'invalid' : 'recorded';
}

export function clientSyncState(value: string | null): ClientSyncState {
  if (!value) return 'not_recorded';
  if (value === 'synced' || value === 'attention') return value;
  return 'invalid';
}

export function integrationConnectionState(value: string | null, fallback: IntegrationConnectionState): IntegrationConnectionState {
  if (!value) return fallback;
  if (value === 'unimplemented' || value === 'planned' || value === 'connected') return value;
  return 'invalid';
}

export function readPasswordManagerConfig(environment: Environment = process.env): PasswordManagerConfig {
  const provider = optionalValue(environment.PASSWORD_MANAGER_PROVIDER);
  const productId = allowedProduct(optionalValue(environment.PASSWORD_MANAGER_PRODUCT));
  const product = productFor(provider, productId);
  const vaultUrl = optionalValue(environment.PASSWORD_MANAGER_URL);
  const configuredHealthUrl = optionalValue(environment.PASSWORD_MANAGER_HEALTH_URL);
  const configuredHealthPath = optionalValue(environment.PASSWORD_MANAGER_HEALTH_PATH);
  const healthPath = allowedHealthPath(configuredHealthPath, product);
  const healthUrl = configuredHealthUrl ?? healthUrlForPath(vaultUrl, healthPath);
  const allowedOrigin = optionalValue(environment.PASSWORD_MANAGER_ALLOWED_ORIGIN);
  const lastBackupAt = optionalValue(environment.PASSWORD_MANAGER_LAST_BACKUP_AT);
  const lastRestoreTestAt = optionalValue(environment.PASSWORD_MANAGER_LAST_RESTORE_TEST_AT);
  const syncState = clientSyncState(optionalValue(environment.PASSWORD_MANAGER_CLIENT_SYNC_STATUS));
  const allowPrivateNetwork = environment.PASSWORD_MANAGER_ALLOW_PRIVATE_NETWORK === 'true';
  const statusFile = safeStatusFilePath(environment.PASSWORD_MANAGER_STATUS_FILE);
  const mdmIntegrationState = integrationConnectionState(optionalValue(environment.PASSWORD_MANAGER_MDM_INTEGRATION_STATE), 'unimplemented');
  const evidenceIntegrationState = integrationConnectionState(optionalValue(environment.PASSWORD_MANAGER_EVIDENCE_INTEGRATION_STATE), 'planned');
  const valid =
    Boolean(product) &&
    (!configuredHealthPath || Boolean(healthPath)) &&
    (!vaultUrl || isAllowedPasswordManagerUrl(vaultUrl, allowPrivateNetwork)) &&
    (!vaultUrl || (isOriginOnly(allowedOrigin, allowPrivateNetwork) && new URL(vaultUrl).origin === allowedOrigin)) &&
    (!healthUrl || isAllowedPasswordManagerUrl(healthUrl, allowPrivateNetwork)) &&
    (!healthUrl || (isAllowedPasswordManagerUrl(vaultUrl, allowPrivateNetwork) && sharesOrigin(vaultUrl, healthUrl) && healthUrl === healthUrlForPath(vaultUrl, healthPath))) &&
    Boolean(statusFile) &&
    mdmIntegrationState !== 'invalid' &&
    evidenceIntegrationState !== 'invalid' &&
    evidenceState(lastBackupAt) !== 'invalid' &&
    evidenceState(lastRestoreTestAt) !== 'invalid' &&
    syncState !== 'invalid';

  return {
    provider: product?.provider ?? null,
    productId,
    productName: product?.productName ?? '未許可のパスワード基盤',
    provenance: product?.provenance ?? 'プロバイダーまたは製品設定が許可リストにありません。',
    vaultUrl,
    healthUrl,
    healthPath,
    allowedOrigin,
    lastBackupAt,
    lastRestoreTestAt,
    clientSyncState: syncState,
    allowPrivateNetwork,
    statusFile,
    mdmIntegrationState,
    evidenceIntegrationState,
    valid,
  };
}

function evidence(value: string | null): { state: EvidenceState; at: string | null } {
  return { state: evidenceState(value), at: evidenceState(value) === 'recorded' ? value : null };
}

type ResolvedAddress = { address: string; family: 4 | 6 };
type HealthRequest = (url: string, resolved: ResolvedAddress) => Promise<boolean>;
type StatusFileReader = (path: string) => Promise<{
  isFile(): boolean;
  isSymbolicLink(): boolean;
  size: number;
  uid: number;
  mode: number;
  parentIsDirectory(): boolean;
  parentIsSymbolicLink(): boolean;
  parentUid: number;
  parentMode: number;
  body: string;
}>;

export type VaultwardenStatusEvidence = {
  lastBackupAt: string | null;
  lastRestoreTestAt: string | null;
  clientSyncState: ClientSyncState;
  productId: PasswordManagerProductId | null;
  upstreamRef: string | null;
  upstreamCommit: string | null;
  forkCommit: string | null;
  imageDigest: string | null;
  compatibilityGate: 'passed' | 'pending' | null;
  migrationGate: 'passed' | 'pending' | null;
  recoveryGate: 'passed' | 'pending' | null;
};

// Keep the production filesystem dependency statically traceable for Turbopack.
const localStatusFileReader: StatusFileReader = async () => {
  const parent = await lstat(dirname(DEFAULT_STATUS_FILE));
  const handle = await open(DEFAULT_STATUS_FILE, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  try {
    const metadata = await handle.stat();
    if (!metadata.isFile() || metadata.size > MAX_STATUS_FILE_BYTES) {
      throw new Error('unsafe Vaultwarden status file');
    }
    return {
      isFile: () => true,
      isSymbolicLink: () => false,
      size: metadata.size,
      uid: metadata.uid,
      mode: metadata.mode,
      parentIsDirectory: () => parent.isDirectory(),
      parentIsSymbolicLink: () => parent.isSymbolicLink(),
      parentUid: parent.uid,
      parentMode: parent.mode,
      body: await handle.readFile({ encoding: 'utf8' }),
    };
  } finally {
    await handle.close();
  }
};

/** A fixed, non-secret provider status file is authoritative when configured; invalid data is never merged with env values. */
export async function readPasswordManagerStatusEvidence(
  path: string,
  reader: StatusFileReader = localStatusFileReader,
): Promise<VaultwardenStatusEvidence> {
  const file = await reader(path);
  const lock = PASSWORD_STATUS_EVIDENCE_LOCK;
  if (file.isSymbolicLink() || !file.isFile()
    || file.uid !== lock.writerUid || (file.mode & 0o777) !== lock.fileMode
    || file.parentIsSymbolicLink() || !file.parentIsDirectory()
    || file.parentUid !== lock.writerUid || (file.parentMode & 0o777) !== lock.directoryMode
    || file.size > MAX_STATUS_FILE_BYTES || file.body.length > MAX_STATUS_FILE_BYTES) {
    throw new Error('unsafe Vaultwarden status file');
  }
  const parsed: unknown = JSON.parse(file.body);
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('invalid Vaultwarden status JSON');
  const record = parsed as Record<string, unknown>;
  const keys = Object.keys(record);
  const allowed = [
    'last_backup_at', 'last_restore_test_at', 'client_sync_status',
    'product_id', 'upstream_ref', 'upstream_commit', 'fork_commit', 'image_digest',
    'compatibility_gate', 'migration_gate', 'recovery_gate',
  ];
  if (keys.some((key) => !allowed.includes(key)) || keys.some((key) => record[key] !== null && typeof record[key] !== 'string')) {
    throw new Error('invalid Vaultwarden status JSON');
  }
  const lastBackupAt = optionalValue(typeof record.last_backup_at === 'string' ? record.last_backup_at : undefined);
  const lastRestoreTestAt = optionalValue(typeof record.last_restore_test_at === 'string' ? record.last_restore_test_at : undefined);
  const sync = clientSyncState(optionalValue(typeof record.client_sync_status === 'string' ? record.client_sync_status : undefined));
  const productIdValue = optionalValue(typeof record.product_id === 'string' ? record.product_id : undefined);
  const productId = productIdValue ? allowedProduct(productIdValue) : null;
  const upstreamRef = optionalValue(typeof record.upstream_ref === 'string' ? record.upstream_ref : undefined);
  const upstreamCommit = optionalValue(typeof record.upstream_commit === 'string' ? record.upstream_commit : undefined);
  const forkCommit = optionalValue(typeof record.fork_commit === 'string' ? record.fork_commit : undefined);
  const imageDigest = optionalValue(typeof record.image_digest === 'string' ? record.image_digest : undefined);
  const compatibilityGate = optionalValue(typeof record.compatibility_gate === 'string' ? record.compatibility_gate : undefined);
  const migrationGate = optionalValue(typeof record.migration_gate === 'string' ? record.migration_gate : undefined);
  const recoveryGate = optionalValue(typeof record.recovery_gate === 'string' ? record.recovery_gate : undefined);
  if (evidenceState(lastBackupAt) === 'invalid' || evidenceState(lastRestoreTestAt) === 'invalid' || sync === 'invalid') {
    throw new Error('invalid Vaultwarden status JSON');
  }
  if ((productIdValue && !productId)
    || (upstreamCommit && !/^[0-9a-f]{40}$/.test(upstreamCommit))
    || (forkCommit && !/^[0-9a-f]{40}$/.test(forkCommit))
    || (imageDigest && !/^sha256:[0-9a-f]{64}$/.test(imageDigest))
    || [compatibilityGate, migrationGate, recoveryGate].some((gate) => gate !== null && gate !== 'passed' && gate !== 'pending')) {
    throw new Error('invalid Vaultwarden status JSON');
  }
  return {
    lastBackupAt,
    lastRestoreTestAt,
    clientSyncState: sync,
    productId,
    upstreamRef,
    upstreamCommit,
    forkCommit,
    imageDigest,
    compatibilityGate: compatibilityGate as 'passed' | 'pending' | null,
    migrationGate: migrationGate as 'passed' | 'pending' | null,
    recoveryGate: recoveryGate as 'passed' | 'pending' | null,
  };
}

/** @deprecated Compatibility alias for the existing Vaultwarden status writer. */
export const readVaultwardenStatusEvidence = readPasswordManagerStatusEvidence;

function cutoverEvidenceMatches(
  productId: PasswordManagerProductId | null,
  source: PasswordManagerStatus['evidenceSource'],
  value: VaultwardenStatusEvidence,
): boolean {
  if (!productId) return false;
  const product = PASSWORD_MANAGER_PRODUCTS[productId];
  if (!product.requiresCutoverEvidence) return true;
  const release = IB_PASSWORD_RELEASE_LOCK;
  return source === 'status_file'
    && value.productId === productId
    && productId === release.productId
    && value.upstreamRef === release.upstreamRef
    && value.upstreamCommit === release.upstreamCommit
    && release.forkCommit !== null
    && value.forkCommit === release.forkCommit
    && release.imageDigest !== null
    && value.imageDigest === release.imageDigest
    && value.compatibilityGate === 'passed'
    && value.migrationGate === 'passed'
    && value.recoveryGate === 'passed';
}

/** DNS検査で確認したIPへ接続を固定し、検査後の再解決を発生させない。 */
const pinnedHealthRequest: HealthRequest = (url, resolved) => new Promise((resolve) => {
  const req = httpsRequest(url, {
    method: 'GET',
    family: resolved.family,
    lookup: (_hostname, _options, callback) => callback(null, resolved.address, resolved.family),
    headers: { accept: 'application/json' },
  }, (response) => {
    response.resume();
    resolve(Boolean(response.statusCode && response.statusCode >= 200 && response.statusCode < 300));
  });
  req.setTimeout(2_500, () => req.destroy(new Error('timeout')));
  req.on('error', () => resolve(false));
  req.end();
});

export async function getPasswordManagerStatus(
  environment: Environment = process.env,
  request: HealthRequest = pinnedHealthRequest,
  resolveHost: (hostname: string) => Promise<ResolvedAddress[]> = async (hostname) => {
    const addresses = await lookup(hostname, { all: true });
    return addresses.flatMap((item) => item.family === 4 || item.family === 6
      ? [{ address: item.address, family: item.family }]
      : []);
  },
  statusReader: StatusFileReader = localStatusFileReader,
): Promise<PasswordManagerStatus> {
  const config = readPasswordManagerConfig(environment);
  let evidenceValues: VaultwardenStatusEvidence = {
    lastBackupAt: config.lastBackupAt,
    lastRestoreTestAt: config.lastRestoreTestAt,
    clientSyncState: config.clientSyncState,
    productId: null,
    upstreamRef: null,
    upstreamCommit: null,
    forkCommit: null,
    imageDigest: null,
    compatibilityGate: null,
    migrationGate: null,
    recoveryGate: null,
  };
  let evidenceSource: PasswordManagerStatus['evidenceSource'] = 'environment';
  if (config.statusFile && optionalValue(environment.PASSWORD_MANAGER_STATUS_FILE)) {
    try {
      evidenceValues = await readPasswordManagerStatusEvidence(config.statusFile, statusReader);
      evidenceSource = 'status_file';
    } catch {
      const base = {
        provider: config.provider,
        productId: config.productId,
        productName: config.productName,
        provenance: config.provenance,
        vaultUrl: isAllowedPasswordManagerUrl(config.vaultUrl, config.allowPrivateNetwork) ? config.vaultUrl : null,
        healthPath: config.healthPath,
        healthCheckedAt: null,
        lastBackup: evidence(config.lastBackupAt),
        lastRestoreTest: evidence(config.lastRestoreTestAt),
        clientSyncState: config.clientSyncState,
        evidenceSource,
        mdmIntegrationState: config.mdmIntegrationState,
        evidenceIntegrationState: config.evidenceIntegrationState,
        cutoverReady: false,
      };
      return { state: 'invalid_config', ...base };
    }
  }
  const cutoverReady = cutoverEvidenceMatches(config.productId, evidenceSource, evidenceValues);
  const base = {
    provider: config.provider,
    productId: config.productId,
    productName: config.productName,
    provenance: config.provenance,
    vaultUrl: isAllowedPasswordManagerUrl(config.vaultUrl, config.allowPrivateNetwork) ? config.vaultUrl : null,
    healthPath: config.healthPath,
    healthCheckedAt: null,
    lastBackup: evidence(evidenceValues.lastBackupAt),
    lastRestoreTest: evidence(evidenceValues.lastRestoreTestAt),
    clientSyncState: evidenceValues.clientSyncState,
    evidenceSource,
    mdmIntegrationState: config.mdmIntegrationState,
    evidenceIntegrationState: config.evidenceIntegrationState,
    cutoverReady,
  };

  if (!config.valid) return { state: 'invalid_config', ...base };
  if (!config.vaultUrl) return { state: 'unconfigured', ...base };
  if (!cutoverReady) return { state: 'configured', ...base };
  if (!config.healthUrl) return { state: 'configured', ...base };

  try {
    const hostname = new URL(config.healthUrl).hostname.replace(/^\[|\]$/g, '');
    const addresses = await resolveHost(hostname);
    if (addresses.length === 0 || (!config.allowPrivateNetwork && addresses.some(({ address }) => !isPublicIpAddress(address)))) {
      return { state: 'unavailable', ...base, healthCheckedAt: new Date().toISOString() };
    }
    const available = await request(config.healthUrl, addresses[0]!);
    return { state: available ? 'available' : 'unavailable', ...base, healthCheckedAt: new Date().toISOString() };
  } catch {
    return { state: 'unavailable', ...base, healthCheckedAt: new Date().toISOString() };
  }
}
