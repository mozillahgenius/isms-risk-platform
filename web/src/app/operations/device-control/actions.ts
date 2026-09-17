'use server';

import { randomUUID } from 'node:crypto';
import { redirect } from 'next/navigation';
import {
  authorizedActorEmail,
  DEVICE_CONTROL_DEVICES,
  DISPATCH_TEMPLATES,
  dispatchDeviceControl,
  RECOVERY_OUTCOMES,
  recoverDeviceControlDispatch,
  type DispatchTemplateId,
  type RecoveryOutcome,
} from '@/lib/deviceControl';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isRecoveryOutcome(value: string): value is RecoveryOutcome {
  return (RECOVERY_OUTCOMES as readonly string[]).includes(value);
}

/**
 * 未確定の要求を、人が端末を確かめたうえで閉じる（設計書 2026-09-11 §9.4 の復旧キュー）。
 * 再実行はしない。何を確かめたか（note）を必須にし、監査に残す。
 */
export async function recoverDispatchAction(formData: FormData) {
  const mode = formData.get('mode') === 'isms' ? 'isms' : 'risk';
  const deviceKey = String(formData.get('device_key') ?? '');
  const requestId = String(formData.get('request_id') ?? '').trim();
  const outcome = String(formData.get('outcome') ?? '');
  const note = String(formData.get('note') ?? '').trim();
  if (!isKnownDeviceKey(deviceKey)) redirect(`/operations/device-control?error=bad_request&mode=${mode}`);
  const back = `/operations/device-control?device=${encodeURIComponent(deviceKey)}&mode=${mode}`;
  // request_id は dispatchDeviceControlAction が randomUUID() で発行したもの。形の違う値は上流へ送らない。
  if (!UUID_RE.test(requestId) || !isRecoveryOutcome(outcome) || note.length === 0 || note.length > 1000) {
    redirect(`${back}&error=bad_request`);
  }
  const result = await recoverDeviceControlDispatch(requestId, outcome, note);
  if (!result.ok) redirect(`${back}&error=recover_${result.reason}`);
  redirect(`${back}&recovered=1`);
}

function isKnownDeviceKey(value: string): boolean {
  return DEVICE_CONTROL_DEVICES.some((d) => d.key === value);
}
function isKnownTemplateId(value: string): value is DispatchTemplateId {
  return DISPATCH_TEMPLATES.some((t) => t.id === value);
}

export async function dispatchDeviceControlAction(formData: FormData) {
  // 前段のSSOリバースプロキシに認可を委ねきらず、アプリ層でも独立して確認する。
  // ヘッダ転送は本番で実機確認済み(2026-09-01、x-forwarded-email)。未設定・不一致時は
  // fail-closed(許可リスト未設定=誰も実行できない)のまま維持する。
  const mode = formData.get('mode') === 'isms' ? 'isms' : 'risk';
  const actorEmail = await authorizedActorEmail();
  if (!actorEmail) {
    redirect(`/operations/device-control?error=unauthorized&mode=${mode}`);
  }

  const deviceKey = String(formData.get('device_key') ?? '');
  const templateId = String(formData.get('template_id') ?? '');
  const reason = String(formData.get('reason') ?? '').trim();
  if (!isKnownDeviceKey(deviceKey) || !isKnownTemplateId(templateId) || reason.length === 0 || reason.length > 200) {
    redirect(`/operations/device-control?error=bad_request&mode=${mode}`);
  }

  const result = await dispatchDeviceControl(deviceKey, templateId, randomUUID(), reason);
  if (!result.ok) {
    redirect(`/operations/device-control?device=${encodeURIComponent(deviceKey)}&error=${result.reason}&mode=${mode}`);
  }
  redirect(`/operations/device-control?device=${encodeURIComponent(deviceKey)}&dispatched=1&mode=${mode}`);
}
