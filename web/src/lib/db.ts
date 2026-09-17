import 'server-only';
import postgres, { type Sql } from 'postgres';

// 画面から DB への唯一の入口。**読み取り専用ロール（app_ro）で繋ぐ。**
//
// なぜロールで縛るか:
//   「画面は読み取り専用です」と書いておくだけの約束は、コードを1行足せば破れる。
//   接続ロールに SELECT しか無ければ、破ろうとした側が DB に断られる。
//   catalog は app_ro に SELECT のみ（migration 0015）。
//
// app.* / audit.* はここから読まない。app_ro で app.* を読むと 0 件ではなく
// 「tenant context is not set」で失敗する（RLS のテナント文脈が無いため）。
// 運用データの表示はテナント文脈の確立（app.set_tenant_context）が要る別の話で、
// この画面の担当範囲ではない。詳細は src/lib/catalog.ts の tenantDataStatus()。

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
    // 画面は読み取りしかしない。書き込みを試みた時点でトランザクションが落ちるようにする
    // （ロール権限に加えた二重の歯止め。ロール設定を取り違えた環境でも書けない）。
    connection: { default_transaction_read_only: true },
    onnotice: () => {},
  });
  return client;
}

export function writeConnectionString(): string {
  return process.env.ISMS_WRITE_DATABASE_URL || 'postgres:///isms_dev?user=app_rw';
}

/** 台帳の登録・更新専用の接続。読み取り用の app_ro と分ける。 */
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

/** DB 由来の失敗を、画面が「取得できなかった」と正直に出せる形にして投げ直す。 */
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
