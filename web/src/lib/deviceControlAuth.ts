// Separates out only the pure-function part of the authorization decision for device operations (device-control).
// deviceControl.ts has 'server-only', so it cannot be imported from plain vitest
// (outside webpack/Next, server-only throws unconditionally). The logic itself is
// environment-independent string comparison, so it is extracted here to be tested directly.

import { timingSafeEqual } from 'node:crypto';

export function isEmailAuthorizedForDeviceControl(email: string | null | undefined, allowlistCsv: string | undefined): boolean {
  const allowed = new Set(
    (allowlistCsv ?? '').split(',').map((e) => e.trim().toLowerCase()).filter((e) => e.length > 0),
  );
  if (allowed.size === 0) return false; // Allowlist not set = nobody is allowed
  const normalized = (email ?? '').trim().toLowerCase();
  return normalized.length > 0 && allowed.has(normalized);
}

// x-forwarded-email is a request header, so it can be spoofed if there is a path that reaches this screen's Next.js process directly
// (e.g. a direct connection from the internal network that bypasses nginx/oauth2-proxy). The other existing pages accept
// this risk, but this screen sends real commands to devices and is the most sensitive, so
// a match of a shared-secret header known only to nginx/oauth2-proxy is also required (a second factor).
// Both unset and mismatch are rejected (fail-closed). The comparison is constant-time to avoid timing attacks.
export function isProxySecretValid(receivedSecret: string | null | undefined, expectedSecret: string | undefined): boolean {
  const expected = (expectedSecret ?? '').trim();
  const received = (receivedSecret ?? '').trim();
  if (expected.length < 16 || received.length === 0) return false;
  const a = Buffer.from(received);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** Return the proxy-authenticated actor only when both trusted headers are valid. */
export function trustedProxyEmail(
  receivedSecret: string | null | undefined,
  expectedSecret: string | undefined,
  forwardedEmail: string | null | undefined,
): string | null {
  if (!isProxySecretValid(receivedSecret, expectedSecret)) return null;
  const email = (forwardedEmail ?? '').trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;
  return email;
}

// Validation and classification of the device ledger (device operations screen) read response. Used from deviceControl.ts (server-only), but
// the logic itself is environment-independent, so it is extracted here to be tested directly from plain vitest
// (the path involving fetch/headers() itself is out of scope. At the same level as existing paths such as getDeviceControlHistory,
// the HTTP call wiring itself is not covered by integration tests).

// The full set of states the device ledger (external dispatcher side) can return (8 kinds).
// Values that do not match here are treated as an "unexpected response" (if new states are added, update this too).
const DEVICE_STATES = ['paused', 'failed', 'unmonitored', 'baseline', 'quiet', 'stale', 'never', 'ok'] as const;
export type DeviceState = (typeof DEVICE_STATES)[number];
export const KNOWN_DEVICE_STATES: ReadonlySet<string> = new Set(DEVICE_STATES);

export type DeviceDispatchPayload = {
  device_key: string;
  template_id: string;
  template_version: string;
  request_id: string;
  actor_email: string;
  reason: string;
};

/** Build in one place the required attribution information passed to the external dispatcher's audit. */
export function buildDeviceDispatchPayload(input: DeviceDispatchPayload): DeviceDispatchPayload | null {
  const payload = {
    device_key: input.device_key.trim(),
    template_id: input.template_id.trim(),
    template_version: input.template_version.trim(),
    request_id: input.request_id.trim(),
    actor_email: input.actor_email.trim().toLowerCase(),
    reason: input.reason.trim(),
  };
  if (Object.values(payload).some((value) => value.length === 0)) return null;
  if (payload.reason.length > 200) return null;
  return payload;
}

export type DeviceInventoryItem = {
  device_key: string;
  os_family: string;
  os_version: string | null;
  state: DeviceState;
  last_success_at: string | null;
};

export function isValidInventoryItem(value: unknown): value is DeviceInventoryItem {
  if (value === null || typeof value !== 'object') return false;
  const v = value as Record<string, unknown>;
  return typeof v.device_key === 'string' && v.device_key.length > 0
    && typeof v.os_family === 'string' && v.os_family.length > 0
    && (v.os_version === null || typeof v.os_version === 'string')
    && typeof v.state === 'string' && KNOWN_DEVICE_STATES.has(v.state)
    && (v.last_success_at === null || typeof v.last_success_at === 'string');
}

export type DeviceControlDevice = { key: string; label: string };

const MAX_DEVICE_FIELD_LENGTH = 200;

/**
 * Read the allowlist of target devices from the setting (ISMS_DEVICE_CONTROL_DEVICES).
 * Format is a JSON array: [{"key":"<device ID on the dispatcher side>","label":"display name"}, ...].
 * If unset, empty, or malformed, return an empty array (fail-closed: no selectable devices = no operations possible).
 * If even one element is invalid, discard the whole thing (do not read it partially and mix in unexpected devices).
 */
export function parseDeviceControlDevices(raw: string | undefined): DeviceControlDevice[] {
  if (!raw || raw.trim() === '') return [];
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(data)) return [];
  const seen = new Set<string>();
  const devices: DeviceControlDevice[] = [];
  for (const item of data) {
    if (item === null || typeof item !== 'object') return [];
    const { key, label } = item as Record<string, unknown>;
    if (typeof key !== 'string' || typeof label !== 'string') return [];
    const k = key.trim();
    const l = label.trim();
    if (!k || !l || k.length > MAX_DEVICE_FIELD_LENGTH || l.length > MAX_DEVICE_FIELD_LENGTH || seen.has(k)) return [];
    seen.add(k);
    devices.push({ key: k, label: l });
  }
  return devices;
}

// Devices not in the configured allowlist are excluded here too, without relying on the upstream filter
// (even if unknown devices get into deviceMap through config drift, they are not shown on this screen).
export function filterKnownInventoryItems(items: DeviceInventoryItem[], knownDeviceKeys: ReadonlySet<string>): DeviceInventoryItem[] {
  return items.filter((it) => knownDeviceKeys.has(it.device_key));
}

export type InventoryClassification =
  | { state: 'ok'; items: DeviceInventoryItem[] }
  | { state: 'empty'; items: [] }
  | { state: 'anomalous' };

// Classify the orchestrator response (parsed JSON). Do not confuse "empty" with "no devices can be shown due to an anomaly/config drift":
// the former is only when the orchestrator itself returned a validated empty array
// with state='empty'. If rawState='ok' but items is empty, or all items are
// outside the fixed list (= effectively 0 known devices), it is 'anomalous', and the caller falls back to unavailable.
export function classifyInventoryResponse(
  rawState: unknown,
  rawItems: unknown,
  knownDeviceKeys: ReadonlySet<string>,
): InventoryClassification {
  if (rawState === 'empty' && Array.isArray(rawItems) && rawItems.length === 0) {
    return { state: 'empty', items: [] };
  }
  if (rawState === 'ok' && Array.isArray(rawItems) && rawItems.length > 0 && rawItems.every(isValidInventoryItem)) {
    const items = filterKnownInventoryItems(rawItems, knownDeviceKeys);
    return items.length > 0 ? { state: 'ok', items } : { state: 'anomalous' };
  }
  return { state: 'anomalous' };
}
