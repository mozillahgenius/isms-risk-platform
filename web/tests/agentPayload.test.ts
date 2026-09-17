import { describe, expect, it, vi } from 'vitest';

vi.mock('server-only', () => ({}));

const { validateAgentPayload } = await import('../src/lib/agent-payload');

const common = {
  device_id: '00000000-0000-4000-8000-000000000001',
  collected_at: '2026-09-13T00:00:00Z',
  agent_version: '0.1.0',
  definition_version: 2,
  definition_hash: 'a'.repeat(64),
  external_id: 'serial-1',
  hostname: 'host-1',
  model: 'model-1',
  off_premise: false,
  disk_encrypted: true,
  screen_lock_enabled: true,
  screen_lock_delay_sec: 300,
  os_version: '10.0.22631',
  patch_current: true,
  firewall_enabled: true,
  edr_running: true,
  admin_account_count: 1,
  password_manager_installed: false,
  unapproved_apps: [],
  auto_update_checks_enabled: true,
  application_inventory_mismatches: [],
  edr_vendor: 'none',
};

const macProtection = {
  xprotect_process_count: 1,
  xprotect_definition_version: '5300',
  xprotect_remediator_version: '150',
  spctl_assessments_enabled: true,
  csrutil_enabled: true,
  system_extensions: [],
};

const windowsProtection = {
  defender_antivirus_enabled: true,
  defender_realtime_enabled: true,
  defender_signature_version: '1.417.0.0',
  tamper_protection_enabled: true,
  smartscreen_enabled: null,
};

describe('posture の固定契約（OS ごとの保護機能）', () => {
  it('macOS の v2 は XProtect の形で通る', () => {
    expect(() => validateAgentPayload({ ...common, os_family: 'macos', builtin_protection: macProtection })).not.toThrow();
  });

  it('Windows の v2 は Defender・Tamper Protection・SmartScreen の形で通る（SmartScreen は null を許す）', () => {
    expect(() => validateAgentPayload({ ...common, os_family: 'windows', builtin_protection: windowsProtection })).not.toThrow();
  });

  it('Windows に XProtect の形を入れると落ちる', () => {
    expect(() => validateAgentPayload({ ...common, os_family: 'windows', builtin_protection: macProtection }))
      .toThrow('builtin_protection fields do not match the fixed contract');
  });

  it('macOS に Windows の形を入れると落ちる', () => {
    expect(() => validateAgentPayload({ ...common, os_family: 'macos', builtin_protection: windowsProtection }))
      .toThrow('builtin_protection fields do not match the fixed contract');
  });

  it('Windows の定義の版が空なら落ちる', () => {
    expect(() => validateAgentPayload({
      ...common, os_family: 'windows', builtin_protection: { ...windowsProtection, defender_signature_version: ' ' },
    })).toThrow('defender_signature_version is required');
  });

  it('Windows の必須の真偽値が null なら落ちる', () => {
    expect(() => validateAgentPayload({
      ...common, os_family: 'windows', builtin_protection: { ...windowsProtection, tamper_protection_enabled: null },
    })).toThrow('tamper_protection_enabled must be boolean');
  });

  it('v1 の Windows は落ちる（v1 は macOS だけ）', () => {
    const { application_inventory_mismatches: _m, edr_vendor: _e, auto_update_checks_enabled: _a, ...v1Common } = common;
    expect(() => validateAgentPayload({
      ...v1Common, definition_version: 1, os_family: 'windows', auto_update_enabled: true,
    })).toThrow('os_family is unsupported');
  });

  it('macOS と Windows 以外の OS は落ちる', () => {
    expect(() => validateAgentPayload({ ...common, os_family: 'linux', builtin_protection: macProtection }))
      .toThrow('os_family is unsupported');
  });
});
