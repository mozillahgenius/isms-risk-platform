import 'server-only';

import { createHash, createPublicKey, randomBytes, randomInt, verify } from 'node:crypto';

export const MANAGEMENT_LOGIN_REQUEST_TTL_SECONDS = 600;
export const MANAGEMENT_LOGIN_POLL_INTERVAL_SECONDS = 5;
export const MANAGEMENT_LOGIN_APPROVAL_PATH = '/operations/device-control/approve';
export const MANAGEMENT_LOGIN_PURPOSE = 'management-login-enrollment-redeem/v1';
export const MANAGEMENT_LOGIN_NOTICE_VERSION = '2026-09-14.1';
export const MANAGEMENT_USER_CODE_ALPHABET = 'BCDFGHJKLMNPQRSTVWXZ';
export const MANAGEMENT_USER_CODE_LENGTH = 8;
export const MANAGEMENT_LOGIN_OS_FAMILIES = ['macos', 'windows', 'linux', 'dsm', 'other'] as const;

const DEVICE_CODE_RE = /^[A-Za-z0-9_-]{43}$/;
const NONCE_RE = /^[A-Za-z0-9_-]{16,128}$/;
const USER_CODE_RE = new RegExp(`^[${MANAGEMENT_USER_CODE_ALPHABET}]{${MANAGEMENT_USER_CODE_LENGTH}}$`);
const HOSTNAME_FORBIDDEN = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u;
const HARDWARE_ID_RE = /^[A-Za-z0-9._:-]{1,200}$/;
const NOTICE_VERSION_RE = /^[A-Za-z0-9._-]{1,32}$/;

export function managementLoginEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.ISMS_AGENT_LOGIN_ENROLLMENT_ENABLED === 'true';
}

export function managementAgentOrigin(env: NodeJS.ProcessEnv = process.env): string | null {
  const configured = env.ISMS_AGENT_ENROLLMENT_ORIGIN?.trim();
  const raw = configured || (env.NODE_ENV === 'production' ? 'https://management.example.invalid' : '');
  if (!raw) return null;
  try {
    const url = new URL(raw);
    const local = url.hostname === 'localhost' || url.hostname === '127.0.0.1';
    if (url.protocol !== 'https:' && !(url.protocol === 'http:' && local)) return null;
    if (url.username || url.password || url.search || url.hash || (url.pathname !== '/' && url.pathname !== '')) return null;
    return url.origin;
  } catch {
    return null;
  }
}

export function managementVerificationUri(env: NodeJS.ProcessEnv = process.env): string | null {
  const origin = managementAgentOrigin(env);
  return origin ? `${origin}${MANAGEMENT_LOGIN_APPROVAL_PATH}` : null;
}

export function managementTargetActivationUri(token: string, env: NodeJS.ProcessEnv = process.env): string | null {
  const origin = managementAgentOrigin(env);
  if (!origin || !/^[A-Za-z0-9_-]{32,128}$/.test(token)) return null;
  return `${origin}/operations/device-control/activate?token=${encodeURIComponent(token)}`;
}

export function generateManagementDeviceCode(): string {
  return randomBytes(32).toString('base64url');
}

export function generateManagementUserCode(): string {
  let code = '';
  for (let i = 0; i < MANAGEMENT_USER_CODE_LENGTH; i += 1) {
    code += MANAGEMENT_USER_CODE_ALPHABET[randomInt(MANAGEMENT_USER_CODE_ALPHABET.length)];
  }
  return code;
}

export function formatManagementUserCode(code: string): string {
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

export function normalizeManagementUserCode(value: unknown): string | null {
  if (typeof value !== 'string' || value.length > 32) return null;
  const code = value.toUpperCase().replace(/[\s-]/g, '');
  return USER_CODE_RE.test(code) ? code : null;
}

function hashWithPrefix(prefix: string, value: string): Buffer {
  return createHash('sha256').update(`${prefix}:${value}`, 'utf8').digest();
}

export function hashManagementDeviceCode(value: string): Buffer {
  return hashWithPrefix('management-login-device-code', value);
}

export function hashManagementUserCode(value: string): Buffer {
  return hashWithPrefix('management-login-user-code', value);
}

export function managementLoginSource(request: Request): string {
  const value = request.headers.get('x-real-ip')?.trim() ?? '';
  return value ? value.slice(0, 100) : 'unknown';
}

function validStandardBase64(value: unknown, bytes: number): value is string {
  if (typeof value !== 'string' || value.length > 200) return false;
  const decoded = Buffer.from(value, 'base64');
  return decoded.length === bytes && decoded.toString('base64') === value;
}

export type ManagementLoginStartInput = {
  hardwareId: string;
  hostname: string;
  model: string;
  offPremise: boolean;
  osFamily: (typeof MANAGEMENT_LOGIN_OS_FAMILIES)[number];
  publicKey: Buffer;
  noticeVersion: string;
  deliveryToken?: string;
};

export function parseManagementLoginStartBody(body: Record<string, unknown>): ManagementLoginStartInput | null {
  const hardwareId = body.hardware_id;
  const hostnameRaw = body.hostname;
  const modelRaw = body.model;
  const offPremise = body.off_premise;
  const osFamily = body.os_family;
  const noticeVersion = body.notice_version;
  const deliveryToken = body.delivery_token;
  if (typeof hardwareId !== 'string' || !HARDWARE_ID_RE.test(hardwareId)) return null;
  if (typeof hostnameRaw !== 'string' || typeof modelRaw !== 'string') return null;
  if (typeof offPremise !== 'boolean') return null;
  const hostname = hostnameRaw.trim();
  const model = modelRaw.trim();
  if ([...hostname].length < 1 || [...hostname].length > 255 || HOSTNAME_FORBIDDEN.test(hostname)) return null;
  if ([...model].length < 1 || [...model].length > 255 || HOSTNAME_FORBIDDEN.test(model)) return null;
  if (typeof osFamily !== 'string' || !(MANAGEMENT_LOGIN_OS_FAMILIES as readonly string[]).includes(osFamily)) return null;
  if (!validStandardBase64(body.public_key, 32)) return null;
  if (typeof noticeVersion !== 'string' || !NOTICE_VERSION_RE.test(noticeVersion)) return null;
  if (deliveryToken !== undefined && (typeof deliveryToken !== 'string' || !/^[A-Za-z0-9_-]{32,128}$/.test(deliveryToken))) return null;
  return {
    hardwareId,
    hostname,
    model,
    offPremise,
    osFamily: osFamily as ManagementLoginStartInput['osFamily'],
    publicKey: Buffer.from(body.public_key, 'base64'),
    noticeVersion,
    deliveryToken: typeof deliveryToken === 'string' ? deliveryToken : undefined,
  };
}

export type ManagementLoginRedeemInput = {
  deviceCode: string;
  nonce: string;
  issuedAt: string;
  signature: Buffer;
  deliveryToken?: string;
};

export function parseManagementLoginRedeemBody(body: Record<string, unknown>): ManagementLoginRedeemInput | null {
  if (typeof body.device_code !== 'string' || !DEVICE_CODE_RE.test(body.device_code)) return null;
  if (typeof body.nonce !== 'string' || !NONCE_RE.test(body.nonce)) return null;
  if (typeof body.issued_at !== 'string' || body.issued_at.length > 64 || !Number.isFinite(Date.parse(body.issued_at))) return null;
  if (!validStandardBase64(body.sig, 64)) return null;
  if (body.delivery_token !== undefined
      && (typeof body.delivery_token !== 'string' || !/^[A-Za-z0-9_-]{32,128}$/.test(body.delivery_token))) return null;
  return {
    deviceCode: body.device_code,
    nonce: body.nonce,
    issuedAt: body.issued_at,
    signature: Buffer.from(body.sig, 'base64'),
    deliveryToken: typeof body.delivery_token === 'string' ? body.delivery_token : undefined,
  };
}

export function canonicalManagementRedeemPayload(input: {
  deviceCode: string;
  nonce: string;
  issuedAt: string;
}): string {
  return JSON.stringify({
    device_code: input.deviceCode,
    issued_at: input.issuedAt,
    nonce: input.nonce,
    purpose: MANAGEMENT_LOGIN_PURPOSE,
  });
}

function ed25519PublicKeyFromRaw(publicKey: Buffer): ReturnType<typeof createPublicKey> {
  // SubjectPublicKeyInfo prefix for a raw Ed25519 public key.
  return createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), publicKey]), format: 'der', type: 'spki' });
}

export function verifyManagementRedeemSignature(publicKey: Buffer, payload: string, signature: Buffer): boolean {
  try {
    return verify(null, Buffer.from(payload, 'utf8'), ed25519PublicKeyFromRaw(publicKey), signature);
  } catch {
    return false;
  }
}

export function noStoreManagementResponse(status: number, body: Record<string, unknown>): Response {
  return Response.json(body, { status, headers: { 'Cache-Control': 'no-store', Pragma: 'no-cache' } });
}

export async function readManagementJsonObject(request: Request, limit = 4096): Promise<Record<string, unknown> | null> {
  try {
    const declared = Number(request.headers.get('content-length') ?? '');
    if (Number.isFinite(declared) && declared > limit) return null;
    const raw = await request.arrayBuffer();
    if (raw.byteLength > limit) return null;
    const value: unknown = JSON.parse(Buffer.from(raw).toString('utf8'));
    return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
  } catch {
    return null;
  }
}
