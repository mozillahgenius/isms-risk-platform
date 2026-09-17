import { NextResponse } from 'next/server';

import { lookupAgentInstallation } from '@/lib/agentDistributionServer';

export const dynamic = 'force-dynamic';

export async function GET(request: Request) {
  const token = new URL(request.url).searchParams.get('token')?.trim() ?? '';
  const manifest = token ? await lookupAgentInstallation(token) : null;
  if (!manifest) return NextResponse.json({ error: 'invalid_or_expired' }, { status: 404, headers: { 'Cache-Control': 'no-store' } });
  return NextResponse.json(manifest, { headers: { 'Cache-Control': 'no-store' } });
}
