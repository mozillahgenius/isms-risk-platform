import 'server-only';
import postgres, { type Sql } from 'postgres';

// The only entry point from the UI to the DB. **Connects with the read-only role (app_ro).**
//
// Why restrict by role:
//   A promise that merely says "the UI is read-only" can be broken by adding one line of code.
//   If the connection role only has SELECT, whoever tries to break it gets refused by the DB.
//   catalog grants app_ro SELECT only (migration 0015).
//
// Don't read app.* / audit.* from here. Reading app.* with app_ro doesn't return 0 rows; it
// fails with "tenant context is not set" (because there is no RLS tenant context).
// Displaying operational data is a separate matter that requires establishing a tenant context (app.set_tenant_context),
// and is outside this UI's scope. See tenantDataStatus() in src/lib/catalog.ts for details.

let client: Sql | null | undefined;
let writeClient: Sql | null | undefined;
let proxyWriteClient: Sql | null | undefined;

export function connectionString(): string {
  return process.env.ISMS_WEB_DATABASE_URL || 'postgres:///isms_dev?user=app_ro';
}

export function getDb(): Sql {
  if (client) return client;
  client = postgres(connectionString(), {
    max: 4,
    idle_timeout: 20,
    connect_timeout: 5,
    // The UI only reads. Make the transaction fail the moment a write is attempted
    // (a second safeguard on top of role privileges; writes fail even in an environment with a misconfigured role).
    connection: { default_transaction_read_only: true },
    onnotice: () => {},
  });
  return client;
}

export function writeConnectionString(): string {
  return process.env.ISMS_WRITE_DATABASE_URL || 'postgres:///isms_dev?user=app_rw';
}

/** A connection dedicated to register inserts/updates. Kept separate from the read-only app_ro. */
export function getWriteDb(): Sql {
  if (writeClient) return writeClient;
  writeClient = postgres(writeConnectionString(), {
    max: 2,
    idle_timeout: 20,
    connect_timeout: 5,
    onnotice: () => {},
  });
  return writeClient;
}

export function proxyWriteConnectionString(): string {
  return process.env.ISMS_PROXY_DATABASE_URL || 'postgres:///isms_dev?user=management_web';
}

/** Trusted browser writes only: this DB login alone may bind proxy identity. */
export function getProxyWriteDb(): Sql {
  if (proxyWriteClient) return proxyWriteClient;
  proxyWriteClient = postgres(proxyWriteConnectionString(), {
    max: 2,
    idle_timeout: 20,
    connect_timeout: 5,
    onnotice: () => {},
  });
  return proxyWriteClient;
}

/** Rethrows DB-originated failures in a form the UI can honestly display as "could not be retrieved". */
export class DbUnavailable extends Error {
  readonly cause: unknown;
  constructor(cause: unknown) {
    const detail = cause instanceof Error ? cause.message : String(cause);
    super(`DB を読めませんでした: ${detail}`);
    this.name = 'DbUnavailable';
    this.cause = cause;
  }
}

export async function query<T>(fn: (sql: Sql) => Promise<T>): Promise<T> {
  try {
    return await fn(getDb());
  } catch (e) {
    throw new DbUnavailable(e);
  }
}
