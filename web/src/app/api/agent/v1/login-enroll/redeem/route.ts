import {
  hashManagementDeviceCode,
  managementLoginEnabled,
  noStoreManagementResponse,
  parseManagementLoginRedeemBody,
  readManagementJsonObject,
  canonicalManagementRedeemPayload,
  verifyManagementRedeemSignature,
} from '@/lib/managementEnrollment';
import { getAgentDb } from '@/lib/agent-db';
import { lookupAgentInstallation, markAgentInstallation } from '@/lib/agentDistributionServer';

export const dynamic = 'force-dynamic';

function responseFor(result: Record<string, unknown>): Response {
  if (result.ok === true && typeof result.device_id === 'string') {
    return noStoreManagementResponse(200, { device_id: result.device_id, tenant_id: result.tenant_id });
  }
  switch (result.reason) {
    case 'authorization_pending': return noStoreManagementResponse(400, { error: 'authorization_pending' });
    case 'slow_down': return noStoreManagementResponse(400, { error: 'slow_down' });
    case 'denied': return noStoreManagementResponse(400, { error: 'access_denied' });
    case 'expired': return noStoreManagementResponse(400, { error: 'expired_token' });
    case 'already_enrolled': return noStoreManagementResponse(409, { error: 'already_enrolled' });
    case 'ENROLLMENT_INCONSISTENT': return noStoreManagementResponse(409, { error: 'ENROLLMENT_INCONSISTENT' });
    default: return noStoreManagementResponse(401, { error: 'invalid_grant' });
  }
}

export async function POST(request: Request) {
  if (!managementLoginEnabled()) return noStoreManagementResponse(403, { error: 'closed' });
  const body = await readManagementJsonObject(request);
  const input = body ? parseManagementLoginRedeemBody(body) : null;
  if (!input) return noStoreManagementResponse(400, { error: 'invalid_request' });
  const db = getAgentDb();
  // 配布リンク由来のGWS登録は、端末を作る前に配布台帳を検証する。
  // 不正/期限切れの配布トークンでデバイスだけ作られる部分適用を防ぐ。
  if (input.deliveryToken) {
    const delivery = await lookupAgentInstallation(input.deliveryToken);
    if (!delivery || delivery.auth_method !== 'gws') {
      return noStoreManagementResponse(401, { error: 'invalid_grant' });
    }
  }
  const keyRows = await db<{ public_key: Buffer | null }[]>`
    SELECT app.device_login_enrollment_key(${hashManagementDeviceCode(input.deviceCode)}) AS public_key
  `;
  const publicKey = keyRows[0]?.public_key;
  if (!publicKey || !verifyManagementRedeemSignature(
    publicKey,
    canonicalManagementRedeemPayload({ deviceCode: input.deviceCode, nonce: input.nonce, issuedAt: input.issuedAt }),
    input.signature,
  )) {
    return noStoreManagementResponse(401, { error: 'invalid_grant' });
  }
  const rows = await db<{ result: Record<string, unknown> }[]>`
    SELECT app.redeem_device_login_enrollment(
      ${hashManagementDeviceCode(input.deviceCode)}, ${publicKey}, ${input.nonce}, ${input.issuedAt}::timestamptz
    ) AS result
  `;
  const result = rows[0]?.result ?? {};
  if (result.ok === true && input.deliveryToken) {
    const delivery = await markAgentInstallation(
      input.deliveryToken,
      'active',
      typeof result.hardware_id === 'string' ? result.hardware_id : undefined,
      typeof result.device_id === 'string' ? result.device_id : undefined,
    );
    if (delivery.ok !== true) return noStoreManagementResponse(409, { error: 'ENROLLMENT_INCONSISTENT' });
  }
  return responseFor(result);
}
