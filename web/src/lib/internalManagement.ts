import { createHash, timingSafeEqual } from 'node:crypto';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const OPERATION = /^[a-f0-9]{12,64}$/;

/** `actor_id` is the pinned service principal; `requester_id` records who initiated the operation. */
export type InternalContext = Readonly<{
  org_id: string; actor_id: string; requester_id: string; role: string;
  operation_id: string; approval_id: string | null;
  policy_version?: number | null;
  policy_version_id: string | null; policy_version_sha256: string | null;
}>;
export type InternalEnvelope = Readonly<{ input: Record<string, unknown>; context: InternalContext }>;

function equalSecret(expected: string, supplied: string): boolean {
  return expected.length >= 32 && supplied.length === expected.length && timingSafeEqual(Buffer.from(expected), Buffer.from(supplied));
}

/** Fixed S2S secret and fixed service identity are both required; no caller can select a tenant or actor. */
export function authorizeInternalManagement(request: Request, context: InternalContext): boolean {
  const supplied = request.headers.get('authorization')?.replace(/^Bearer /, '') ?? '';
  const expected = process.env.ISMS_MANAGEMENT_S2S_TOKEN ?? '';
  return equalSecret(expected, supplied)
    && context.org_id === process.env.ISMS_MANAGEMENT_TENANT_ID
    && context.actor_id === process.env.ISMS_MANAGEMENT_ACTOR_ID;
}

export function internalSessionToken(): string | null {
  const token = process.env.ISMS_MANAGEMENT_SESSION_TOKEN;
  return token && token.length >= 32 ? token : null;
}

export function parseEnvelope(value: unknown): InternalEnvelope {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('MANAGEMENT_ENVELOPE_INVALID');
  const row = value as Record<string, unknown>;
  if (Object.keys(row).length !== 2 || !row.input || typeof row.input !== 'object' || Array.isArray(row.input)
    || !row.context || typeof row.context !== 'object' || Array.isArray(row.context)) throw new Error('MANAGEMENT_ENVELOPE_INVALID');
  const context = row.context as Record<string, unknown>;
  const legacyKeys = ['org_id', 'actor_id', 'requester_id', 'role', 'operation_id', 'approval_id', 'policy_version'];
  const evidenceKeys = ['org_id', 'actor_id', 'requester_id', 'role', 'operation_id', 'approval_id', 'policy_version_id', 'policy_version_sha256'];
  const hasLegacyContext = Object.keys(context).length === legacyKeys.length && legacyKeys.every(key => key in context);
  const hasEvidenceContext = Object.keys(context).length === evidenceKeys.length && evidenceKeys.every(key => key in context);
  const evidenceFieldsInvalid = hasEvidenceContext
    && (!(context.policy_version_id === null || UUID.test(String(context.policy_version_id)))
      || !(context.policy_version_sha256 === null || /^[a-f0-9]{64}$/.test(String(context.policy_version_sha256))));
  if ((!hasLegacyContext && !hasEvidenceContext)
    || !UUID.test(String(context.org_id)) || !UUID.test(String(context.actor_id)) || !UUID.test(String(context.requester_id)) || typeof context.role !== 'string' || !context.role
    || !OPERATION.test(String(context.operation_id))
    || !(context.approval_id === null || UUID.test(String(context.approval_id)))
    || (hasLegacyContext && (!Number.isInteger(context.policy_version) || Number(context.policy_version) < 1))
    || evidenceFieldsInvalid) throw new Error('MANAGEMENT_ENVELOPE_INVALID');
  return Object.freeze({ input: Object.freeze({ ...(row.input as Record<string, unknown>) }), context: Object.freeze({
    org_id: String(context.org_id), actor_id: String(context.actor_id), requester_id: String(context.requester_id), role: context.role,
    operation_id: String(context.operation_id), approval_id: context.approval_id === null ? null : String(context.approval_id),
    policy_version: hasLegacyContext ? Number(context.policy_version) : null,
    policy_version_id: hasEvidenceContext && context.policy_version_id !== null ? String(context.policy_version_id) : null,
    policy_version_sha256: hasEvidenceContext && context.policy_version_sha256 !== null ? String(context.policy_version_sha256) : null,
  }) });
}

export function acceptanceEvidence(context: InternalContext): {
  approvalId: string; policyVersionId: string; policyVersionSha256: string;
} {
  if (!context.approval_id || !context.policy_version_id || !context.policy_version_sha256) {
    throw new Error('MANAGEMENT_APPROVAL_INVALID');
  }
  return {
    approvalId: context.approval_id,
    policyVersionId: context.policy_version_id,
    policyVersionSha256: context.policy_version_sha256,
  };
}

export function managementErrorStatus(code: string): number {
  if (code === 'IDEMPOTENCY_CONFLICT') return 409;
  if (code === 'RISK_NOT_FOUND') return 404;
  if (code === 'MANAGEMENT_SERVICE_FORBIDDEN' || code === 'MANAGEMENT_REQUESTER_FORBIDDEN'
    || code === 'MANAGEMENT_IDENTITY_MISMATCH') return 403;
  return 400;
}

export function parseTagIso(input: Record<string, unknown>): { riskId: string } {
  if (Object.keys(input).length !== 1 || !UUID.test(String(input.risk_id))) throw new Error('MANAGEMENT_INPUT_INVALID');
  return { riskId: String(input.risk_id) };
}

export function parseAcceptRisk(input: Record<string, unknown>): { riskId: string; evaluationSnapshotId: string; evaluationSnapshotSha256: string; inherentSnapshotId: string; inherentSnapshotSha256: string; reason: string; expiresAt: string | null } {
  const legacy = ['risk_id', 'evaluation_snapshot_id', 'evaluation_snapshot_sha256', 'inherent_snapshot_id', 'inherent_snapshot_sha256', 'reason'];
  const expected = 'expires_at' in input ? [...legacy, 'expires_at'] : legacy;
  if (Object.keys(input).length !== expected.length || expected.some(key => !(key in input)) || !UUID.test(String(input.risk_id))
    || !UUID.test(String(input.evaluation_snapshot_id)) || !/^[a-f0-9]{64}$/.test(String(input.evaluation_snapshot_sha256))
    || !UUID.test(String(input.inherent_snapshot_id)) || !/^[a-f0-9]{64}$/.test(String(input.inherent_snapshot_sha256))
    || typeof input.reason !== 'string' || !input.reason.trim() || input.reason.length > 4000
    || ('expires_at' in input && (typeof input.expires_at !== 'string' || !input.expires_at.trim()
      || !Number.isFinite(Date.parse(input.expires_at))))) throw new Error('MANAGEMENT_INPUT_INVALID');
  const expiresAt = typeof input.expires_at === 'string' ? input.expires_at.trim() : null;
  return { riskId: String(input.risk_id), evaluationSnapshotId: String(input.evaluation_snapshot_id), evaluationSnapshotSha256: String(input.evaluation_snapshot_sha256), inherentSnapshotId: String(input.inherent_snapshot_id), inherentSnapshotSha256: String(input.inherent_snapshot_sha256), reason: input.reason.trim(), expiresAt };
}

export function requestSha256(action: string, envelope: InternalEnvelope): string {
  return createHash('sha256').update(JSON.stringify({ action, input: envelope.input, context: envelope.context })).digest('hex');
}
