import { timingSafeEqual } from 'node:crypto';
import { NextResponse } from 'next/server';

import { withTenantWrite } from '@/lib/tenant';

type ReceiptRequest = { check_keys?: unknown; requester?: unknown };

function isAuthorized(request: Request): boolean {
  const expected = process.env.ISMS_VERIFICATION_RECEIPT_TOKEN || '';
  const supplied = request.headers.get('authorization')?.replace(/^Bearer /, '') || '';
  if (expected.length < 32 || supplied.length !== expected.length) return false;
  return timingSafeEqual(Buffer.from(supplied), Buffer.from(expected));
}

function parseRequest(body: ReceiptRequest): { checkKeys: string[]; requester: string } {
  if (!Array.isArray(body.check_keys) || body.check_keys.length === 0
      || body.check_keys.some((key) => typeof key !== 'string' || key.trim() === '')) {
    throw new Error('check_keys is required');
  }
  if (typeof body.requester !== 'string' || body.requester.trim() === '') {
    throw new Error('requester is required');
  }
  return { checkKeys: body.check_keys.map((key) => key.trim()), requester: body.requester.trim() };
}

// POST だけを export する。受付済みの内容を返す GET や変更・削除の入口は作らない。
export async function POST(request: Request) {
  if (!isAuthorized(request)) return NextResponse.json({ error: 'receipt rejected' }, { status: 401 });
  try {
    const { checkKeys, requester } = parseRequest((await request.json()) as ReceiptRequest);
    const result = await withTenantWrite(async (sql) => sql`
      SELECT app.accept_verification_receipt(${checkKeys}::text[], ${requester}) AS receipt_id
    `);
    if (!result.ok) return NextResponse.json({ error: 'receipt rejected' }, { status: 400 });
    return NextResponse.json({ receipt_id: result.data[0].receipt_id }, { status: 201 });
  } catch {
    return NextResponse.json({ error: 'receipt rejected' }, { status: 400 });
  }
}
