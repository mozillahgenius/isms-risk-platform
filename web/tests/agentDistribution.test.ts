import { describe, expect, it, vi } from 'vitest';

vi.mock('server-only', () => ({}));

import { agentWebOrigin } from '../src/lib/agentDistribution';

describe('agent distribution public origin', () => {
  it('uses the configured public origin instead of an internal request origin', () => {
    expect(agentWebOrigin({ ...process.env, ISMS_WEB_BASE_URL: 'https://management.example.invalid' }))
      .toBe('https://management.example.invalid');
  });

  it('returns null when the public origin is not configured', () => {
    expect(agentWebOrigin({ ...process.env, ISMS_WEB_BASE_URL: '' })).toBeNull();
  });
});
