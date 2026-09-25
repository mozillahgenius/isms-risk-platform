import 'server-only';

import { headers } from 'next/headers';
import {
  classifyInventoryResponse,
  buildDeviceDispatchPayload,
  isEmailAuthorizedForDeviceControl,
  isProxySecretValid,
  type DeviceInventoryItem as ValidatedDeviceInventoryItem,
} from './deviceControlAuth';
import { tenantToken, withTenant } from './tenant';
import { isAbortError } from './abort';

export { isEmailAuthorizedForDeviceControl };

// Codzilla orchestrator の /api/isms-dispatch を叩くサーバー専用クライアント。
//
// トークンは NEXT_PUBLIC_ を付けず、サーバ側の環境変数からしか読まない(tenant.ts と同じ方針)。
// isms-platform は Kaname の書込用トークンを一切持たない — Codzilla側の /api/isms-dispatch/history
// が Codzilla 自身の tool_calls テーブルだけを読むため、Kaname に直接触れる必要が無い。
//
// Codzilla のサービスアカウントは配送主体として固定する一方、人間の実行者は
// 認証済みヘッダから取得し、理由・テンプレート版とともに監査属性として送る。

export type DeviceControlDevice = { key: string; label: string };

// 配布先テナントの KANAME_DEVICE_CONTROL_DEVICE_MAP と一致する値へ置き換えてから利用する。
// ここにある値は匿名化済みの例であり、実端末の UUID や利用者名をリポジトリへ埋め込まない。
//
// key は Codzilla orchestrator 側のマップの値(Kaname device_id、UUID)と一致させる必要がある。
// 人が読むラベルとしては使わない機械的な識別子なので、表示名は label 側に持たせる。
export const DEVICE_CONTROL_DEVICES: DeviceControlDevice[] = [
  { key: '00000000-0000-4000-8000-000000000001', label: 'managed-device-01' },
  { key: '00000000-0000-4000-8000-000000000002', label: 'managed-device-02' },
  { key: '00000000-0000-4000-8000-000000000003', label: 'managed-device-03' },
  { key: '00000000-0000-4000-8000-000000000004', label: 'managed-device-04' },
  { key: '00000000-0000-4000-8000-000000000005', label: 'managed-device-05' },
];

export type DispatchTemplateId = 'patch.macos_update' | 'screen_share.enable' | 'screen_share.disable';

export type DispatchTemplate = {
  id: DispatchTemplateId;
  version: string;
  label: string;
  description: string;
  risk: 'low';
  evidence: string;
};

// 現行の操作面は Apple MDM ではなく、Codzilla Local Agent による固定操作 RMM。
// UI が将来機能を先に名乗らないよう、実際に配備済みのテンプレートだけを列挙する。
export const DISPATCH_TEMPLATES: DispatchTemplate[] = [
  {
    id: 'patch.macos_update',
    version: '2026-09-04.1',
    label: 'macOS更新を適用',
    description: '端末側で定義済みのmacOS更新だけを実行します。',
    risk: 'low',
    evidence: '終了コードとCodzilla実行監査',
  },
  {
    id: 'screen_share.enable',
    version: '2026-09-04.1',
    label: '画面共有を有効化',
    description: '管理支援用のRemote Managementを有効にします。',
    risk: 'low',
    evidence: '終了コードとCodzilla実行監査',
  },
  {
    id: 'screen_share.disable',
    version: '2026-09-04.1',
    label: '画面共有を無効化',
    description: '管理支援用のRemote Managementを無効に戻します。',
    risk: 'low',
    evidence: '終了コードとCodzilla実行監査',
  },
];

function dispatchUrl(): string | null {
  const base = process.env.CODZILLA_ISMS_DISPATCH_URL;
  return base ? base.replace(/\/$/, '') : null;
}

function dispatchToken(): string | null {
  const t = process.env.CODZILLA_ISMS_DISPATCH_TOKEN;
  return t && t.length >= 16 ? t : null;
}

// 台帳閲覧専用のS2Sトークン。実行用(CODZILLA_ISMS_DISPATCH_TOKEN)とは別の値を要求する
// (Codzilla orchestrator側もISMS_DISPATCH_VIEW_PROFILEという別プロファイルでのみ受け付ける)。
function dispatchViewToken(): string | null {
  const t = process.env.CODZILLA_ISMS_DISPATCH_VIEW_TOKEN;
  return t && t.length >= 16 ? t : null;
}

// tenantToken() は自社テナント限定のデプロイだけがサーバ環境変数として持つ値(tenant.tsと同じ方針)。
// これが無い環境では、この画面自体を「設定されていない」扱いにする
// (他社テナント向けデプロイに、実端末へのコマンド実行経路を持ち込まないための不変条件)。
export function isDeviceControlConfigured(): boolean {
  return dispatchUrl() !== null && dispatchToken() !== null && tenantToken() !== null;
}

export function isDeviceInventoryConfigured(): boolean {
  return dispatchUrl() !== null && dispatchViewToken() !== null && tenantToken() !== null;
}

// この画面はISMS内で最も強い権限(実端末へのコマンド実行トリガー)を持つため、
// 前段のSSOリバースプロキシに認可を委ねきらず、アプリ層でも独立して確認する。
// 二要素で判定する: (1) nginx/oauth2-proxyだけが知る共有シークレットヘッダ
// (x-ib-device-control-proxy-secret、ISMS_DEVICE_CONTROL_PROXY_SECRETと一致必須。
// Tailscale直結などnginxを経由しない経路からのヘッダ偽装を防ぐ) (2) oauth2-proxy が
// upstreamへの reverse proxy モード(このデプロイの構成)で --pass-user-headers(既定true)
// により注入する x-forwarded-email が明示的な許可リスト
// (ISMS_DEVICE_CONTROL_ALLOWED_EMAILS、カンマ区切り)に含まれること。
// 注意: x-auth-request-email は nginx の auth_request サブリクエスト応答ヘッダ用
// (--set-xauthrequest)であり、oauth2-proxyがreverse_proxyとして直接upstreamへ
// 転送するこの構成では送られない(2026-09-01 実機調査で確認)。
// どちらか一方でも欠ける・不一致の経路は許可しない(fail-closed)。
// 判定ロジック自体は deviceControlAuth.ts(server-only非依存、テスト可能)。
export async function authorizedActorEmail(): Promise<string | null> {
  const h = await headers();
  const proxySecret = h.get('x-ib-device-control-proxy-secret');
  if (!isProxySecretValid(proxySecret, process.env.ISMS_DEVICE_CONTROL_PROXY_SECRET)) return null;
  const email = (h.get('x-forwarded-email') ?? '').trim().toLowerCase();
  return isEmailAuthorizedForDeviceControl(email, process.env.ISMS_DEVICE_CONTROL_ALLOWED_EMAILS) ? email : null;
}

// 端末台帳(OS種別・バージョン等)の閲覧は、実行(authorizedActorEmail)とは別の許可リストで
// 判定する(閲覧だけ許可された利用者に実行ボタンの権限まで渡さないため)。
// 判定ロジック自体は既存のisEmailAuthorizedForDeviceControl()をそのまま使う
// (許可リストの環境変数だけを別にする。新しい判定関数は作らない)。
export async function authorizedViewerEmail(): Promise<string | null> {
  const h = await headers();
  const proxySecret = h.get('x-ib-device-control-proxy-secret');
  if (!isProxySecretValid(proxySecret, process.env.ISMS_DEVICE_CONTROL_PROXY_SECRET)) return null;
  const email = (h.get('x-forwarded-email') ?? '').trim().toLowerCase();
  return isEmailAuthorizedForDeviceControl(email, process.env.ISMS_DEVICE_CONTROL_VIEW_ALLOWED_EMAILS) ? email : null;
}

// tenantToken() は環境変数の「値が設定されているか」しか見ない(期限切れ・失効・
// テナント/利用者の停止は判定できない)。実際の有効性は withTenant() が
// app.set_tenant_context() 経由でDBに問い合わせて初めて分かる。この経路はDBの
// データを必要としないが、有効なテナントセッションであることの検証それ自体のために
// withTenant を呼ぶ(値を使わない空の読み取りでよい)。
async function hasValidTenantSession(): Promise<boolean> {
  const result = await withTenant(async () => true);
  return result.ok === true;
}

export type DispatchResult =
  | { ok: true; text: string }
  | { ok: false; reason: 'not_configured' | 'unauthorized' | 'timeout' | 'http_error' | 'network_error'; detail?: string };

// 承認待ちで長時間ブロックされ得る(Codzilla側のexecuteToolが人の承認を待つ場合がある)。
// isms-platform 側のタイムアウトは、その待ち時間より短く切ってはいけない
// (短く切ると、承認後に実際は実行されているのに「失敗した」とUIに誤表示する)。
const DISPATCH_TIMEOUT_MS = 20 * 60 * 1000;

export async function dispatchDeviceControl(
  deviceKey: string,
  templateId: DispatchTemplateId,
  requestId: string,
  reason: string,
): Promise<DispatchResult> {
  // 認可を呼び出し元(Server Action)の確認だけに頼らない。この関数自身が実端末への
  // コマンド実行を引き起こす最終地点なので、将来別の経路から直接呼ばれても
  // 認可されていない要求を配送しない(fail-closed)。
  const actorEmail = await authorizedActorEmail();
  if (actorEmail === null) return { ok: false, reason: 'unauthorized' };
  const url = dispatchUrl();
  const token = dispatchToken();
  // isDeviceControlConfigured() は画面表示の出し分けにしか使われず、この関数自身を
  // 呼び出す経路(Server Action等)を止めない。自社テナント限定の不変条件は、
  // 実際に配送するこの関数自身にも直接持たせる(呼び出し元の確認漏れに依存しない)。
  // tenantToken()の存在確認だけでなく、withTenant()でセッションの実際の有効性を検証する
  // (失効・期限切れ・停止済みのトークンが環境変数に残っていても実行できてしまうのを防ぐ)。
  if (!url || !token || !(await hasValidTenantSession())) return { ok: false, reason: 'not_configured' };

  const template = DISPATCH_TEMPLATES.find((item) => item.id === templateId);
  if (!template) return { ok: false, reason: 'not_configured' };
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
      // タイムアウトしても、承認完了後にCodzilla側で実行されている可能性がある
      // (HTTP切断はexecuteToolの継続を止めない)。「失敗」ではなく「未確定」として扱う。
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
  // accepted / unconfirmed / closed_manually は設計書 2026-09-11 §9.4 で足した区分。
  // pending / unknown は旧版の orchestrator が返す値。配備順が前後しても表示が崩れないよう残す。
  execution_result: 'accepted' | 'success' | 'failed' | 'not_executed' | 'unconfirmed' | 'closed_manually' | 'pending' | 'unknown';
  /** 復旧キューへ渡す識別子。未確定の pending にだけ付く。 */
  request_id?: string | null;
  /** 復旧キューで人が閉じた記録。人の申告であって終了コードではない。 */
  recovery?: { outcome: string; note: string; resolved_actor_email: string; resolved_at: string } | null;
};

export type DispatchHistoryResult =
  | { ok: true; items: DispatchHistoryItem[] }
  | { ok: false; reason: 'not_configured' | 'unauthorized' | 'http_error' | 'network_error' };

const HISTORY_TIMEOUT_MS = 10_000;

export async function getDeviceControlHistory(deviceKey: string): Promise<DispatchHistoryResult> {
  // dispatchDeviceControl と同様、この関数自身が認可を確認する(呼び出し元任せにしない)。
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
    // timeout は「閉じられたかどうか分からない」。network_error（届かなかった）と分ける。
    reason: 'not_configured' | 'unauthorized' | 'too_early' | 'not_pending' | 'still_running' | 'timeout' | 'http_error' | 'network_error';
  };

/**
 * 未確定の要求を、人が端末を確かめたうえで閉じる（設計書 2026-09-11 §9.4 の復旧キュー）。
 * **再実行はしない。** Codzilla 側の台帳を閉じて端末の直列化を解き、誰が何を確かめたかを残すだけ。
 * dispatchDeviceControl と同じく、この関数自身が認可とテナントセッションを確かめる。
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
    // 復旧は実行と同じ入口へ action='recover' で送る（Codzilla 側で server.ts に経路を足さないため）。
    const res = await fetch(`${url}/api/isms-dispatch`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ action: 'recover', request_id: requestId, outcome, note, actor_email: actorEmail }),
      cache: 'no-store',
      signal: controller.signal,
    });
    if (res.ok) return { ok: true };
    // 本文が JSON でなければ空として扱う。ただし本文の読み取り中の時間切れは握りつぶさない（下の catch で timeout にする）。
    const data = (await res.json().catch((e: unknown) => {
      if (isAbortError(e)) throw e;
      return {};
    })) as { code?: unknown };
    if (data.code === 'too_early' || data.code === 'not_pending' || data.code === 'still_running') {
      return { ok: false, reason: data.code };
    }
    return { ok: false, reason: 'http_error' };
  } catch (e) {
    // 送った後で応答が来なかったのか、そもそも届かなかったのかを分ける。
    // 前者は上流で閉じ終わっている可能性があるので「失敗」とは言わない（再操作の前に履歴を見させる）。
    if (isAbortError(e)) return { ok: false, reason: 'timeout' };
    return { ok: false, reason: 'network_error' };
  } finally {
    clearTimeout(timer);
  }
}

export type DeviceInventoryItem = ValidatedDeviceInventoryItem;

// orchestrator側のstate('ok'|'empty'|'unavailable')に加え、isms-platform自身が検知した
// 通信断・認可拒否も'unavailable'系の理由として区別する(getDeviceControlHistoryと同じ
// 二層構造: 経路先(Kaname/orchestrator)の障害と、この画面自身の設定不備を混同しない)。
export type DeviceInventoryResult =
  | { state: 'ok'; items: DeviceInventoryItem[] }
  | { state: 'empty'; items: [] }
  | { state: 'unavailable'; reason: 'not_configured' | 'unauthorized' | 'http_error' | 'network_error' | 'upstream_unavailable'; items: [] };

const INVENTORY_TIMEOUT_MS = 10_000;

export async function getDeviceInventory(): Promise<DeviceInventoryResult> {
  // 閲覧許可リスト(authorizedViewerEmail)で判定する。実行者許可リストとは別の判定。
  if ((await authorizedViewerEmail()) === null) return { state: 'unavailable', reason: 'unauthorized', items: [] };
  const url = dispatchUrl();
  const token = dispatchViewToken();
  if (!url || !token || !(await hasValidTenantSession())) return { state: 'unavailable', reason: 'not_configured', items: [] };

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
    const known = new Set(DEVICE_CONTROL_DEVICES.map((d) => d.key));
    const classification = classifyInventoryResponse(
      (data as Record<string, unknown>).state,
      (data as Record<string, unknown>).items,
      known,
    );
    // 'anomalous'は「rawState='ok'なのにitemsが空/欠落」「全件が固定リスト外」
    // 「想定外の応答形」をまとめて指す。いずれも"登録端末が無い"(empty)とは別物であり、
    // 異常・設定ドリフトを0件と誤魔化さないためunavailableへ倒す。
    if (classification.state === 'anomalous') return { state: 'unavailable', reason: 'upstream_unavailable', items: [] };
    return classification;
  } catch {
    return { state: 'unavailable', reason: 'network_error', items: [] };
  } finally {
    clearTimeout(timer);
  }
}

export type ManagementDeviceInventoryItem = {
  id: string;
  target_email: string;
  target_name: string;
  os_family: string;
  status: string;
  hardware_id: string | null;
  device_id: string | null;
  created_at: string;
  installed_at: string | null;
  activated_at: string | null;
  failure_code: string | null;
};

export type ManagementDeviceInventoryResult =
  | { state: 'ok'; items: ManagementDeviceInventoryItem[] }
  | { state: 'empty'; items: [] }
  | { state: 'unavailable'; reason: 'not_configured' | 'unauthorized' | 'invalid_session' | 'database_error'; items: [] };

export type DeviceBasicsItem = {
  id: string;
  hostname: string;
  model: string | null;
  os_family: string;
  os_version: string | null;
  cpu: string | null;
  cores: string | null;
  memory: string | null;
  last_seen_at: string | null;
  agent_version: string | null;
  disk_encrypted: boolean | null;
  screen_lock_enabled: boolean | null;
  firewall_enabled: boolean | null;
  patch_current: boolean | null;
};

export type DeviceBasicsResult =
  | { state: 'ok'; items: DeviceBasicsItem[] }
  | { state: 'empty'; items: [] }
  | { state: 'unavailable'; reason: 'unauthorized' | 'not_configured' | 'invalid_session' | 'database_error'; items: [] };

/** PC の基礎情報（2026-09-25）。登録済みの端末と、その最新の状態の報告（OS・スペック・保護の状態）を並べる。
 *  スペック（cpu・cores・memory）は報告の payload.hardware から取る（macOS のエージェント 2026-09-25 版以降。無ければ空）。 */
export async function getDeviceBasics(): Promise<DeviceBasicsResult> {
  if ((await authorizedViewerEmail()) === null) return { state: 'unavailable', reason: 'unauthorized', items: [] };
  const result = await withTenant(async (sql) => sql<DeviceBasicsItem[]>`
    SELECT
      d.id::text,
      d.hostname,
      d.model,
      d.os_family,
      s.os_version,
      s.payload->'hardware'->>'cpu' AS cpu,
      s.payload->'hardware'->>'cores' AS cores,
      s.payload->'hardware'->>'memory' AS memory,
      d.last_seen_at::text,
      s.agent_version,
      s.disk_encrypted,
      s.screen_lock_enabled,
      s.firewall_enabled,
      s.patch_current
    FROM app.devices d
    LEFT JOIN LATERAL (
      SELECT * FROM app.device_snapshots x
      WHERE x.device_id = d.id
      ORDER BY x.collected_at DESC
      LIMIT 1
    ) s ON true
    WHERE d.tenant_id = app.current_tenant()
    ORDER BY d.hostname
    LIMIT 200
  `);
  if (!result.ok) {
    if (result.reason === 'no_token') return { state: 'unavailable', reason: 'not_configured', items: [] };
    if (result.reason === 'invalid_session') return { state: 'unavailable', reason: 'invalid_session', items: [] };
    return { state: 'unavailable', reason: 'database_error', items: [] };
  }
  return result.data.length > 0 ? { state: 'ok', items: result.data } : { state: 'empty', items: [] };
}

/** Management自身が保持するagent_installations台帳を表示用に読む。 */
export async function getManagementDeviceInventory(): Promise<ManagementDeviceInventoryResult> {
  if ((await authorizedViewerEmail()) === null) return { state: 'unavailable', reason: 'unauthorized', items: [] };

  const result = await withTenant(async (sql) => {
    return sql<ManagementDeviceInventoryItem[]>`
      SELECT
        id::text,
        target_email::text,
        target_name,
        os_family,
        status,
        hardware_id,
        device_id::text,
        created_at::text,
        installed_at::text,
        activated_at::text,
        failure_code
      FROM app.agent_installations
      WHERE tenant_id = app.current_tenant()
      ORDER BY created_at DESC
      LIMIT 100
    `;
  });

  if (!result.ok) {
    if (result.reason === 'no_token') return { state: 'unavailable', reason: 'not_configured', items: [] };
    if (result.reason === 'invalid_session') return { state: 'unavailable', reason: 'invalid_session', items: [] };
    return { state: 'unavailable', reason: 'database_error', items: [] };
  }
  return result.data.length > 0 ? { state: 'ok', items: result.data } : { state: 'empty', items: [] };
}
