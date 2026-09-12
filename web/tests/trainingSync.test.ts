import { describe, expect, it } from 'vitest';
import { invalidationTarget } from '../src/lib/trainingSync';

describe('invalidationTarget', () => {
  it('該当する講座が無ければ何もしない', () => {
    expect(invalidationTarget(false)).toEqual({ kind: 'none' });
  });

  it('講座があっても当てずに保留する', () => {
    // This is the crux. Even if the DB has the matching course, you cannot tell which year's
    // revocation the response's incomplete refers to (the response carries no year). Applying it based on DB state
    // would delete evaluated records during a resync of past years.
    expect(invalidationTarget(true)).toEqual({ kind: 'deferred' });
  });

  it('どの講座行も選ばない（id を返さない）', () => {
    expect(invalidationTarget(true)).not.toHaveProperty('id');
  });
});
