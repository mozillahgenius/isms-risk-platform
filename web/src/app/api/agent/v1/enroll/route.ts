import { NextResponse } from 'next/server';

import { getAgentDb } from '@/lib/agent-db';

type EnrollmentBody = {
  token?: unknown;
  external_id?: unknown;
  hostname?: unknown;
  model?: unknown;
  os_family?: unknown;
  off_premise?: unknown;
  public_key?: unknown;
};

function stringField(body: EnrollmentBody, key: keyof EnrollmentBody): string {
  const value = body[key];
  if (typeof value !== 'string' || value.trim() === '') throw new Error(`${key} is required`);
  return value;
}

export async function POST(request: Request) {
  try {
    const body = (await request.json()) as EnrollmentBody;
    const token = stringField(body, 'token');
    const externalId = stringField(body, 'external_id');
    const hostname = stringField(body, 'hostname');
    const model = stringField(body, 'model');
    const osFamily = stringField(body, 'os_family');
    if (typeof body.off_premise !== 'boolean') throw new Error('off_premise must be boolean');
    const publicKeyText = stringField(body, 'public_key');
    const publicKey = Buffer.from(publicKeyText, 'base64');
    if (publicKey.length !== 32 || publicKey.toString('base64') !== publicKeyText) {
      throw new Error('public_key is invalid');
    }

    const rows = await getAgentDb()`
      SELECT device_id, tenant_id
        FROM app.enroll_device(
          ${token}, ${externalId}, ${hostname}, ${model}, ${osFamily},
          ${body.off_premise}, ${publicKey}
        )
    `;
    if (rows.length !== 1) return NextResponse.json({ error: 'enrollment rejected' }, { status: 401 });
    return NextResponse.json({ device_id: rows[0].device_id });
  } catch (error) {
    console.error('[agent/enroll] rejected', error instanceof Error ? error.message : error);
    return NextResponse.json({ error: 'enrollment rejected' }, { status: 400 });
  }
}
