import 'server-only';

import { createHmac, createPrivateKey, createPublicKey, sign } from 'node:crypto';

function ingestSecret(): Buffer {
  const value = process.env.ISMS_AGENT_INGEST_SECRET || '';
  if (!/^[0-9a-fA-F]{64}$/.test(value)) {
    throw new Error('ISMS_AGENT_INGEST_SECRET is not configured');
  }
  return Buffer.from(value, 'hex');
}

export function postureIngestMac(
  deviceId: string,
  rawHash: Buffer,
  signature: Buffer,
): Buffer {
  return createHmac('sha256', ingestSecret())
    .update(Buffer.concat([rawHash, signature, Buffer.from(deviceId, 'utf8')]))
    .digest();
}

export function signAgentDefinition(canonicalDefinition: Buffer): {
  signature: Buffer;
  publicKey: Buffer;
} {
  const value = process.env.ISMS_AGENT_DEFINITION_PRIVATE_KEY_B64 || '';
  if (!value) throw new Error('ISMS_AGENT_DEFINITION_PRIVATE_KEY_B64 is not configured');
  const privateKey = createPrivateKey({
    key: Buffer.from(value, 'base64'),
    format: 'der',
    type: 'pkcs8',
  });
  const publicDer = createPublicKey(privateKey).export({ format: 'der', type: 'spki' });
  const publicKey = Buffer.from(publicDer).subarray(-32);
  return { signature: sign(null, canonicalDefinition, privateKey), publicKey };
}
