import { afterEach, describe, expect, it, vi } from 'vitest';

// deviceControl.ts は 'server-only' と 'next/headers' に依存するため、両方をモックして
// authorizedActorEmail() 自身が実際にどのヘッダ名を読むかを直接検証する。
// (2026-09-01 のCodexレビュー指摘: ヘッダ名を x-auth-request-email → x-forwarded-email へ
// 修正した際、この関数自体の回帰テストが無く、旧ヘッダ名のままでも既存テストは全て
// 通ってしまっていた。)

vi.mock('server-only', () => ({}));

function mockHeaders(entries: Record<string, string>) {
  const map = new Map(Object.entries(entries));
  return {
    headers: vi.fn(async () => ({
      get: (key: string) => map.get(key.toLowerCase()) ?? null,
    })),
  };
}

const PROXY_SECRET = 'a'.repeat(32);
const ALLOWED = 'admin@example.invalid';

async function loadWithHeaders(entries: Record<string, string>) {
  vi.resetModules();
  vi.doMock('next/headers', () => mockHeaders(entries));
  vi.stubEnv('ISMS_DEVICE_CONTROL_PROXY_SECRET', PROXY_SECRET);
  vi.stubEnv('ISMS_DEVICE_CONTROL_ALLOWED_EMAILS', ALLOWED);
  const mod = await import('../src/lib/deviceControl');
  return mod.authorizedActorEmail();
}

describe('authorizedActorEmail() が実際に読むヘッダ名', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it('x-forwarded-email + 正しい共有シークレットなら許可する', async () => {
    const email = await loadWithHeaders({
      'x-ib-device-control-proxy-secret': PROXY_SECRET,
      'x-forwarded-email': ALLOWED,
    });
    expect(email).toBe(ALLOWED);
  });

  it('旧ヘッダ名 x-auth-request-email だけでは許可しない(この経路では転送されないヘッダのため)', async () => {
    const email = await loadWithHeaders({
      'x-ib-device-control-proxy-secret': PROXY_SECRET,
      'x-auth-request-email': ALLOWED,
    });
    expect(email).toBeNull();
  });

  it('共有シークレットが無ければ x-forwarded-email が正しくても許可しない', async () => {
    const email = await loadWithHeaders({
      'x-forwarded-email': ALLOWED,
    });
    expect(email).toBeNull();
  });
});
