import 'server-only';

const commonFields = [
  'device_id',
  'collected_at',
  'agent_version',
  'definition_version',
  'definition_hash',
  'external_id',
  'hostname',
  'model',
  'os_family',
  'off_premise',
  'disk_encrypted',
  'screen_lock_enabled',
  'screen_lock_delay_sec',
  'os_version',
  'patch_current',
  'firewall_enabled',
  'edr_running',
  'admin_account_count',
  'password_manager_installed',
  'unapproved_apps',
];
const fieldsV1 = new Set([...commonFields, 'auto_update_enabled']);
const fieldsV2 = new Set([
  ...commonFields,
  'auto_update_checks_enabled',
  'application_inventory_mismatches',
  'edr_vendor',
  'builtin_protection',
]);

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const hashPattern = /^[0-9a-f]{64}$/;

export type AgentPayload = {
  device_id: string;
  collected_at: string;
  agent_version: string;
  definition_version: number;
  definition_hash: string;
  external_id: string;
  hostname: string;
  model: string;
  os_family: string;
  off_premise: boolean;
  disk_encrypted: boolean | null;
  screen_lock_enabled: boolean | null;
  screen_lock_delay_sec: number | null;
  os_version: string;
  patch_current: boolean | null;
  auto_update_checks_enabled?: boolean | null;
  auto_update_enabled?: boolean | null;
  application_inventory_mismatches?: string[];
  firewall_enabled: boolean | null;
  edr_running: boolean | null;
  edr_vendor: string;
  builtin_protection: BuiltinProtectionPayload | WindowsBuiltinProtectionPayload;
  admin_account_count: number | null;
  password_manager_installed: boolean | null;
  unapproved_apps: string[];
};

type BuiltinProtectionPayload = {
  xprotect_process_count: number;
  xprotect_definition_version: string;
  xprotect_remediator_version: string;
  spctl_assessments_enabled: boolean;
  csrutil_enabled: boolean;
  system_extensions: string[];
};

function nonEmptyString(value: unknown, field: string): asserts value is string {
  if (typeof value !== 'string' || value.trim() === '') throw new Error(`${field} is required`);
}

function nullableBoolean(value: unknown, field: string): void {
  if (value !== null && typeof value !== 'boolean') throw new Error(`${field} must be boolean or null`);
}

function nullableInteger(value: unknown, field: string): void {
  if (value !== null && (!Number.isInteger(value) || (value as number) < 0)) {
    throw new Error(`${field} must be a non-negative integer or null`);
  }
}

function requiredInteger(value: unknown, field: string): asserts value is number {
  if (!Number.isInteger(value) || (value as number) < 0) {
    throw new Error(`${field} must be a non-negative integer`);
  }
}

const HARDWARE_FIELDS = new Set(['cpu', 'cores', 'memory']);

/** hardware は { cpu?, cores?, memory? } の文字列だけ（各 200 文字まで）。知らない項目は断る。 */
function validateHardware(value: unknown): void {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('hardware must be an object');
  for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
    if (!HARDWARE_FIELDS.has(key)) throw new Error('hardware fields do not match the fixed contract');
    if (typeof item !== 'string' || item.length === 0 || item.length > 200) throw new Error(`hardware.${key} must be a short string`);
  }
}

export function validateAgentPayload(value: unknown): AgentPayload {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('payload must be an object');
  }
  const payload = value as Record<string, unknown>;
  if (payload.definition_version !== 1 && payload.definition_version !== 2) {
    throw new Error('definition_version is unsupported');
  }
  const fields = payload.definition_version === 1 ? fieldsV1 : fieldsV2;
  // hardware（PC の基礎情報）は固定の項目の外にある、あってもなくてもよい唯一の項目（2026-09-25）。
  // 古いエージェントの報告（hardware が無い）も受ける。中身は validateHardware で形を確かめる。
  const keys = Object.keys(payload).filter((key) => key !== 'hardware');
  if (keys.length !== fields.size || keys.some((key) => !fields.has(key))) {
    throw new Error('payload fields do not match the fixed posture contract');
  }
  if ('hardware' in payload) validateHardware(payload.hardware);

  for (const field of [
    'device_id', 'collected_at', 'agent_version', 'definition_hash',
    'external_id', 'hostname', 'model', 'os_family', 'os_version',
  ]) nonEmptyString(payload[field], field);
  // v1 は macOS だけ。v2 は macOS と Windows で、保護機能の形だけが OS ごとに違う（DB は端末の OS の定義で照合する）。
  if (payload.os_family !== 'macos' && !(payload.definition_version === 2 && payload.os_family === 'windows')) {
    throw new Error('os_family is unsupported');
  }
  if (payload.definition_version === 2) {
    nonEmptyString(payload.edr_vendor, 'edr_vendor');
    if (payload.os_family === 'windows') validateWindowsBuiltinProtection(payload.builtin_protection);
    else validateBuiltinProtection(payload.builtin_protection);
  }
  if (!uuidPattern.test(payload.device_id as string)) throw new Error('device_id is invalid');
  if (Number.isNaN(Date.parse(payload.collected_at as string))) throw new Error('collected_at is invalid');
  if (!hashPattern.test(payload.definition_hash as string)) throw new Error('definition_hash is invalid');
  if (typeof payload.off_premise !== 'boolean') throw new Error('off_premise must be boolean');

  for (const field of [
    'disk_encrypted', 'screen_lock_enabled', 'patch_current',
    'firewall_enabled', 'edr_running', 'password_manager_installed',
  ]) nullableBoolean(payload[field], field);
  const updateField = payload.definition_version === 1
    ? 'auto_update_enabled' : 'auto_update_checks_enabled';
  nullableBoolean(payload[updateField], updateField);
  if (payload.definition_version === 2) {
    const mismatches = payload.application_inventory_mismatches;
    if (!Array.isArray(mismatches)) throw new Error('application_inventory_mismatches must be an array');
    const sortedMismatches = [...mismatches].sort();
    if (JSON.stringify(mismatches) !== JSON.stringify(sortedMismatches)) {
      throw new Error('application_inventory_mismatches must be sorted');
    }
    const seenMismatches = new Set<string>();
    for (const mismatch of mismatches) {
      if (typeof mismatch !== 'string' || mismatch.trim() === '' || mismatch.length > 255 || /[\\/]/.test(mismatch)) {
        throw new Error('application_inventory_mismatches must contain names only');
      }
      if (seenMismatches.has(mismatch)) throw new Error('application_inventory_mismatches contains duplicates');
      seenMismatches.add(mismatch);
    }
  }
  nullableInteger(payload.screen_lock_delay_sec, 'screen_lock_delay_sec');
  nullableInteger(payload.admin_account_count, 'admin_account_count');

  if (!Array.isArray(payload.unapproved_apps)) throw new Error('unapproved_apps must be an array');
  const apps = payload.unapproved_apps;
  const sorted = [...apps].sort();
  if (JSON.stringify(apps) !== JSON.stringify(sorted)) throw new Error('unapproved_apps must be sorted');
  const seen = new Set<string>();
  for (const app of apps) {
    if (typeof app !== 'string' || app.trim() === '' || app.length > 255 || /[\\/]/.test(app)) {
      throw new Error('unapproved_apps must contain names only');
    }
    if (seen.has(app)) throw new Error('unapproved_apps contains duplicates');
    seen.add(app);
  }

  return payload as AgentPayload;
}

function validateBuiltinProtection(value: unknown): asserts value is BuiltinProtectionPayload {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('builtin_protection must be an object');
  }
  const protection = value as Record<string, unknown>;
  const fields = new Set([
    'xprotect_process_count',
    'xprotect_definition_version',
    'xprotect_remediator_version',
    'spctl_assessments_enabled',
    'csrutil_enabled',
    'system_extensions',
  ]);
  const keys = Object.keys(protection);
  if (keys.length !== fields.size || keys.some((key) => !fields.has(key))) {
    throw new Error('builtin_protection fields do not match the fixed contract');
  }
  requiredInteger(protection.xprotect_process_count, 'xprotect_process_count');
  nonEmptyString(protection.xprotect_definition_version, 'xprotect_definition_version');
  nonEmptyString(protection.xprotect_remediator_version, 'xprotect_remediator_version');
  if (typeof protection.spctl_assessments_enabled !== 'boolean') {
    throw new Error('spctl_assessments_enabled must be boolean');
  }
  if (typeof protection.csrutil_enabled !== 'boolean') {
    throw new Error('csrutil_enabled must be boolean');
  }
  const extensions = protection.system_extensions;
  if (!Array.isArray(extensions)) throw new Error('system_extensions must be an array');
  const sorted = [...extensions].sort();
  if (JSON.stringify(extensions) !== JSON.stringify(sorted)) {
    throw new Error('system_extensions must be sorted');
  }
  const seen = new Set<string>();
  for (const extension of extensions) {
    if (typeof extension !== 'string' || extension.trim() === '' || extension.length > 1000) {
      throw new Error('system_extensions must contain non-empty strings');
    }
    if (seen.has(extension)) throw new Error('system_extensions contains duplicates');
    seen.add(extension);
  }
}

// Windows の保護機能（Defender・Tamper Protection・SmartScreen）。SmartScreen は取れないことがあるので null を許す。
type WindowsBuiltinProtectionPayload = {
  defender_antivirus_enabled: boolean;
  defender_realtime_enabled: boolean;
  defender_signature_version: string;
  tamper_protection_enabled: boolean;
  smartscreen_enabled: boolean | null;
};

function validateWindowsBuiltinProtection(value: unknown): asserts value is WindowsBuiltinProtectionPayload {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('builtin_protection must be an object');
  }
  const protection = value as Record<string, unknown>;
  const fields = new Set([
    'defender_antivirus_enabled',
    'defender_realtime_enabled',
    'defender_signature_version',
    'tamper_protection_enabled',
    'smartscreen_enabled',
  ]);
  const keys = Object.keys(protection);
  if (keys.length !== fields.size || keys.some((key) => !fields.has(key))) {
    throw new Error('builtin_protection fields do not match the fixed contract');
  }
  for (const field of ['defender_antivirus_enabled', 'defender_realtime_enabled', 'tamper_protection_enabled']) {
    if (typeof protection[field] !== 'boolean') throw new Error(`${field} must be boolean`);
  }
  nonEmptyString(protection.defender_signature_version, 'defender_signature_version');
  nullableBoolean(protection.smartscreen_enabled, 'smartscreen_enabled');
}
