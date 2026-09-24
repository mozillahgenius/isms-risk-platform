import { describe, expect, it, vi } from 'vitest';

vi.mock('server-only', () => ({}));

import { agentWebOrigin, installUrl } from '../src/lib/agentDistribution';
import { managementAgentOrigin, managementTargetActivationUri } from '../src/lib/managementEnrollment';

describe('agent distribution public origin', () => {
  it('uses the configured public origin instead of an internal request origin', () => {
    expect(agentWebOrigin({ ...process.env, ISMS_WEB_BASE_URL: 'https://management.example.invalid' }))
      .toBe('https://management.example.invalid');
  });

  it('keeps a basePath so links do not land on the parent app', () => {
    const token = 't'.repeat(40);
    const env = { ...process.env, ISMS_WEB_BASE_URL: 'https://portal.example.invalid/risk/' };
    expect(agentWebOrigin(env)).toBe('https://portal.example.invalid/risk');
    expect(installUrl(token, env)).toBe(`https://portal.example.invalid/risk/agent/install/${token}`);
    const enrollmentEnv = { ...process.env, ISMS_AGENT_ENROLLMENT_ORIGIN: 'https://portal.example.invalid/risk' };
    expect(managementAgentOrigin(enrollmentEnv)).toBe('https://portal.example.invalid/risk');
    expect(managementTargetActivationUri(token, enrollmentEnv))
      .toBe(`https://portal.example.invalid/risk/operations/device-control/activate?token=${token}`);
  });

  it('still rejects credentials, query strings and fragments', () => {
    for (const bad of ['https://u:p@portal.example.invalid/risk', 'https://portal.example.invalid/risk?x=1', 'https://portal.example.invalid/risk#x']) {
      expect(agentWebOrigin({ ...process.env, ISMS_WEB_BASE_URL: bad })).toBeNull();
      expect(managementAgentOrigin({ ...process.env, ISMS_AGENT_ENROLLMENT_ORIGIN: bad })).toBeNull();
    }
  });

  it('returns null when the public origin is not configured', () => {
    expect(agentWebOrigin({ ...process.env, ISMS_WEB_BASE_URL: '' })).toBeNull();
  });
});
