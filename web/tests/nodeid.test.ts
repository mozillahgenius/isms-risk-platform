import { describe, expect, it } from 'vitest';
import {
  decodeNodeId,
  encodeNodeId,
  groupKey,
  parseGroupKey,
  GROUP_SEP,
  MAX_NODE_ID_LENGTH,
  UnencodableNodeKey,
} from '../src/lib/nodeid';

describe('ノード ID', () => {
  it('URL に入れて壊れる文字を含むキーでも往復する', () => {
    // 実データにそのまま在る形。' / '・全角括弧・空白が入る。
    const keys = [
      '運営基盤 / 機関設計 / 取締役会',
      '経理・税務（Phase1）',
      'a/b?c=d&e#f',
      'ISO27001:2022',
      '00000000-0000-0000-0000-000000002026',
    ];
    for (const k of keys) {
      const id = encodeNodeId('group', k);
      expect(id).toMatch(/^group\.[A-Za-z0-9_-]+$/); // パス区切りも query 記号も含まない
      expect(decodeNodeId(id)).toEqual({ type: 'group', key: k });
    }
  });

  it('区切りに使う制御文字が入っていても段が割れない', () => {
    const key = groupKey('theme', ['IPO-KARTE', '運営基盤 / 機関設計', '取締役会']);
    const back = parseGroupKey(key);
    expect(back.kind).toBe('theme');
    expect(back.path).toEqual(['IPO-KARTE', '運営基盤 / 機関設計', '取締役会']);
  });

  it('壊れた ID・未知の型・長すぎる ID を弾く', () => {
    expect(decodeNodeId('')).toBeNull();
    expect(decodeNodeId('control')).toBeNull(); // 区切りが無い
    expect(decodeNodeId('.abc')).toBeNull(); // 型が空
    expect(decodeNodeId('unknown.YWJj')).toBeNull(); // 許可していない型
    expect(decodeNodeId('control.あいう')).toBeNull(); // base64url の文字集合外
    expect(decodeNodeId('control.YWJj$')).toBeNull();
    expect(decodeNodeId(`control.${'A'.repeat(MAX_NODE_ID_LENGTH)}`)).toBeNull();
    expect(decodeNodeId('control.')).toBeNull(); // 中身が空
  });

  it('同じキーに複数の ID を許さない（正規形でない base64 は弾く）', () => {
    const id = encodeNodeId('control', 'a'); // 'YQ'
    expect(decodeNodeId(id)).toEqual({ type: 'control', key: 'a' });
    // 末尾ビットにゴミを載せた変種は、decode すると同じ 'a' になるが正規形ではない
    expect(decodeNodeId('control.YR')).toBeNull();
  });

  it('不正な UTF-8 は置換文字にせず弾く', () => {
    // 0xFF は単独では UTF-8 として成立しない
    expect(decodeNodeId('control._w')).toBeNull();
  });

  it('生成側も上限を守る（作れるのにクリックすると 404、を作らない）', () => {
    // 上限ちょうどまでは作れる。1 文字でも超えたら投げる。
    const maxKeyChars = Math.floor((MAX_NODE_ID_LENGTH - 'control.'.length) / 4) * 3;
    const ok = 'a'.repeat(maxKeyChars);
    expect(decodeNodeId(encodeNodeId('control', ok))).toEqual({ type: 'control', key: ok });
    expect(() => encodeNodeId('control', 'a'.repeat(maxKeyChars + 100))).toThrow(UnencodableNodeKey);
  });

  it('符号化できないキーは黙って通さない', () => {
    expect(() => encodeNodeId('control', '')).toThrow(UnencodableNodeKey);
    // 対になっていないサロゲート。TextEncoder は U+FFFD に潰すので、別のキーが同じ ID になる。
    expect(() => encodeNodeId('control', '\uD800')).toThrow(UnencodableNodeKey);
    expect(() => encodeNodeId('control', 'a\uDC00b')).toThrow(UnencodableNodeKey);
    // 対になっていれば通る（絵文字など）
    expect(decodeNodeId(encodeNodeId('control', '😀'))).toEqual({ type: 'control', key: '😀' });
  });

  it('分類の値に区切り文字が混ざったら落とす（別のまとまりが同じキーにならない）', () => {
    expect(() => groupKey('theme', [`a${GROUP_SEP}b`])).toThrow(UnencodableNodeKey);
    expect(() => groupKey(`the${GROUP_SEP}me`, ['a'])).toThrow(UnencodableNodeKey);
    // 区切りが無ければ、段の数が違えば別のキーになる
    expect(groupKey('theme', ['a', 'b'])).not.toBe(groupKey('theme', ['ab']));
  });
});
