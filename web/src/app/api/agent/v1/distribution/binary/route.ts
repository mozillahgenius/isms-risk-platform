import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { NextResponse } from 'next/server';

import {
  artifactDirectory,
  binaryArtifactPath,
  lookupAgentInstallation,
  markAgentInstallation,
} from '@/lib/agentDistributionServer';

export const dynamic = 'force-dynamic';

export async function GET(request: Request) {
  const params = new URL(request.url).searchParams;
  const token = params.get('token')?.trim() ?? '';
  const platform = params.get('platform')?.trim() ?? '';
  const manifest = token ? await lookupAgentInstallation(token) : null;
  const filename = binaryArtifactPath(platform);
  if (!manifest || !filename || !platform.startsWith(manifest.os_family + '-')) {
    return NextResponse.json({ error: 'invalid_or_expired' }, { status: 404, headers: { 'Cache-Control': 'no-store' } });
  }
  try {
    const content = await readFile(join(artifactDirectory(), filename));
    await markAgentInstallation(token, 'downloaded');
    return new Response(content, {
      headers: {
        'Content-Type': 'application/octet-stream',
        'Content-Disposition': `attachment; filename="${filename}"`,
        'Cache-Control': 'no-store',
      },
    });
  } catch {
    return NextResponse.json({ error: 'artifact_unavailable' }, { status: 503, headers: { 'Cache-Control': 'no-store' } });
  }
}
