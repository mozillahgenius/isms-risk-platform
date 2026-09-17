import { NextResponse } from 'next/server';

import { getAgentDb } from '@/lib/agent-db';
import { canonicalJson } from '@/lib/canonical-json';
import { signAgentDefinition } from '@/lib/agent-crypto';

// 端末の OS ごとに定義を返す。指定が無ければ macOS（既存の agent は platform を送らない）。
const platforms = new Set(['macos', 'windows']);

export async function GET(request: Request) {
  const platform = new URL(request.url).searchParams.get('platform') ?? 'macos';
  if (!platforms.has(platform)) return NextResponse.json({ error: 'platform is unsupported' }, { status: 400 });
  try {
    const rows = await getAgentDb()`
      SELECT version, platform, definition, encode(definition_hash, 'hex') AS definition_hash
        FROM catalog.agent_definitions
       WHERE platform = ${platform} AND active
       ORDER BY version DESC
       LIMIT 1
    `;
    if (rows.length !== 1) return NextResponse.json({ error: 'definition unavailable' }, { status: 404 });
    const definition = rows[0].definition;
    const signed = signAgentDefinition(canonicalJson(definition));
    return NextResponse.json({
      ...rows[0],
      signature: signed.signature.toString('base64'),
      signing_public_key: signed.publicKey.toString('base64'),
    });
  } catch (error) {
    console.error('[agent/definition] unavailable', error instanceof Error ? error.message : error);
    return NextResponse.json({ error: 'definition unavailable' }, { status: 503 });
  }
}
