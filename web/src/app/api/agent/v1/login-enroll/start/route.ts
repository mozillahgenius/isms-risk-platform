import {
  MANAGEMENT_LOGIN_POLL_INTERVAL_SECONDS,
  MANAGEMENT_LOGIN_REQUEST_TTL_SECONDS,
  formatManagementUserCode,
  generateManagementDeviceCode,
  generateManagementUserCode,
  hashManagementDeviceCode,
  hashManagementUserCode,
  managementLoginEnabled,
  managementLoginSource,
  managementTargetActivationUri,
  managementVerificationUri,
  noStoreManagementResponse,
  parseManagementLoginStartBody,
  readManagementJsonObject,
} from '@/lib/managementEnrollment';
import { hashDeliveryToken } from '@/lib/agentDistribution';
import { getAgentDb } from '@/lib/agent-db';

export const dynamic = 'force-dynamic';

export async function POST(request: Request) {
  if (!managementLoginEnabled()) return noStoreManagementResponse(403, { error: 'closed' });
  const verificationUri = managementVerificationUri();
  if (!verificationUri) return noStoreManagementResponse(503, { error: 'unavailable' });
  const body = await readManagementJsonObject(request);
  const input = body ? parseManagementLoginStartBody(body) : null;
  if (!input) return noStoreManagementResponse(400, { error: 'invalid_request' });
  const db = getAgentDb();
  const targetUri = input.deliveryToken ? managementTargetActivationUri(input.deliveryToken) : null;
  if (input.deliveryToken && !targetUri) return noStoreManagementResponse(400, { error: 'invalid_distribution' });
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const deviceCode = generateManagementDeviceCode();
    const userCode = generateManagementUserCode();
    const rows = await db<{ result: Record<string, unknown> }[]>`
      SELECT app.start_device_login_enrollment(
        ${hashManagementDeviceCode(deviceCode)}, ${hashManagementUserCode(userCode)},
        ${input.publicKey}, ${input.hardwareId}, ${input.hostname}, ${input.model},
        ${input.osFamily}, ${input.offPremise}, ${input.noticeVersion}, ${managementLoginSource(request)},
        ${input.deliveryToken ? hashDeliveryToken(input.deliveryToken) : null}
      ) AS result
    `;
    const result = rows[0]?.result ?? {};
    if (result.ok === true) {
      const expiresAt = typeof result.expires_at === 'string' ? result.expires_at : null;
      return noStoreManagementResponse(200, {
        device_code: deviceCode,
        user_code: formatManagementUserCode(userCode),
        verification_uri: targetUri ?? verificationUri,
        expires_in: MANAGEMENT_LOGIN_REQUEST_TTL_SECONDS,
        expires_at: expiresAt,
        interval: MANAGEMENT_LOGIN_POLL_INTERVAL_SECONDS,
      });
    }
    if (result.reason === 'retry') continue;
    if (result.reason === 'rate_limited') return noStoreManagementResponse(429, { error: 'rate_limited' });
    return noStoreManagementResponse(400, { error: 'invalid_request' });
  }
  return noStoreManagementResponse(503, { error: 'unavailable' });
}
