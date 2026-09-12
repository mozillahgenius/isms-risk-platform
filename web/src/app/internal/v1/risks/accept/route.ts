import { NextResponse } from 'next/server';
import { acceptanceEvidence, authorizeInternalManagement, internalSessionToken, managementErrorStatus, parseAcceptRisk, parseEnvelope, requestSha256 } from '@/lib/internalManagement';
import { withTenantWriteToken } from '@/lib/tenant';

export async function POST(request: Request) {
  try {
    const envelope = parseEnvelope(await request.json());
    if (!authorizeInternalManagement(request, envelope.context)) return NextResponse.json({ error: 'MANAGEMENT_FORBIDDEN' }, { status: 401 });
    const input = parseAcceptRisk(envelope.input);
    if (!input.expiresAt || !envelope.context.approval_id
      || !envelope.context.policy_version_id || !envelope.context.policy_version_sha256) {
      return NextResponse.json(
        { error: 'MANAGEMENT_V2_REQUIRED', upgrade: '/internal/v2/risks/accept' },
        { status: 426, headers: { 'Deprecation': 'true', 'Link': '</internal/v2/risks/accept>; rel="successor-version"' } },
      );
    }
    const evidence = acceptanceEvidence(envelope.context);
    const hash = requestSha256('accept_risk', envelope);
    const result = await withTenantWriteToken(internalSessionToken(), async (sql) => {
      const identity = await sql<{ tenant: string; actor: string }[]>`SELECT app.current_tenant()::text AS tenant, app.current_session_user()::text AS actor`;
      if (identity[0]?.tenant !== envelope.context.org_id || identity[0]?.actor !== envelope.context.actor_id) throw new Error('MANAGEMENT_IDENTITY_MISMATCH');
      const recorded = await sql<{ receipt: Record<string, unknown> }[]>`
        SELECT app.internal_accept_risk(
          ${envelope.context.operation_id},${hash},${envelope.context.requester_id}::uuid,
          ${envelope.context.role},${evidence.approvalId}::uuid,
          ${evidence.policyVersionId}::uuid,${evidence.policyVersionSha256},${input.riskId}::uuid,
          ${input.evaluationSnapshotId}::uuid,${input.evaluationSnapshotSha256},
          ${input.inherentSnapshotId}::uuid,${input.inherentSnapshotSha256},${input.reason},${input.expiresAt}::timestamptz
        ) AS receipt`;
      return recorded[0]!.receipt;
    });
    if (!result.ok) {
      if (result.reason === 'domain' && result.detail) {
        return NextResponse.json({ error: result.detail }, { status: managementErrorStatus(result.detail) });
      }
      return NextResponse.json({ error: 'MANAGEMENT_UNAVAILABLE' }, { status: 503 });
    }
    return NextResponse.json(result.data, { status: 200 });
  } catch (error) {
    const code = error instanceof Error ? error.message : 'MANAGEMENT_REJECTED';
    return NextResponse.json({ error: code }, { status: managementErrorStatus(code) });
  }
}
