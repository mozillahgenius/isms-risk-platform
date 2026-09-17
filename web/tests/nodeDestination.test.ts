import { describe, expect, it } from 'vitest';
import { destinationOf } from '../src/lib/nodeDestination';
import { groupKey } from '../src/lib/nodeid';

const UUID = '00000000-0000-4000-8000-000000000006';

describe('ノードの行き先', () => {
  it('実体の行は、その詳細ページへ送る', () => {
    expect(destinationOf('control', UUID)).toBe(`/catalog/controls/${UUID}`);
    expect(destinationOf('risk', UUID)).toBe(`/catalog/risks/${UUID}`);
    expect(destinationOf('policy', 'p01_basic')).toBe('/catalog/policies/p01_basic');
    expect(destinationOf('dom', '2026.1')).toBe('/');
  });

  it('導出ノードは、その条件で絞り込んだ一覧へ送る', () => {
    expect(destinationOf('group', groupKey('section', ['controls']))).toBe('/catalog/controls');
    expect(destinationOf('group', groupKey('theme', ['IPO-KARTE', '運営基盤', '機関設計']))).toBe(
      '/catalog/controls?framework=IPO-KARTE&theme=%E9%81%8B%E5%96%B6%E5%9F%BA%E7%9B%A4+%2F+%E6%A9%9F%E9%96%A2%E8%A8%AD%E8%A8%88',
    );
    expect(destinationOf('group', groupKey('phase', ['経理・税務', 'Phase1']))).toContain('/catalog/risks?domain=');
    expect(destinationOf('group', groupKey('empty', ['checks']))).toBe('/catalog/checks');
  });

  it('形の合わないキーは行き先を返さない（404 になるページへ飛ばさない）', () => {
    // decode はできるが uuid ではない。ここで止めないと 307 → 404 になり、
    // 「壊れた ID」と「消えた項目」の区別が付かなくなる。
    expect(destinationOf('control', 'abc')).toBeNull();
    expect(destinationOf('risk', 'abc')).toBeNull();
    expect(destinationOf('policy', '../etc/passwd')).toBeNull();
    expect(destinationOf('policy', 'P01_BASIC')).toBeNull(); // 大文字は自然キーに無い
    expect(destinationOf('frame', '存在しない観点')).toBeNull();
    expect(destinationOf('framework', 'a b/c')).toBeNull();
    expect(destinationOf('role', '../org')).toBeNull();
  });

  it('未知の型・未知の分類は行き先を返さない', () => {
    expect(destinationOf('unknown', 'x')).toBeNull();
    expect(destinationOf('group', groupKey('未知の軸', ['x']))).toBeNull();
    expect(destinationOf('group', groupKey('section', ['存在しない区分']))).toBeNull();
    expect(destinationOf('group', groupKey('theme', ['IPO-KARTE']))).toBeNull(); // 段が無い
  });
});
