'use server';

import { randomUUID } from 'node:crypto';
import { redirect } from 'next/navigation';
import {
  authorizedActorEmail,
  deviceControlDevices,
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
 * Closes a pending request after a person has checked the device (recovery queue in design doc 2026-09-11 §9.4).
 * Does not retry. What was checked (note) is required and kept in the audit log.
 */
export async function recoverDispatchAction(formData: FormData) {
  const mode = formData.get('mode') === 'isms' ? 'isms' : 'risk';
  const deviceKey = String(formData.get('device_key') ?? '');
  const requestId = String(formData.get('request_id') ?? '').trim();
  const outcome = String(formData.get('outcome') ?? '');
  const note = String(formData.get('note') ?? '').trim();
  if (!isKnownDeviceKey(deviceKey)) redirect(`/operations/device-control?error=bad_request&mode=${mode}`);
  const back = `/operations/device-control?device=${encodeURIComponent(deviceKey)}&mode=${mode}`;
  // request_id is issued by dispatchDeviceControlAction via randomUUID(). Values of a different shape are not sent upstream.
  if (!UUID_RE.test(requestId) || !isRecoveryOutcome(outcome) || note.length === 0 || note.length > 1000) {
    redirect(`${back}&error=bad_request`);
  }
  const result = await recoverDeviceControlDispatch(requestId, outcome, note);
  if (!result.ok) redirect(`${back}&error=recover_${result.reason}`);
  redirect(`${back}&recovered=1`);
}

function isKnownDeviceKey(value: string): boolean {
  return deviceControlDevices().some((d) => d.key === value);
}
function isKnownTemplateId(value: string): value is DispatchTemplateId {
  return DISPATCH_TEMPLATES.some((t) => t.id === value);
}

export async function dispatchDeviceControlAction(formData: FormData) {
  // Do not delegate authorization entirely to the upstream SSO reverse proxy; check independently in the app layer too.
  // Header forwarding verified on real hardware in production (2026-09-01, x-forwarded-email). When unset or mismatched,
  // stay fail-closed (allowlist unset = nobody can execute).
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
