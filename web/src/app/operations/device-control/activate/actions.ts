'use server';

import { redirect } from 'next/navigation';

import { hashDeliveryToken } from '@/lib/agentDistribution';
import { withTenantActor } from '@/lib/tenant';

export async function activateManagementEnrollmentForTarget(formData: FormData): Promise<void> {
  const token = String(formData.get('token') ?? '').trim();
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(token)) redirect('/operations/device-control?error=invalid_distribution');
  const result = await withTenantActor(async (sql) => {
    const rows = await sql<{ result: Record<string, unknown> }[]>`
      SELECT app.activate_device_login_enrollment_for_target(${hashDeliveryToken(token)}) AS result
    `;
    return rows[0]?.result ?? { ok: false, reason: 'failed' };
  });
  if (!result.ok || result.data.ok !== true) {
    const reason = result.ok ? String(result.data.reason ?? 'failed') : result.detail ?? result.reason;
    if (!result.ok) {
      console.error('[agent-activation] tenant actor context unavailable', {
        reason: result.reason,
        detail: result.detail ?? null,
      });
    }
    redirect(`/operations/device-control/activate?token=${encodeURIComponent(token)}&error=${encodeURIComponent(reason)}`);
  }
  redirect(`/operations/device-control/activate?token=${encodeURIComponent(token)}&done=approved`);
}
