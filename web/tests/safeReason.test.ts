import { describe, expect, it } from 'vitest';
import { safeReason } from '../src/lib/dbError';

describe('読めない理由の丸め', () => {
  it('期待している理由はそのまま出す', () => {
    expect(safeReason('tenant context is not set')).toContain('tenant context is not set');
    expect(
      safeReason('DB を読めませんでした: tenant context is not set\nCONTEXT: PL/pgSQL function'),
    ).toContain('tenant context is not set');
  });

  it('接続先・利用者名が混ざる文面は画面へ出さない', () => {
    const leaky = 'DB を読めませんでした: connect ECONNREFUSED 10.0.0.5:5432';
    expect(safeReason(leaky)).not.toContain('10.0.0.5');
    expect(safeReason(leaky)).not.toContain('5432');

    const auth = 'password authentication failed for user "app_ro"';
    expect(safeReason(auth)).not.toContain('app_ro');

    const dsn = 'getaddrinfo ENOTFOUND db.internal.example.com';
    expect(safeReason(dsn)).not.toContain('db.internal.example.com');
  });

  it('権限不足は種別だけ伝える', () => {
    expect(safeReason('permission denied for table tenants')).toContain('権限');
  });
});
