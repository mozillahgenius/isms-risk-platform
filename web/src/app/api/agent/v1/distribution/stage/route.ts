import { NextResponse } from 'next/server';

import { markAgentInstallation } from '@/lib/agentDistributionServer';

export const dynamic = 'force-dynamic';

export async function POST(request: Request) {
  try {
    const body = await request.json() as Record<string, unknown>;
    const token = typeof body.token === 'string' ? body.token.trim() : '';
    const stage = typeof body.stage === 'string' ? body.stage.trim() : '';
    const hardwareId = typeof body.hardware_id === 'string' ? body.hardware_id.trim() : undefined;
    const deviceId = typeof body.device_id === 'string' ? body.device_id.trim() : undefined;
    const failureCode = typeof body.failure_code === 'string' ? body.failure_code.trim() : undefined;
    if (!token || !stage) return NextResponse.json({ error: 'invalid_request' }, { status: 400 });
    const result = await markAgentInstallation(token, stage, hardwareId, deviceId, failureCode);
    if (result.ok !== true) return NextResponse.json({ error: result.reason ?? 'rejected' }, { status: 400, headers: { 'Cache-Control': 'no-store' } });
    return NextResponse.json(result, { headers: { 'Cache-Control': 'no-store' } });
  } catch {
    return NextResponse.json({ error: 'invalid_request' }, { status: 400 });
  }
}
