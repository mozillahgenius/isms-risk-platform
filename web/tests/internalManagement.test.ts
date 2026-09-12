import { describe, expect, it } from 'vitest';
import { acceptanceEvidence, authorizeInternalManagement, managementErrorStatus, parseAcceptRisk, parseEnvelope, parseTagIso, requestSha256 } from '../src/lib/internalManagement';

const tenant = '11111111-1111-4111-8111-111111111111';
const actor = '22222222-2222-4222-8222-222222222222';
const requester = '33333333-3333-4333-8333-333333333333';
const policyVersion = '66666666-6666-4666-8666-666666666666';
const context = { org_id: tenant, actor_id: actor, requester_id: requester, role: 'ciso', operation_id: 'a'.repeat(16), approval_id: null, policy_version_id: null, policy_version_sha256: null };

describe('internal management contracts', () => {
  it('accepts only the exact input/context envelope and rejects model-supplied identity', () => {
    const envelope = parseEnvelope({ input: { risk_id: '44444444-4444-4444-8444-444444444444' }, context });
    expect(parseTagIso(envelope.input).riskId).toBe('44444444-4444-4444-8444-444444444444');
    expect(() => parseEnvelope({ input: { risk_id: 'x' }, context: { ...context, extra: 'no' } })).toThrow('MANAGEMENT_ENVELOPE_INVALID');
    expect(() => parseEnvelope({ input: envelope.input, context: { ...context, requester_id: 'x' } })).toThrow('MANAGEMENT_ENVELOPE_INVALID');
    expect(() => parseTagIso({ risk_id: envelope.input.risk_id, actor_id: actor })).toThrow('MANAGEMENT_INPUT_INVALID');
  });
  it('enforces bounded accepted-risk input and stable idempotency digest', () => {
    const input = parseAcceptRisk({ risk_id: '33333333-3333-4333-8333-333333333333', evaluation_snapshot_id: '44444444-4444-4444-8444-444444444444', evaluation_snapshot_sha256: 'a'.repeat(64), inherent_snapshot_id: '55555555-5555-4555-8555-555555555555', inherent_snapshot_sha256: 'b'.repeat(64), reason: 'accepted by CISO', expires_at: '2027-09-07T18:00:00+09:00' });
    expect(input.evaluationSnapshotSha256).toBe('a'.repeat(64));
    const legacyInput = parseAcceptRisk({ risk_id: '33333333-3333-4333-8333-333333333333', evaluation_snapshot_id: '44444444-4444-4444-8444-444444444444', evaluation_snapshot_sha256: 'a'.repeat(64), inherent_snapshot_id: '55555555-5555-4555-8555-555555555555', inherent_snapshot_sha256: 'b'.repeat(64), reason: 'accepted by CISO' });
    expect(legacyInput.expiresAt).toBeNull();
    expect(() => parseAcceptRisk({ ...input, residual_level: 4 })).toThrow('MANAGEMENT_INPUT_INVALID');
    expect(() => parseAcceptRisk({ ...input, expires_at: 'invalid' })).toThrow('MANAGEMENT_INPUT_INVALID');
    const envelope = parseEnvelope({ input: { risk_id: input.riskId, evaluation_snapshot_id: input.evaluationSnapshotId, evaluation_snapshot_sha256: input.evaluationSnapshotSha256, inherent_snapshot_id: input.inherentSnapshotId, inherent_snapshot_sha256: input.inherentSnapshotSha256, reason: input.reason, expires_at: input.expiresAt }, context });
    expect(requestSha256('accept_risk', envelope)).toBe(requestSha256('accept_risk', envelope));
    expect(requestSha256('accept_risk', envelope)).not.toBe(requestSha256('accept_risk', { ...envelope, context: { ...envelope.context, requester_id: actor } }));
  });
  it('requires unambiguous acceptance approval and policy evidence', () => {
    expect(() => acceptanceEvidence(context)).toThrow('MANAGEMENT_APPROVAL_INVALID');
    const approved = parseEnvelope({ input: {}, context: {
      ...context,
      approval_id: '77777777-7777-4777-8777-777777777777',
      policy_version_id: policyVersion,
      policy_version_sha256: 'c'.repeat(64),
    } });
    expect(acceptanceEvidence(approved.context)).toEqual({
      approvalId: '77777777-7777-4777-8777-777777777777',
      policyVersionId: policyVersion,
      policyVersionSha256: 'c'.repeat(64),
    });
    expect(() => parseEnvelope({ input: {}, context: { ...context, policy_version_id: 1 } })).toThrow('MANAGEMENT_ENVELOPE_INVALID');
  });
  it('retains the v1 legacy context for tag-iso callers', () => {
    const legacy = parseEnvelope({ input: { risk_id: tenant }, context: {
      org_id: tenant, actor_id: actor, requester_id: requester, role: 'secretariat',
      operation_id: 'b'.repeat(16), approval_id: null, policy_version: 1,
    } });
    expect(legacy.context.policy_version).toBe(1);
    expect(legacy.context.policy_version_id).toBeNull();
    expect(() => acceptanceEvidence(legacy.context)).toThrow('MANAGEMENT_APPROVAL_INVALID');
  });
  it('maps preserved database domain errors to API statuses', () => {
    expect(managementErrorStatus('IDEMPOTENCY_CONFLICT')).toBe(409);
    expect(managementErrorStatus('RISK_NOT_FOUND')).toBe(404);
    expect(managementErrorStatus('MANAGEMENT_SERVICE_FORBIDDEN')).toBe(403);
    expect(managementErrorStatus('MANAGEMENT_REQUESTER_FORBIDDEN')).toBe(403);
    expect(managementErrorStatus('MANAGEMENT_SNAPSHOT_STALE')).toBe(400);
  });
  it('requires the configured S2S secret and fixed server identity', () => {
    process.env.ISMS_MANAGEMENT_S2S_TOKEN = 'x'.repeat(32);
    process.env.ISMS_MANAGEMENT_TENANT_ID = tenant;
    process.env.ISMS_MANAGEMENT_ACTOR_ID = actor;
    expect(authorizeInternalManagement(new Request('http://test', { headers: { authorization: `Bearer ${'x'.repeat(32)}` } }), context)).toBe(true);
    expect(authorizeInternalManagement(new Request('http://test', { headers: { authorization: `Bearer ${'x'.repeat(32)}` } }), { ...context, actor_id: '44444444-4444-4444-8444-444444444444' })).toBe(false);
    expect(authorizeInternalManagement(new Request('http://test', { headers: { authorization: `Bearer ${'x'.repeat(32)}` } }), { ...context, requester_id: actor })).toBe(true);
  });
});
