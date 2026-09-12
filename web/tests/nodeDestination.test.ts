import { describe, expect, it } from 'vitest';
import { destinationOf } from '../src/lib/nodeDestination';
import { groupKey } from '../src/lib/nodeid';

const UUID = '12345678-1234-4123-8123-123456789abc';

describe('ノードの行き先', () => {
  it('実体の行は、その詳細ページへ送る', () => {
    expect(destinationOf('control', UUID)).toBe(`/catalog/controls/${UUID}`);
    expect(destinationOf('risk', UUID)).toBe(`/catalog/risks/${UUID}`);
    expect(destinationOf('policy', 'p01_basic')).toBe('/catalog/policies/p01_basic');
    expect(destinationOf('dom', '2026.1')).toBe('/');
  });

  it('導出ノードは、その条件で絞り込んだ一覧へ送る', () => {
    expect(destinationOf('group', groupKey('section', ['controls']))).toBe('/catalog/controls');
    expect(destinationOf('group', groupKey('theme', ['IPO-KARTE', 'サンプル大項目', 'サンプル中項目']))).toBe(
      '/catalog/controls?framework=IPO-KARTE&theme=%E3%82%B5%E3%83%B3%E3%83%97%E3%83%AB%E5%A4%A7%E9%A0%85%E7%9B%AE+%2F+%E3%82%B5%E3%83%B3%E3%83%97%E3%83%AB%E4%B8%AD%E9%A0%85%E7%9B%AE',
    );
    expect(destinationOf('group', groupKey('phase', ['サンプル部門A', 'Phase1']))).toContain('/catalog/risks?domain=');
    expect(destinationOf('group', groupKey('empty', ['checks']))).toBe('/catalog/checks');
  });

  it('形の合わないキーは行き先を返さない（404 になるページへ飛ばさない）', () => {
    // It decodes but is not a uuid. If not stopped here, it becomes 307 -> 404,
    // and "a broken ID" can no longer be distinguished from "a deleted item".
    expect(destinationOf('control', 'abc')).toBeNull();
    expect(destinationOf('risk', 'abc')).toBeNull();
    expect(destinationOf('policy', '../etc/passwd')).toBeNull();
    expect(destinationOf('policy', 'P01_BASIC')).toBeNull(); // Uppercase does not occur in natural keys
    expect(destinationOf('frame', '存在しない観点')).toBeNull();
    expect(destinationOf('framework', 'a b/c')).toBeNull();
    expect(destinationOf('role', '../org')).toBeNull();
  });

  it('未知の型・未知の分類は行き先を返さない', () => {
    expect(destinationOf('unknown', 'x')).toBeNull();
    expect(destinationOf('group', groupKey('未知の軸', ['x']))).toBeNull();
    expect(destinationOf('group', groupKey('section', ['存在しない区分']))).toBeNull();
    expect(destinationOf('group', groupKey('theme', ['IPO-KARTE']))).toBeNull(); // No level
  });
});
