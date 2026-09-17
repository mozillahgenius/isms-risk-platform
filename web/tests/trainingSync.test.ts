import { describe, expect, it } from 'vitest';
import { invalidationTarget } from '../src/lib/trainingSync';

describe('invalidationTarget', () => {
  it('該当する講座が無ければ何もしない', () => {
    expect(invalidationTarget(false)).toEqual({ kind: 'none' });
  });

  it('講座があっても当てずに保留する', () => {
    // ここが核心。DB に該当講座があっても、応答の incomplete がどの年度の
    // 取消なのかは分からない（応答は年度を持たない）。DB の状態を根拠に
    // 当てると、過年度分の再同期で評価済み記録を消してしまう。
    expect(invalidationTarget(true)).toEqual({ kind: 'deferred' });
  });

  it('どの講座行も選ばない（id を返さない）', () => {
    expect(invalidationTarget(true)).not.toHaveProperty('id');
  });
});
