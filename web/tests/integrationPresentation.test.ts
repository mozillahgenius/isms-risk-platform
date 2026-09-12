import { describe, expect, it } from 'vitest';
import { summarizeManifest, summarizeRunError } from '../src/lib/integrationPresentation';

describe('収集設定の表示用変換', () => {
  it('マニフェストの構造だけを表示用に取り出す', () => {
    const summary = summarizeManifest({
      auth: { type: 'service_account_dwd', scopes: ['a', 'b'] },
      resources: [
        { name: 'users', map_to: 'accounts' },
        { name: 'groups', map_to: 'groups' },
        { endpoint: 'ignored' },
      ],
      sync: { full: 'weekly', incremental: 'hourly' },
      secret_ref: 'must-not-be-read',
    });

    expect(summary).toEqual({
      authType: 'service_account_dwd',
      scopes: 2,
      resources: [
        { name: 'users', mapTo: 'accounts' },
        { name: 'groups', mapTo: 'groups' },
      ],
      fullSchedule: 'weekly',
      incrementalSchedule: 'hourly',
    });
    expect(JSON.stringify(summary)).not.toContain('must-not-be-read');
  });

  it('外部エラーは安全な分類へ丸める', () => {
    expect(summarizeRunError('HTTP 403 missing_scope')).toBe('権限不足またはスコープ不足');
    expect(summarizeRunError('HTTP 429 rate limit')).toBe('レート制限');
    expect(summarizeRunError('unexpected provider response with token value')).toBe(
      '外部サービス側のエラー（詳細はサーバログ）',
    );
    expect(summarizeRunError(null)).toBeNull();
  });
});
