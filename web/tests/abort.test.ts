import { describe, expect, it } from 'vitest';
import { isAbortError } from '../src/lib/abort';

describe('isAbortError', () => {
  it('AbortController の中断（DOMException）を中断と判定する', async () => {
    const controller = new AbortController();
    controller.abort();
    const err = await fetch('http://127.0.0.1:9/', { signal: controller.signal }).catch((e: unknown) => e);
    expect(isAbortError(err)).toBe(true);
  });

  it('Error を継承していない中断でも名前で判定する', () => {
    // In some runtimes DOMException is not a subclass of Error. Build that shape directly and verify it.
    const foreign = Object.create(null) as { name: string };
    foreign.name = 'AbortError';
    expect(foreign instanceof Error).toBe(false);
    expect(isAbortError(foreign)).toBe(true);
  });

  it('中断以外は中断と判定しない', () => {
    expect(isAbortError(new TypeError('fetch failed'))).toBe(false);
    expect(isAbortError(new Error('boom'))).toBe(false);
    expect(isAbortError('AbortError')).toBe(false);
    expect(isAbortError(null)).toBe(false);
    expect(isAbortError(undefined)).toBe(false);
  });
});
