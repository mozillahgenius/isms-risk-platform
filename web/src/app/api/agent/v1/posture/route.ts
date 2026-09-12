import { createHash, createPublicKey, verify } from 'node:crypto';
import { NextResponse } from 'next/server';

import { getAgentDb } from '@/lib/agent-db';
import { canonicalJson } from '@/lib/canonical-json';
import { validateAgentPayload } from '@/lib/agent-payload';
import { postureIngestMac } from '@/lib/agent-crypto';

const ed25519SpkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');

type PostureBody = { payload?: unknown; signature?: unknown };

export async function POST(request: Request) {
  try {
    const body = (await request.json()) as PostureBody;
    const payload = validateAgentPayload(body.payload);
    if (typeof body.signature !== 'string') throw new Error('signature is required');
    const signature = Buffer.from(body.signature, 'base64');
    if (signature.length !== 64 || signature.toString('base64') !== body.signature) {
      throw new Error('signature is invalid');
    }

    const db = getAgentDb();
    const keyRows = await db`
      SELECT tenant_id, public_key
        FROM app.get_device_verification_key(${payload.device_id}::uuid)
    `;
    if (keyRows.length !== 1 || !(keyRows[0].public_key instanceof Uint8Array)) {
      return NextResponse.json({ error: 'posture rejected' }, { status: 401 });
    }
    const publicKeyBytes = Buffer.from(keyRows[0].public_key);
    if (publicKeyBytes.length !== 32) return NextResponse.json({ error: 'posture rejected' }, { status: 401 });

    const canonical = canonicalJson(payload);
    const publicKey = createPublicKey({
      key: Buffer.concat([ed25519SpkiPrefix, publicKeyBytes]),
      format: 'der',
      type: 'spki',
    });
    if (!verify(null, canonical, publicKey, signature)) {
      return NextResponse.json({ error: 'posture rejected' }, { status: 401 });
    }

    const definitionRows = await db`
      SELECT definition_hash
        FROM catalog.agent_definitions
       WHERE platform = 'macos' AND version = ${payload.definition_version} AND active
    `;
    if (definitionRows.length !== 1) return NextResponse.json({ error: 'definition rejected' }, { status: 409 });
    const expectedHash = Buffer.from(definitionRows[0].definition_hash);
    if (!expectedHash.equals(Buffer.from(payload.definition_hash, 'hex'))) {
      return NextResponse.json({ error: 'definition rejected' }, { status: 409 });
    }

    const rawHash = createHash('sha256').update(canonical).digest();
    const ingestMac = postureIngestMac(payload.device_id, rawHash, signature);
    const payloadJson = db.json(payload);
    await db`
      SELECT app.ingest_device_snapshot(
        ${payload.device_id}::uuid,
        ${payload.collected_at}::timestamptz,
        ${payload.agent_version},
        ${payload.definition_version}::int,
        ${Buffer.from(payload.definition_hash, 'hex')},
        ${payloadJson},
        ${signature},
        ${rawHash},
        ${ingestMac}
      )
    `;
    return NextResponse.json({ accepted: true, raw_hash: rawHash.toString('hex') });
  } catch (error) {
    console.error('[agent/posture] rejected', error instanceof Error ? error.message : error);
    return NextResponse.json({ error: 'posture rejected' }, { status: 400 });
  }
}
