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
    // The shape as it appears in real data. Contains ' / ', full-width parentheses, and spaces.
    const keys = [
      'サンプル大項目 / サンプル中項目 / サンプル小項目',
      'サンプル部門A（Phase1）',
      'a/b?c=d&e#f',
      'ISO27001:2022',
      '00000000-0000-0000-0000-000000002026',
    ];
    for (const k of keys) {
      const id = encodeNodeId('group', k);
      expect(id).toMatch(/^group\.[A-Za-z0-9_-]+$/); // Contains neither path separators nor query characters
      expect(decodeNodeId(id)).toEqual({ type: 'group', key: k });
    }
  });

  it('区切りに使う制御文字が入っていても段が割れない', () => {
    const key = groupKey('theme', ['IPO-KARTE', 'サンプル大項目 / サンプル中項目', 'サンプル小項目']);
    const back = parseGroupKey(key);
    expect(back.kind).toBe('theme');
    expect(back.path).toEqual(['IPO-KARTE', 'サンプル大項目 / サンプル中項目', 'サンプル小項目']);
  });

  it('壊れた ID・未知の型・長すぎる ID を弾く', () => {
    expect(decodeNodeId('')).toBeNull();
    expect(decodeNodeId('control')).toBeNull(); // No separator
    expect(decodeNodeId('.abc')).toBeNull(); // Empty type
    expect(decodeNodeId('unknown.YWJj')).toBeNull(); // Type not in the allowlist
    expect(decodeNodeId('control.あいう')).toBeNull(); // Outside the base64url alphabet
    expect(decodeNodeId('control.YWJj$')).toBeNull();
    expect(decodeNodeId(`control.${'A'.repeat(MAX_NODE_ID_LENGTH)}`)).toBeNull();
    expect(decodeNodeId('control.')).toBeNull(); // Empty payload
  });

  it('同じキーに複数の ID を許さない（正規形でない base64 は弾く）', () => {
    const id = encodeNodeId('control', 'a'); // 'YQ'
    expect(decodeNodeId(id)).toEqual({ type: 'control', key: 'a' });
    // A variant with garbage in the trailing bits decodes to the same 'a' but is not canonical
    expect(decodeNodeId('control.YR')).toBeNull();
  });

  it('不正な UTF-8 は置換文字にせず弾く', () => {
    // 0xFF on its own is not valid UTF-8
    expect(decodeNodeId('control._w')).toBeNull();
  });

  it('生成側も上限を守る（作れるのにクリックすると 404、を作らない）', () => {
    // Can be created right up to the limit. Throws if it exceeds it by even 1 character.
    const maxKeyChars = Math.floor((MAX_NODE_ID_LENGTH - 'control.'.length) / 4) * 3;
    const ok = 'a'.repeat(maxKeyChars);
    expect(decodeNodeId(encodeNodeId('control', ok))).toEqual({ type: 'control', key: ok });
    expect(() => encodeNodeId('control', 'a'.repeat(maxKeyChars + 100))).toThrow(UnencodableNodeKey);
  });

  it('符号化できないキーは黙って通さない', () => {
    expect(() => encodeNodeId('control', '')).toThrow(UnencodableNodeKey);
    // An unpaired surrogate. TextEncoder collapses it to U+FFFD, so different keys become the same ID.
    expect(() => encodeNodeId('control', '\uD800')).toThrow(UnencodableNodeKey);
    expect(() => encodeNodeId('control', 'a\uDC00b')).toThrow(UnencodableNodeKey);
    // Passes if properly paired (emoji, etc.)
    expect(decodeNodeId(encodeNodeId('control', '😀'))).toEqual({ type: 'control', key: '😀' });
  });

  it('分類の値に区切り文字が混ざったら落とす（別のまとまりが同じキーにならない）', () => {
    expect(() => groupKey('theme', [`a${GROUP_SEP}b`])).toThrow(UnencodableNodeKey);
    expect(() => groupKey(`the${GROUP_SEP}me`, ['a'])).toThrow(UnencodableNodeKey);
    // With no separator, a different number of levels yields a different key
    expect(groupKey('theme', ['a', 'b'])).not.toBe(groupKey('theme', ['ab']));
  });
});
