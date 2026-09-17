import { describe, expect, it } from 'vitest';
import { isPlaceholderBody } from '../src/lib/policyBody';

describe('規程の本文が書かれているか', () => {
  it('DOM 2026.1 に実際に入っている本文は、すべて仮置きと判定する', () => {
    // 実測値（psql で取得した中身そのまま）
    expect(isPlaceholderBody('# 情報セキュリティ基本方針\n\n（標準本文。差分を持つと逸脱として記録される）')).toBe(true);
    expect(isPlaceholderBody('# ISMS 適用範囲\n\n（標準本文）')).toBe(true);
    expect(isPlaceholderBody('# 組織・役割・責任規程\n\n（標準本文）')).toBe(true);
  });

  it('見出ししか無いもの・空も仮置き', () => {
    expect(isPlaceholderBody('# 見出しだけ')).toBe(true);
    expect(isPlaceholderBody('')).toBe(true);
    expect(isPlaceholderBody('   \n\n  ')).toBe(true);
  });

  it('本文が書かれていれば仮置きではない', () => {
    expect(
      isPlaceholderBody('# 情報セキュリティ基本方針\n\n当社は、情報資産を保護するため、次の方針を定める。\n\n1. 経営者は…'),
    ).toBe(false);
    // 注記に続いて本文があるものは本文あり
    expect(isPlaceholderBody('# 規程\n\n（注: 抜粋）\n\n第1条 目的')).toBe(false);
  });
});
