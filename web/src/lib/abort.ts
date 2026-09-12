/**
 * Whether this is a fetch abort (a timeout via AbortController).
 *
 * Don't check with `instanceof Error`. An abort is thrown as a DOMException, and depending on the runtime
 * it is not treated as a subclass of Error (Codex review 2026-09-12, 3rd-round finding). Only the name is checked.
 */
export function isAbortError(e: unknown): boolean {
  return typeof e === 'object' && e !== null && (e as { name?: unknown }).name === 'AbortError';
}
