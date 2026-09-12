import { NextResponse } from 'next/server';
import { authorizeInternalManagement, internalSessionToken, managementErrorStatus, parseEnvelope, parseTagIso, requestSha256 } from '@/lib/internalManagement';
import { withTenantWriteToken } from '@/lib/tenant';

export async function POST(request: Request) {
  try {
    const envelope = parseEnvelope(await request.json());
    if (!authorizeInternalManagement(request, envelope.context)) return NextResponse.json({ error: 'MANAGEMENT_FORBIDDEN' }, { status: 401 });
    const input = parseTagIso(envelope.input); const hash = requestSha256('tag_iso', envelope);
    const result = await withTenantWriteToken(internalSessionToken(), async (sql) => {
      const identity = await sql<{ tenant: string; actor: string }[]>`SELECT app.current_tenant()::text AS tenant, app.current_session_user()::text AS actor`;
      if (identity[0]?.tenant !== envelope.context.org_id || identity[0]?.actor !== envelope.context.actor_id) throw new Error('MANAGEMENT_IDENTITY_MISMATCH');
      const recorded = await sql<{ receipt: Record<string, unknown> }[]>`
        SELECT app.internal_tag_iso(
          ${envelope.context.operation_id},${hash},${envelope.context.requester_id}::uuid,
          ${envelope.context.role},${input.riskId}::uuid
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
