import 'server-only';

import { headers } from 'next/headers';
import {
  classifyInventoryResponse,
  buildDeviceDispatchPayload,
  isEmailAuthorizedForDeviceControl,
  isProxySecretValid,
  parseDeviceControlDevices,
  type DeviceControlDevice,
  type DeviceInventoryItem as ValidatedDeviceInventoryItem,
} from './deviceControlAuth';
import { tenantToken, withTenant } from './tenant';
import { isAbortError } from './abort';

export { isEmailAuthorizedForDeviceControl };
export type { DeviceControlDevice };

// Server-only client that calls /api/isms-dispatch on the external device dispatcher (orchestrator).
//
// The token has no NEXT_PUBLIC_ prefix and is read only from server-side environment variables (same policy as tenant.ts).
// isms-platform holds no token for writing to the device inventory at all: on the dispatcher side,
// /api/isms-dispatch/history reads only the dispatcher's own execution audit, so there is no need to touch the inventory directly.
//
// The dispatcher's service account is fixed as the delivering principal, while the human actor is
// taken from authenticated headers and sent as audit attributes along with the reason and template version.

// Target devices are limited to those explicitly configured (ISMS_DEVICE_CONTROL_DEVICES, a JSON array). Devices not listed there cannot be selected.
// If unset, zero devices (= nothing can be operated).
//
// key must match the dispatcher-side device ID (the dispatcher looks up the device by this value).
// It is a machine identifier not meant as a human-readable label, so the display name lives in label.
export function deviceControlDevices(): DeviceControlDevice[] {
  return parseDeviceControlDevices(process.env.ISMS_DEVICE_CONTROL_DEVICES);
}

export type DispatchTemplateId = 'patch.macos_update' | 'screen_share.enable' | 'screen_share.disable';

export type DispatchTemplate = {
  id: DispatchTemplateId;
  version: string;
  label: string;
  description: string;
  risk: 'low';
  evidence: string;
};

// The current control surface is not Apple MDM but a fixed-operation RMM via a local device agent (through the external dispatcher).
// List only templates that are actually deployed, so the UI does not advertise future features ahead of time.
export const DISPATCH_TEMPLATES: DispatchTemplate[] = [
  {
    id: 'patch.macos_update',
    version: '2026-09-04.1',
    label: 'macOS更新を適用',
    description: '端末側で定義済みのmacOS更新だけを実行します。',
    risk: 'low',
    evidence: '終了コードとディスパッチャの実行監査',
  },
  {
    id: 'screen_share.enable',
    version: '2026-09-04.1',
    label: '画面共有を有効化',
    description: '管理支援用のRemote Managementを有効にします。',
    risk: 'low',
    evidence: '終了コードとディスパッチャの実行監査',
  },
  {
    id: 'screen_share.disable',
    version: '2026-09-04.1',
    label: '画面共有を無効化',
    description: '管理支援用のRemote Managementを無効に戻します。',
    risk: 'low',
    evidence: '終了コードとディスパッチャの実行監査',
  },
];

function dispatchUrl(): string | null {
  const base = process.env.ISMS_DEVICE_DISPATCH_URL;
  return base ? base.replace(/\/$/, '') : null;
}

function dispatchToken(): string | null {
  const t = process.env.ISMS_DEVICE_DISPATCH_TOKEN;
  return t && t.length >= 16 ? t : null;
}

// S2S token for inventory viewing only. Requires a value distinct from the execution token (ISMS_DEVICE_DISPATCH_TOKEN)
// (the dispatcher side also accepts it only under a separate profile, ISMS_DISPATCH_VIEW_PROFILE).
function dispatchViewToken(): string | null {
  const t = process.env.ISMS_DEVICE_DISPATCH_VIEW_TOKEN;
  return t && t.length >= 16 ? t : null;
}

// tenantToken() is a value that only own-organization-only deployments hold as a server environment variable (same policy as tenant.ts).
// In environments without it, this screen itself is treated as "not configured"
// (an invariant that keeps command-execution paths to real devices out of deployments for other organizations' tenants).
export function isDeviceControlConfigured(): boolean {
  return dispatchUrl() !== null && dispatchToken() !== null && tenantToken() !== null && deviceControlDevices().length > 0;
}

export function isDeviceInventoryConfigured(): boolean {
  return dispatchUrl() !== null && dispatchViewToken() !== null && tenantToken() !== null;
}

// This screen holds the strongest privilege in the ISMS (triggering command execution on real devices), so
// authorization is not left entirely to the upstream SSO reverse proxy; the app layer checks it independently too.
// Decided by two factors: (1) a shared-secret header known only to nginx/oauth2-proxy
// (x-isms-device-control-proxy-secret, must match ISMS_DEVICE_CONTROL_PROXY_SECRET;
// prevents header spoofing from paths that bypass nginx, such as direct connections from the internal network) (2) the x-forwarded-email that oauth2-proxy
// injects via --pass-user-headers (default true) in reverse proxy mode to upstream (this deployment's setup)
// must be in an explicit allowlist
// (ISMS_DEVICE_CONTROL_ALLOWED_EMAILS, comma-separated).
// Note: x-auth-request-email is for nginx auth_request subrequest response headers
// (--set-xauthrequest), and is not sent in this setup where oauth2-proxy forwards directly to upstream
// as a reverse_proxy (confirmed by an on-machine investigation on 2026-09-01).
// Any path where either factor is missing or mismatched is denied (fail-closed).
// The decision logic itself lives in deviceControlAuth.ts (no server-only dependency, testable).
export async function authorizedActorEmail(): Promise<string | null> {
  const h = await headers();
  const proxySecret = h.get('x-isms-device-control-proxy-secret');
  if (!isProxySecretValid(proxySecret, process.env.ISMS_DEVICE_CONTROL_PROXY_SECRET)) return null;
  const email = (h.get('x-forwarded-email') ?? '').trim().toLowerCase();
  return isEmailAuthorizedForDeviceControl(email, process.env.ISMS_DEVICE_CONTROL_ALLOWED_EMAILS) ? email : null;
}

// Viewing the device inventory (OS type, version, etc.) is decided by an allowlist separate from execution (authorizedActorEmail)
// (so users allowed only to view are not also given the privilege of the execute buttons).
// The decision logic itself reuses the existing isEmailAuthorizedForDeviceControl() as-is
// (only the allowlist environment variable differs; no new decision function is created).
export async function authorizedViewerEmail(): Promise<string | null> {
  const h = await headers();
  const proxySecret = h.get('x-isms-device-control-proxy-secret');
  if (!isProxySecretValid(proxySecret, process.env.ISMS_DEVICE_CONTROL_PROXY_SECRET)) return null;
  const email = (h.get('x-forwarded-email') ?? '').trim().toLowerCase();
  return isEmailAuthorizedForDeviceControl(email, process.env.ISMS_DEVICE_CONTROL_VIEW_ALLOWED_EMAILS) ? email : null;
}

// tenantToken() only checks whether the environment variable "has a value set" (it cannot detect expiry, revocation,
// or suspension of the tenant/user). Actual validity is only known once withTenant() queries
// the DB via app.set_tenant_context(). This path does not need DB
// data, but calls withTenant solely to verify that the tenant session is valid
// (an empty read that uses no values is fine).
async function hasValidTenantSession(): Promise<boolean> {
  const result = await withTenant(async () => true);
  return result.ok === true;
}

export type DispatchResult =
  | { ok: true; text: string }
  | { ok: false; reason: 'not_configured' | 'unauthorized' | 'timeout' | 'http_error' | 'network_error'; detail?: string };

// May block for a long time waiting for approval (dispatcher-side execution may wait for human approval).
// The isms-platform-side timeout must not be shorter than that wait
// (if cut short, the UI wrongly shows "failed" even though it actually ran after approval).
const DISPATCH_TIMEOUT_MS = 20 * 60 * 1000;

export async function dispatchDeviceControl(
  deviceKey: string,
  templateId: DispatchTemplateId,
  requestId: string,
  reason: string,
): Promise<DispatchResult> {
  // Do not rely solely on the caller (Server Action) for authorization. This function itself is the final point that
  // triggers command execution on real devices, so even if it is called directly from another path in the future,
  // it does not deliver unauthorized requests (fail-closed).
  const actorEmail = await authorizedActorEmail();
  if (actorEmail === null) return { ok: false, reason: 'unauthorized' };
  const url = dispatchUrl();
  const token = dispatchToken();
  // isDeviceControlConfigured() is only used to switch what the screen shows and does not stop the paths
  // (Server Actions etc.) that call this function. The own-organization-tenant-only invariant is
  // also held directly by this function, which actually delivers (not relying on callers remembering to check).
  // Beyond checking that tenantToken() exists, verify the session's actual validity with withTenant()
  // (prevents execution when a revoked, expired, or suspended token is still left in the environment variables).
  if (!url || !token || !(await hasValidTenantSession())) return { ok: false, reason: 'not_configured' };

  const template = DISPATCH_TEMPLATES.find((item) => item.id === templateId);
  if (!template) return { ok: false, reason: 'not_configured' };
  // Do not deliver to devices not in the configured allowlist (not relying on callers remembering to check).
  if (!deviceControlDevices().some((d) => d.key === deviceKey.trim())) return { ok: false, reason: 'not_configured' };
  const payload = buildDeviceDispatchPayload({
    device_key: deviceKey,
    template_id: templateId,
    template_version: template.version,
    request_id: requestId,
    actor_email: actorEmail,
    reason,
  });
  if (!payload) return { ok: false, reason: 'not_configured' };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), DISPATCH_TIMEOUT_MS);
  try {
    const res = await fetch(`${url}/api/isms-dispatch`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    const raw = await res.text();
    let data: unknown = {};
    try { data = raw ? JSON.parse(raw) : {}; } catch { data = {}; }
    if (!res.ok) {
      const error = (data as { error?: unknown })?.error;
      return { ok: false, reason: 'http_error', detail: typeof error === 'string' ? error : `HTTP ${res.status}` };
    }
    const text = (data as { text?: unknown })?.text;
    return { ok: true, text: typeof text === 'string' ? text : '' };
  } catch (e) {
    if (isAbortError(e)) {
      // Even after a timeout, the dispatcher may have executed it once approval completed
      // (an HTTP disconnect does not stop executeTool from continuing). Treat it as "unconfirmed", not "failed".
      return { ok: false, reason: 'timeout' };
    }
    return { ok: false, reason: 'network_error', detail: e instanceof Error ? e.message : String(e) };
  } finally {
    clearTimeout(timer);
  }
}

export type DispatchHistoryItem = {
  id: string;
  device_key: string | null;
  tool: string;
  policy_decision: string;
  matched_rule: string;
  status: string;
  created_at: string;
  exit_code: number | null;
  // accepted / unconfirmed / closed_manually are categories added in design doc 2026-09-11 §9.4.
  // pending / unknown are values returned by older orchestrator versions. Kept so the display does not break if deployment order varies.
  execution_result: 'accepted' | 'success' | 'failed' | 'not_executed' | 'unconfirmed' | 'closed_manually' | 'pending' | 'unknown';
  /** Identifier passed to the recovery queue. Present only on unconfirmed pending entries. */
  request_id?: string | null;
  /** Record of a person closing it in the recovery queue. A human declaration, not an exit code. */
  recovery?: { outcome: string; note: string; resolved_actor_email: string; resolved_at: string } | null;
};

export type DispatchHistoryResult =
  | { ok: true; items: DispatchHistoryItem[] }
  | { ok: false; reason: 'not_configured' | 'unauthorized' | 'http_error' | 'network_error' };

const HISTORY_TIMEOUT_MS = 10_000;

export async function getDeviceControlHistory(deviceKey: string): Promise<DispatchHistoryResult> {
  // Like dispatchDeviceControl, this function checks authorization itself (not left to the caller).
  if ((await authorizedActorEmail()) === null) return { ok: false, reason: 'unauthorized' };
  const url = dispatchUrl();
  const token = dispatchToken();
  if (!url || !token || !(await hasValidTenantSession())) return { ok: false, reason: 'not_configured' };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), HISTORY_TIMEOUT_MS);
  try {
    const res = await fetch(`${url}/api/isms-dispatch/history?device_key=${encodeURIComponent(deviceKey)}`, {
      headers: { authorization: `Bearer ${token}` },
      cache: 'no-store',
      signal: controller.signal,
    });
    if (!res.ok) return { ok: false, reason: 'http_error' };
    const data = (await res.json()) as { items?: DispatchHistoryItem[] };
    return { ok: true, items: Array.isArray(data.items) ? data.items : [] };
  } catch {
    return { ok: false, reason: 'network_error' };
  } finally {
    clearTimeout(timer);
  }
}

export type RecoveryOutcome = 'executed_confirmed' | 'not_executed_confirmed' | 'undetermined';
export const RECOVERY_OUTCOMES: readonly RecoveryOutcome[] = ['executed_confirmed', 'not_executed_confirmed', 'undetermined'];

export type RecoverResult =
  | { ok: true }
  | {
    ok: false;
    // timeout means "unknown whether it was closed". Kept separate from network_error (never arrived).
    reason: 'not_configured' | 'unauthorized' | 'too_early' | 'not_pending' | 'still_running' | 'timeout' | 'http_error' | 'network_error';
  };

/**
 * Close an unconfirmed request after a person has checked the device (recovery queue in design doc 2026-09-11 §9.4).
 * **It does not re-run anything.** It only closes the dispatcher-side ledger entry, releases the device's serialization, and records who checked what.
 * Like dispatchDeviceControl, this function itself checks authorization and the tenant session.
 */
export async function recoverDeviceControlDispatch(
  requestId: string,
  outcome: RecoveryOutcome,
  note: string,
): Promise<RecoverResult> {
  const actorEmail = await authorizedActorEmail();
  if (actorEmail === null) return { ok: false, reason: 'unauthorized' };
  const url = dispatchUrl();
  const token = dispatchToken();
  if (!url || !token || !(await hasValidTenantSession())) return { ok: false, reason: 'not_configured' };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), HISTORY_TIMEOUT_MS);
  try {
    // Recovery is sent to the same entry point as execution with action='recover' (to avoid adding paths on the dispatcher side).
    const res = await fetch(`${url}/api/isms-dispatch`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ action: 'recover', request_id: requestId, outcome, note, actor_email: actorEmail }),
      cache: 'no-store',
      signal: controller.signal,
    });
    if (res.ok) return { ok: true };
    // If the body is not JSON, treat it as empty. But a timeout while reading the body is not swallowed (the catch below turns it into timeout).
    const data = (await res.json().catch((e: unknown) => {
      if (isAbortError(e)) throw e;
      return {};
    })) as { code?: unknown };
    if (data.code === 'too_early' || data.code === 'not_pending' || data.code === 'still_running') {
      return { ok: false, reason: data.code };
    }
    return { ok: false, reason: 'http_error' };
  } catch (e) {
    // Distinguish between no response after sending and the request never arriving at all.
    // The former may already have been closed upstream, so do not call it "failed" (make the user check history before retrying).
    if (isAbortError(e)) return { ok: false, reason: 'timeout' };
    return { ok: false, reason: 'network_error' };
  } finally {
    clearTimeout(timer);
  }
}

export type DeviceInventoryItem = ValidatedDeviceInventoryItem;

// In addition to the orchestrator-side state ('ok'|'empty'|'unavailable'), connection loss and authorization denial
// detected by isms-platform itself are distinguished as 'unavailable'-type reasons (same
// two-layer structure as getDeviceControlHistory: do not confuse failures of the downstream target (device inventory/dispatcher) with misconfiguration of this screen itself).
export type DeviceInventoryResult =
  | { state: 'ok'; items: DeviceInventoryItem[] }
  | { state: 'empty'; items: [] }
  | { state: 'unavailable'; reason: 'not_configured' | 'unauthorized' | 'http_error' | 'network_error' | 'upstream_unavailable'; items: [] };

const INVENTORY_TIMEOUT_MS = 10_000;

export async function getDeviceInventory(): Promise<DeviceInventoryResult> {
  // Decided by the viewer allowlist (authorizedViewerEmail). A check separate from the actor allowlist.
  if ((await authorizedViewerEmail()) === null) return { state: 'unavailable', reason: 'unauthorized', items: [] };
  const url = dispatchUrl();
  const token = dispatchViewToken();
  const known = new Set(deviceControlDevices().map((d) => d.key));
  // If no target devices are configured, not a single device can be shown whatever the upstream returns. Treat it as missing configuration, not an upstream anomaly.
  if (!url || !token || known.size === 0 || !(await hasValidTenantSession())) {
    return { state: 'unavailable', reason: 'not_configured', items: [] };
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), INVENTORY_TIMEOUT_MS);
  try {
    const res = await fetch(`${url}/api/isms-dispatch/devices`, {
      headers: { authorization: `Bearer ${token}` },
      cache: 'no-store',
      signal: controller.signal,
    });
    if (!res.ok) return { state: 'unavailable', reason: 'http_error', items: [] };
    const data: unknown = await res.json();
    if (data === null || typeof data !== 'object') return { state: 'unavailable', reason: 'upstream_unavailable', items: [] };
    const classification = classifyInventoryResponse(
      (data as Record<string, unknown>).state,
      (data as Record<string, unknown>).items,
      known,
    );
    // 'anomalous' collectively covers "rawState='ok' but items empty/missing", "all entries outside the fixed list",
    // and "unexpected response shape". None of these is the same as "no registered devices" (empty),
    // so they fall to unavailable to avoid disguising anomalies or configuration drift as zero entries.
    if (classification.state === 'anomalous') return { state: 'unavailable', reason: 'upstream_unavailable', items: [] };
    return classification;
  } catch {
    return { state: 'unavailable', reason: 'network_error', items: [] };
  } finally {
    clearTimeout(timer);
  }
}
