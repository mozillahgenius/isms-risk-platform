// 端末操作(device-control)の認可判定の純粋関数部分だけを分離する。
// deviceControl.ts 側は 'server-only' を持つため、素の vitest からは import できない
// (webpack/Next以外の環境では server-only が無条件でthrowする)。ロジック自体は
// 環境非依存の文字列比較なので、ここへ切り出して直接テストできるようにする。

import { timingSafeEqual } from 'node:crypto';

export function isEmailAuthorizedForDeviceControl(email: string | null | undefined, allowlistCsv: string | undefined): boolean {
  const allowed = new Set(
    (allowlistCsv ?? '').split(',').map((e) => e.trim().toLowerCase()).filter((e) => e.length > 0),
  );
  if (allowed.size === 0) return false; // 許可リスト未設定 = 誰も許可しない
  const normalized = (email ?? '').trim().toLowerCase();
  return normalized.length > 0 && allowed.has(normalized);
}

// x-forwarded-email はリクエストヘッダなので、この画面のNext.jsプロセスへ直接到達できる経路
// (例: nginx/oauth2-proxyを経由しないTailscale直結)があると偽装できる。既存の他ページはこの
// リスクを許容しているが、端末へ実コマンドを送るこの画面は最も機微度が高いため、
// nginx/oauth2-proxy側だけが知る共有シークレットヘッダの一致も必須にする(二要素目)。
// 未設定・不一致は共に拒否(fail-closed)。比較はタイミング攻撃を避けるため定数時間で行う。
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

// 端末台帳(端末操作画面)の閲覧応答の検証・分類。deviceControl.ts(server-only)から使うが、
// ロジック自体は環境非依存なのでここへ切り出し、素のvitestから直接テストできるようにする
// (fetch/headers()を伴う経路そのものは対象外。getDeviceControlHistory等の既存経路と
// 同じ水準で、HTTP呼び出しの配線自体は結合テストの対象としない)。

// Kaname kaname.device_status ビューが返しうる状態の全集合(0062_devices.sqlのcase文と同じ8種)。
// ここで一致しない値は「想定外の応答」として扱う(新しい状態が増えたら、ここも一緒に更新する)。
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

/** Codzilla と Kaname の監査へ渡す必須帰属情報を一か所で組み立てる。 */
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

// 対象5台の固定リストに無い端末は、upstream側のフィルタに依存せずここでも除外する
// (設定ドリフトで未知の端末がdeviceMapに混入しても、この画面には出さない)。
export function filterKnownInventoryItems(items: DeviceInventoryItem[], knownDeviceKeys: ReadonlySet<string>): DeviceInventoryItem[] {
  return items.filter((it) => knownDeviceKeys.has(it.device_key));
}

export type InventoryClassification =
  | { state: 'ok'; items: DeviceInventoryItem[] }
  | { state: 'empty'; items: [] }
  | { state: 'anomalous' };

// orchestrator応答(パース済みJSON)を分類する。「空である」と「異常/設定ドリフトで
// 表示できる端末が無い」を混同しない: 前者はorchestrator自身が検証済みの空配列を
// state='empty'で返した場合だけ。rawState='ok'なのにitemsが空、または全件が
// 固定リスト外(=既知端末が実質0件)は'anomalous'とし、呼び出し側でunavailableへ倒す。
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
