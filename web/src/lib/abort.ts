/**
 * fetch の中断（AbortController による時間切れ）かどうか。
 *
 * `instanceof Error` では判定しない。中断は DOMException として投げられ、実行環境によっては
 * Error の子として扱われない（Codex レビュー 2026-09-12 3 巡目指摘）。名前だけを見る。
 */
export function isAbortError(e: unknown): boolean {
  return typeof e === 'object' && e !== null && (e as { name?: unknown }).name === 'AbortError';
}
