// DB 由来の失敗を、画面に出してよい形へ丸める。
//
// server-only を付けない（純関数でテストから読めるようにするため）。DB には触らない。

/**
 * 「読めない理由」を画面に出せる形にする。
 *
 * 失敗の中身は選べない。接続に失敗すれば host:port が、認証に失敗すれば利用者名が
 * 文面に混ざる。期待している理由（テナント文脈が無い・権限が無い）は種別として出し、
 * それ以外は種別だけ出す。詳しい中身はサーバのログにある。
 */
export function safeReason(message: string): string {
  const first = message.split('\n')[0].trim();
  if (first.includes('tenant context is not set')) {
    return 'tenant context is not set（テナント文脈が確立されていない）';
  }
  if (/permission denied|must be owner|not authorized/i.test(first)) {
    return '権限がありません（app_ro に読む権限が無い）';
  }
  return '読み取りに失敗しました（詳細はサーバのログを参照）';
}
