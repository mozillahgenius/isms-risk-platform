'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';

import { withTenantWrite } from '@/lib/tenant';
import { queueMail } from '@/lib/mailOutbox';
import {
  AGENT_AUTH_METHODS,
  AGENT_INSTALLER_VERSION,
  AGENT_OS_FAMILIES,
  agentDistributionMailBody,
  createDeliveryToken,
  installUrl,
  type AgentAuthMethod,
  type AgentOsFamily,
} from '@/lib/agentDistribution';
import { managementTargetActivationUri } from '@/lib/managementEnrollment';

export type DistributionActionState = {
  ok?: boolean;
  deliveryStatus?: 'queued';
  authMethod?: AgentAuthMethod;
  installUrl?: string;
  token?: string;
  error?: string;
};

export async function issueAgentDistribution(
  _previous: DistributionActionState,
  formData: FormData,
): Promise<DistributionActionState> {
  const targetEmail = String(formData.get('target_email') ?? '').trim().toLowerCase();
  const targetName = String(formData.get('target_name') ?? '').trim();
  const osFamily = String(formData.get('os_family') ?? '').trim() as AgentOsFamily;
  const authMethod = String(formData.get('auth_method') ?? '').trim() as AgentAuthMethod;
  if (!/^[^\s\u0000-\u001f@]+@[^\s\u0000-\u001f@]+$/.test(targetEmail)) return { error: '送付先メールアドレスが不正です' };
  if (!(AGENT_OS_FAMILIES as readonly string[]).includes(osFamily)) return { error: 'OSが不正です' };
  if (!(AGENT_AUTH_METHODS as readonly string[]).includes(authMethod)) return { error: '認証方式が不正です' };
  const token = createDeliveryToken();
  const url = installUrl(token);
  if (!url) return { error: 'ISMS_WEB_BASE_URLが設定されていないため送付できません' };

  const result = await withTenantWrite(async (sql) => {
    const rows = await sql<{ result: Record<string, unknown> }[]>`
      SELECT app.issue_agent_installation(
        ${token}, ${targetEmail}, ${targetName}, ${osFamily}, ${authMethod},
        ${AGENT_INSTALLER_VERSION}, interval '24 hours'
      ) AS result
    `;
    const issued = rows[0]?.result;
    if (!issued || issued.ok !== true || typeof issued.id !== 'string' || typeof issued.expires_at !== 'string') {
      return { ok: false, reason: String(issued?.reason ?? '発行できませんでした') };
    }
    await queueMail(sql, {
      purpose: 'agent_distribution',
      toEmail: targetEmail,
      toName: targetName,
      subject: '端末エージェントの導入リンク',
      bodyText: agentDistributionMailBody({
        targetName,
        installUrl: url,
        activationUrl: authMethod === 'gws' ? managementTargetActivationUri(token) ?? undefined : undefined,
        osFamily,
        authMethod,
        expiresAt: issued.expires_at,
      }),
      relatedType: 'agent_installation',
      relatedId: issued.id,
    });
    return { ok: true };
  });
  if (!result.ok) return { error: result.detail ?? result.reason };
  revalidatePath('/operations/device-control');
  return { ok: true, deliveryStatus: 'queued', authMethod, installUrl: url, token };
}

/** 招待の取り消し（2026-09-25）。複数送った招待の古い分などを失効させる。
 *  発行と同じ入口（withTenantWrite＝在籍する本人の書き込み）で、組織は DB 側が文脈から決める。
 *  有効（登録済み）の端末は取り消さない（DB が already_active で断る）。 */
export async function revokeAgentInstallation(formData: FormData): Promise<void> {
  const id = String(formData.get('installation_id') ?? '').trim();
  const mode = formData.get('mode') === 'isms' ? 'isms' : 'risk';
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    redirect(`/operations/device-control?error=bad_request&mode=${mode}`);
  }
  const result = await withTenantWrite(async (sql) => {
    const rows = await sql<{ result: { ok?: boolean; reason?: string } }[]>`
      SELECT app.revoke_agent_installation(${id}::uuid) AS result
    `;
    return rows[0]?.result ?? { ok: false, reason: 'error' };
  });
  if (!result.ok) redirect(`/operations/device-control?error=revoke_${result.reason}&mode=${mode}`);
  const data = result.data;
  if (data.ok !== true) redirect(`/operations/device-control?error=revoke_${data.reason ?? 'error'}&mode=${mode}`);
  redirect(`/operations/device-control?revoked=1&mode=${mode}`);
}

/** 登録済みの端末を外す（2026-09-25。0086 app.detach_device）。
 *  外した端末の報告は受けなくなり、再び使うには招待からの導入し直しが要る（画面で確認を出してから送る）。 */
export async function detachDevice(formData: FormData): Promise<void> {
  const id = String(formData.get('device_id') ?? '').trim();
  const mode = formData.get('mode') === 'isms' ? 'isms' : 'risk';
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    redirect(`/operations/device-control?error=bad_request&mode=${mode}`);
  }
  const result = await withTenantWrite(async (sql) => {
    const rows = await sql<{ result: { ok?: boolean; reason?: string } }[]>`
      SELECT app.detach_device(${id}::uuid) AS result
    `;
    return rows[0]?.result ?? { ok: false, reason: 'error' };
  });
  if (!result.ok) redirect(`/operations/device-control?error=detach_${result.reason}&mode=${mode}`);
  if (result.data.ok !== true) redirect(`/operations/device-control?error=detach_${result.data.reason ?? 'error'}&mode=${mode}`);
  redirect(`/operations/device-control?detached=1&mode=${mode}`);
}
