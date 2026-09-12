import { describe, expect, it } from 'vitest';
import { firstParam, pageParam } from '../src/lib/searchParams';

describe('クエリの均し', () => {
  it('同じ名前が複数回来ても落ちない（?q=a&q=b は配列で届く）', () => {
    // A place that would 500 because .trim() does not exist if we assumed a string.
    expect(firstParam(['a', 'b'])).toBe('a');
    expect(firstParam('a')).toBe('a');
    expect(firstParam(undefined)).toBe('');
    expect(firstParam([])).toBe('');
  });

  it('ページ番号は数でない値・0 以下・巨大な値を安全側へ倒す', () => {
    expect(pageParam('3')).toBe(3);
    expect(pageParam(['2', '9'])).toBe(2);
    expect(pageParam(undefined)).toBe(1);
    expect(pageParam('abc')).toBe(1);
    expect(pageParam('0')).toBe(1);
    expect(pageParam('-5')).toBe(1);
    expect(pageParam('99999999999')).toBe(100_000);
    expect(pageParam('1e9')).toBe(1); // parseInt returns 1
  });
});
