'use server';

import { randomBytes } from 'node:crypto';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';

import { withTenantActor, withTenantWrite } from '@/lib/tenant';
import {
  hashManagementUserCode,
  managementLoginEnabled,
  normalizeManagementUserCode,
} from '@/lib/managementEnrollment';

export type EnrollmentActionState = {
  ok: boolean;
  token?: string;
  error?: string;
};

export async function issueManagementEnrollmentCode(
  _previousState?: EnrollmentActionState,
  _formData?: FormData,
): Promise<EnrollmentActionState> {
  const token = randomBytes(48).toString('base64url');
  const result = await withTenantWrite(async (sql) => {
    const rows = await sql<{ id: string }[]>`
      SELECT app.issue_device_enrollment_token_for_management(${token}, interval '24 hours') AS id
    `;
    if (rows.length !== 1) throw new Error('management enrollment token was not issued');
    return rows[0]!.id;
  });
  if (!result.ok) return { ok: false, error: result.detail ?? result.reason };
  return { ok: true, token };
}

const APPROVAL_COOKIE = 'management_device_approval';
const APPROVAL_PATH = '/operations/device-control/approve';

function approvalCookieOptions(maxAge: number) {
  return {
    httpOnly: true,
    sameSite: 'strict' as const,
    secure: process.env.NODE_ENV === 'production',
    path: APPROVAL_PATH,
    maxAge,
  };
}

function approvalBack(error: string): never {
  redirect(`${APPROVAL_PATH}?error=${encodeURIComponent(error)}`);
}

export async function enterManagementLoginCode(formData: FormData): Promise<void> {
  if (!managementLoginEnabled()) approvalBack('closed');
  const code = normalizeManagementUserCode(formData.get('user_code'));
  if (!code) approvalBack('format');
  const result = await withTenantActor(async (sql) => {
    const rows = await sql<{ result: Record<string, unknown> }[]>`
      SELECT app.lookup_device_login_enrollment(${hashManagementUserCode(code)}) AS result
    `;
    return rows[0]?.result ?? { ok: false, reason: 'invalid' };
  });
  if (!result.ok) approvalBack('failed');
  if (result.data.ok !== true) approvalBack(String(result.data.reason ?? 'invalid'));
  (await cookies()).set(APPROVAL_COOKIE, code, approvalCookieOptions(600));
  redirect(APPROVAL_PATH);
}

export async function decideManagementLoginRequest(formData: FormData): Promise<void> {
  if (!managementLoginEnabled()) approvalBack('closed');
  const requestId = String(formData.get('request_id') ?? '').trim();
  const decision = String(formData.get('decision') ?? '');
  if (!/^[0-9a-f-]{36}$/i.test(requestId) || (decision !== 'approve' && decision !== 'deny')) approvalBack('format');
  const store = await cookies();
  const code = normalizeManagementUserCode(store.get(APPROVAL_COOKIE)?.value);
  if (!code) approvalBack('format');
  const result = await withTenantWrite(async (sql) => {
    const rows = await sql<{ result: Record<string, unknown> }[]>`
      SELECT app.decide_device_login_enrollment(
        ${requestId}::uuid, ${hashManagementUserCode(code)}, ${decision === 'approve'}
      ) AS result
    `;
    return rows[0]?.result ?? { ok: false, reason: 'failed' };
  });
  if (!result.ok) approvalBack(result.detail ?? result.reason);
  if (result.data.ok !== true) approvalBack(String(result.data.reason ?? 'failed'));
  store.set(APPROVAL_COOKIE, '', approvalCookieOptions(0));
  revalidatePath('/operations/device-control');
  revalidatePath(APPROVAL_PATH);
  redirect(`${APPROVAL_PATH}?done=${decision === 'approve' ? 'approved' : 'denied'}`);
}
