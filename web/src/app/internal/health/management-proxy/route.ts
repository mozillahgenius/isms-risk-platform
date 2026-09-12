import { NextResponse } from 'next/server';
import { isProxySecretValid } from '@/lib/deviceControlAuth';
import { withTenantWrite } from '@/lib/tenant';

export async function POST(request: Request) {
  const supplied = request.headers.get('authorization')?.replace(/^Bearer /, '') ?? '';
  if (!isProxySecretValid(supplied, process.env.ISMS_DEVICE_CONTROL_PROXY_SECRET)) {
    return NextResponse.json({ error: 'MANAGEMENT_FORBIDDEN' }, { status: 401 });
  }
  const result = await withTenantWrite(async (sql) => {
    const rows = await sql<{ health: Record<string, unknown> }[]>`
      SELECT app.management_proxy_healthcheck() AS health`;
    if (!rows[0]?.health) throw new Error('MANAGEMENT_SMOKE_FAILED');
    return rows[0].health;
  });
  if (!result.ok) return NextResponse.json({ error: 'MANAGEMENT_SMOKE_FAILED' }, { status: 503 });
  return NextResponse.json(result.data, { status: 200 });
}
