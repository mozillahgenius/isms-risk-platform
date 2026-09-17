'use server';

import { revalidatePath } from 'next/cache';

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
