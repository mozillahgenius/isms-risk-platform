import 'server-only';
import { headers } from 'next/headers';
import type { TransactionSql } from 'postgres';
import { getDb, getProxyWriteDb, getWriteDb, DbUnavailable } from './db';
import { trustedProxyEmail } from './deviceControlAuth';

// Where the tenant context is established and reads happen.
//
// **Always establish and use it within a single transaction.**
// app.set_tenant_context() sets the GUC with set_config(..., true) (= equivalent to SET LOCAL), so
// it disappears when the transaction ends. Connections are reused from a pool, so
// sending the "establishing query" and the "business query" separately can route them to different connections and run without context.
// Doing both inside sql.begin() confines them to the same connection and the same transaction.
//
// The token is read **only from server-side environment variables**. No NEXT_PUBLIC_ prefix.
// Never exposed in URLs, HTML, or logs. Reads use this tenant boundary, and web writes
// additionally bind the trusted oauth2-proxy email to an actual user in the same tenant.

export function tenantToken(): string | null {
  const t = process.env.ISMS_WEB_TENANT_TOKEN;
  return t && t.length >= 32 ? t : null;
}

export async function trustedWebActorEmail(): Promise<string | null> {
  const requestHeaders = await headers();
  return trustedProxyEmail(
    requestHeaders.get('x-isms-device-control-proxy-secret'),
    process.env.ISMS_DEVICE_CONTROL_PROXY_SECRET,
    requestHeaders.get('x-forwarded-email'),
  );
}

export type TenantReadResult<T> =
  | { ok: true; data: T }
  | { ok: false; reason: 'no_token' | 'invalid_session' | 'domain' | 'error'; detail?: string };

const DOMAIN_ERRORS = new Set([
  'IDEMPOTENCY_CONFLICT', 'RISK_NOT_FOUND', 'MANAGEMENT_SERVICE_FORBIDDEN',
  'MANAGEMENT_REQUESTER_FORBIDDEN', 'MANAGEMENT_IDENTITY_MISMATCH',
  'MANAGEMENT_APPROVAL_INVALID', 'MANAGEMENT_POLICY_INVALID',
  'MANAGEMENT_SNAPSHOT_STALE',
]);

function domainError(message: string): string | null {
  for (const code of DOMAIN_ERRORS) {
    if (message.includes(code)) return code;
  }
  return null;
}

/**
 * Establish the tenant context and run fn. Read-only (the connection is read only).
 * When the token is missing or ineffective, return that as a type (do not throw and turn it into a 500).
 */
export async function withTenant<T>(
  fn: (sql: TransactionSql) => Promise<T>,
): Promise<TenantReadResult<T>> {
  const token = tenantToken();
  if (!token) return { ok: false, reason: 'no_token' };

  try {
    const data = await getDb().begin(async (sql) => {
      await sql`SELECT app.set_tenant_context(${token})`;
      return fn(sql);
    });
    return { ok: true, data: data as T };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    // Expired, revoked, or suspended users end up here. Report it distinctly from a configuration mistake.
    if (/invalid session/i.test(msg)) {
      console.error('[tenant] セッションが無効です（期限切れ・失効・停止のいずれか）');
      return { ok: false, reason: 'invalid_session' };
    }
    // Only the kind is shown on screen. The details are kept only in the server log.
    // Wrapped in DbUnavailable so it can be handled the same way as other DB failures.
    console.error('[tenant] テナント文脈での読み取りに失敗:', new DbUnavailable(e));
    return { ok: false, reason: 'error' };
  }
}

/** For registering/updating the register. Even on a write connection, always establish the same tenant boundary as reads first. */
export async function withTenantWrite<T>(
  fn: (sql: TransactionSql) => Promise<T>,
): Promise<TenantReadResult<T>> {
  const token = tenantToken();
  const actorEmail = await trustedWebActorEmail();
  if (actorEmail) return withTenantWriteProxyActor(token, actorEmail, fn);
  if (process.env.NODE_ENV !== 'production' && process.env.ISMS_WEB_ALLOW_SHARED_WRITE_ACTOR === 'true') {
    return withTenantWriteToken(token, fn);
  }
  console.error('[tenant] 信頼済みプロキシ本人性が無いため Web 書き込みを拒否しました');
  return { ok: false, reason: 'invalid_session', detail: 'trusted_proxy_identity_required' };
}

/** Read using the same proxy-authenticated person that Web mutations authorize. */
export async function withTenantActor<T>(
  fn: (sql: TransactionSql) => Promise<T>,
): Promise<TenantReadResult<T>> {
  const token = tenantToken();
  const actorEmail = await trustedWebActorEmail();
  if (!actorEmail) {
    if (process.env.NODE_ENV !== 'production' && process.env.ISMS_WEB_ALLOW_SHARED_WRITE_ACTOR === 'true') {
      return withTenant(fn);
    }
    return { ok: false, reason: 'invalid_session', detail: 'trusted_proxy_identity_required' };
  }
  if (!token) return { ok: false, reason: 'no_token' };
  try {
    const data = await getProxyWriteDb().begin(async (sql) => {
      await sql`SELECT app.set_tenant_context_for_proxy(${token},${actorEmail})`;
      return fn(sql);
    });
    return { ok: true, data: data as T };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (/invalid session|proxy identity/i.test(msg)) return { ok: false, reason: 'invalid_session' };
    console.error('[tenant] 本人文脈での読み取りに失敗:', new DbUnavailable(e));
    return { ok: false, reason: 'error' };
  }
}

async function withTenantWriteProxyActor<T>(
  token: string | null,
  actorEmail: string,
  fn: (sql: TransactionSql) => Promise<T>,
): Promise<TenantReadResult<T>> {
  if (!token) return { ok: false, reason: 'no_token' };
  try {
    const data = await getProxyWriteDb().begin(async (sql) => {
      await sql`SELECT app.set_tenant_context_for_proxy(${token},${actorEmail})`;
      return fn(sql);
    });
    return { ok: true, data: data as T };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (/invalid session|proxy identity/i.test(msg)) {
      console.error('[tenant] プロキシ本人性または書き込み用セッションが無効です');
      return { ok: false, reason: 'invalid_session' };
    }
    const code = domainError(msg);
    if (code) return { ok: false, reason: 'domain', detail: code };
    console.error('[tenant] 本人文脈での書き込みに失敗:', new DbUnavailable(e));
    return { ok: false, reason: 'error' };
  }
}

/** Fixed internal integrations may use a distinct server-only session token. */
export async function withTenantWriteToken<T>(
  token: string | null,
  fn: (sql: TransactionSql) => Promise<T>,
): Promise<TenantReadResult<T>> {
  if (!token) return { ok: false, reason: 'no_token' };

  try {
    const data = await getWriteDb().begin(async (sql) => {
      await sql`SELECT app.set_tenant_context(${token})`;
      return fn(sql);
    });
    return { ok: true, data: data as T };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (/invalid session/i.test(msg)) {
      console.error('[tenant] 書き込み用セッションが無効です');
      return { ok: false, reason: 'invalid_session' };
    }
    const code = domainError(msg);
    if (code) return { ok: false, reason: 'domain', detail: code };
    console.error('[tenant] テナント文脈での書き込みに失敗:', new DbUnavailable(e));
    return { ok: false, reason: 'error' };
  }
}
