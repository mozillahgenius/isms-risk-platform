// Reduces DB-originated failures to a form that is safe to show on screen.
//
// No server-only marker (so tests can import it as a pure function). Does not touch the DB.

/**
 * Makes the "reason it could not be read" displayable on screen.
 *
 * The content of a failure cannot be chosen. A connection failure mixes host:port into
 * the message; an authentication failure mixes in the user name. Expected reasons (no tenant context, no permission) are shown as a kind,
 * and anything else is shown only as a kind. Details are in the server log.
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
