import 'server-only';
import { headers } from 'next/headers';
import type { TransactionSql } from 'postgres';
import { getDb, getProxyWriteDb, getWriteDb, DbUnavailable } from './db';
import { trustedProxyEmail } from './deviceControlAuth';

// テナント文脈を確立して読むところ。
//
// **必ず 1 つのトランザクションの中で確立して使う。**
// app.set_tenant_context() は set_config(..., true)（= SET LOCAL 相当）で GUC を置くので、
// トランザクションが終われば消える。接続はプールで使い回されるため、
// 「確立するクエリ」と「業務クエリ」を別々に投げると、別の接続に流れて文脈が無いまま実行される。
// sql.begin() の中で両方やることで、同じ接続・同じトランザクションに閉じ込める。
//
// トークンは **サーバ側の環境変数だけ**から読む。NEXT_PUBLIC_ を付けない。
// URL にも HTML にもログにも出さない。読み取りはこのテナント境界を使い、Web書き込みは
// さらに信頼済み oauth2-proxy のメールを同一テナントの実利用者へ束縛する。

export function tenantToken(): string | null {
  const t = process.env.ISMS_WEB_TENANT_TOKEN;
  return t && t.length >= 32 ? t : null;
}

export async function trustedWebActorEmail(): Promise<string | null> {
  const requestHeaders = await headers();
  return trustedProxyEmail(
    requestHeaders.get('x-ib-device-control-proxy-secret'),
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
 * テナント文脈を確立して fn を走らせる。読み取り専用（接続が read only）。
 * トークンが無い・効かないときは、それを型で返す（例外にして 500 にしない）。
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
    // 期限切れ・失効・停止済みの利用者はここに来る。設定の間違いと区別して出す。
    if (/invalid session/i.test(msg)) {
      console.error('[tenant] セッションが無効です（期限切れ・失効・停止のいずれか）');
      return { ok: false, reason: 'invalid_session' };
    }
    // 画面に出すのは種別だけ。中身はサーバのログにだけ残す。
    // DbUnavailable に包むのは、他の DB 失敗と同じ形で扱えるようにするため。
    console.error('[tenant] テナント文脈での読み取りに失敗:', new DbUnavailable(e));
    return { ok: false, reason: 'error' };
  }
}

/** 台帳の登録・更新用。書き込み接続でも、読み取りと同じテナント境界を必ず先に確立する。 */
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
