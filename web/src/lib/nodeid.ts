// 図（グラフ・ピラミッド）のノード ID。
//
// なぜ素の値をそのまま使わないか:
//   ノードの自然キーには ' / ' やスペース、全角括弧が入る（例: 統制の theme
//   「運営基盤 / 機関設計 / 取締役会」、リスクの domain「経理・税務（Phase1）」）。
//   図の実装はクリック時に `/n/<id>` へ push するだけなので、ID に '/' が入ると
//   パスが割れて別のルートに飛ぶ。だから ID の側を URL 安全な形に固定する。
//
// 形式: `<type>.<base64url(utf8(key))>`
//   - base64url の文字集合は A-Z a-z 0-9 - _ のみ。パス区切りにも query にもぶつからない
//   - 可逆。resolver 側で元の自然キーへ戻せる（別表を持たなくてよい）
//   - 型は固定の許可リスト。未知の型は decode で弾く

export const NODE_TYPES = [
  'dom', // DOM 版そのもの
  'framework', // catalog.frameworks.key
  'control', // catalog.controls.id (uuid)
  'risk', // catalog.risk_scenario_templates.id (uuid)
  'policy', // catalog.policies_default.key
  'role', // catalog.roles_default.key
  'asset', // catalog.asset_classes_default.key
  'calendar', // catalog.calendar_events_default.key
  'frame', // リスクの観点（管理可能性 / 精度 / スピード）
  'group', // 分類から導出した中間ノード（DB の行ではない）
] as const;

export type NodeType = (typeof NODE_TYPES)[number];

// ID 全体の長さ上限。長すぎる入力でルータや DB を叩かないための門。
//
// 実測（2026-08-13 の DOM 2026.1）での最長キーは、リスクの measure 群で 231 バイト。
// base64url は 3 バイト → 4 文字に膨らむので ID は約 314 文字。1024 なら約 760 バイトの
// キーまで入り、URL の実用上限（おおむね 2000 文字）にも収まる。
// **生成側（encodeNodeId）もこの上限を守る。** 片側だけに掛けると、
// 「作れるがクリックすると 404 になるノード」ができる。
export const MAX_NODE_ID_LENGTH = 1024;

const B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

function bytesToBase64Url(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i];
    const b1 = bytes[i + 1];
    const b2 = bytes[i + 2];
    out += B64_CHARS[b0 >> 2];
    out += B64_CHARS[((b0 & 0x03) << 4) | ((b1 ?? 0) >> 4)];
    if (b1 === undefined) break;
    out += B64_CHARS[((b1 & 0x0f) << 2) | ((b2 ?? 0) >> 6)];
    if (b2 === undefined) break;
    out += B64_CHARS[b2 & 0x3f];
  }
  return out; // パディング '=' は付けない（URL に入れないため）
}

function base64UrlToBytes(s: string): Uint8Array | null {
  const n = s.length;
  // base64 は 4 文字で 3 バイト。余り 1 文字は base64 として成立しない。
  if (n % 4 === 1) return null;
  const bytes: number[] = [];
  let acc = 0;
  let bits = 0;
  for (let i = 0; i < n; i++) {
    const v = B64_CHARS.indexOf(s[i]);
    if (v < 0) return null;
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes.push((acc >> bits) & 0xff);
    }
  }
  return Uint8Array.from(bytes);
}

/** 符号化できないキーだと分かったときに投げる。黙って壊れた ID を作らないための番人。 */
export class UnencodableNodeKey extends Error {
  constructor(reason: string) {
    super(`ノード ID を作れません: ${reason}`);
    this.name = 'UnencodableNodeKey';
  }
}

// 対になっていないサロゲート。TextEncoder はこれを U+FFFD に置き換えるため、
// 別々のキーが同じバイト列＝同じ ID になり、リンクの同一性が崩れる。
// PostgreSQL の text から来る値には現れないが、生成側の契約として明示的に弾く。
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

export function encodeNodeId(type: NodeType, key: string): string {
  if (key.length === 0) throw new UnencodableNodeKey('キーが空です');
  if (LONE_SURROGATE.test(key)) throw new UnencodableNodeKey('対になっていないサロゲートを含みます');
  const id = `${type}.${bytesToBase64Url(new TextEncoder().encode(key))}`;
  // 生成側と復号側で上限が食い違うと、「作れるがクリックすると 404 になるノード」ができる。
  // 上限を超えたら黙って作らず、ここで落とす（データが想定より長いことに気づけるように）。
  if (id.length > MAX_NODE_ID_LENGTH) {
    throw new UnencodableNodeKey(`ID が上限 ${MAX_NODE_ID_LENGTH} 文字を超えます（${id.length} 文字）`);
  }
  return id;
}

export type DecodedNodeId = { type: NodeType; key: string };

/** 不正・未知・壊れた ID は null。呼び出し側はこれを 404 に翻訳する。 */
export function decodeNodeId(id: string): DecodedNodeId | null {
  if (typeof id !== 'string' || id.length === 0 || id.length > MAX_NODE_ID_LENGTH) return null;
  const dot = id.indexOf('.');
  if (dot <= 0) return null;
  const type = id.slice(0, dot);
  if (!(NODE_TYPES as readonly string[]).includes(type)) return null;
  const bytes = base64UrlToBytes(id.slice(dot + 1));
  if (!bytes) return null;
  let key: string;
  try {
    // 不正な UTF-8 は置換文字にせず落とす（別のキーとして通ってしまうため）。
    key = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
  if (key.length === 0) return null;
  // 正規形でない base64（末尾ビットにゴミがある等）を弾く。
  // 同じキーに複数の ID が存在すると、リンクの同一性が崩れる。
  //
  // encodeNodeId は符号化できないキーで例外を投げる。ここへ来る時点で長さも UTF-8 も
  // 検査済みなので通常は投げないが、復号は利用者の入力を受ける入口なので、
  // 投げられても 500 にせず「読めない ID」として null に倒す。
  try {
    if (encodeNodeId(type as NodeType, key) !== id) return null;
  } catch {
    return null;
  }
  return { type: type as NodeType, key };
}

// なお、decodeNodeId は型ごとのキーの形までは見ない（uuid か、自然キーの字面か等）。
// それは行き先を決める側（lib/nodeDestination.ts）の仕事で、意図的に二段構えにしている。
// 「ID として読めるか」と「その対象が存在しうる形か」は別の判断で、
// 前者をここで、後者を遷移先の決定時に見る。どちらで落ちても 404 になる。

/**
 * 導出した中間ノード（DB の行ではない）のキー。
 * kind は分類の軸、path はその軸の中での位置。継ぎ目は U+001F（Unit Separator）。
 * theme パスには ' / ' も空白も入るため、
 * 見える文字を区切りにすると「運営基盤 / 機関設計」の途中で割れて別ノードになる。
 * 制御文字なら実データに現れない。
 */
export const GROUP_SEP = '\u001F';

export function groupKey(kind: string, path: string[]): string {
  const parts = [kind, ...path];
  // 構成要素が区切り文字を含んでいると、割り直したときに段がずれて別のまとまりになる
  // （groupKey('a', ['b\u001Fc']) と groupKey('a', ['b','c']) が同じキーになる）。
  // エスケープで飲み込まず、投入側の異常として落とす。
  for (const part of parts) {
    if (part.includes(GROUP_SEP)) {
      throw new UnencodableNodeKey('分類の値に区切り文字（U+001F）が含まれています');
    }
  }
  return parts.join(GROUP_SEP);
}

export function parseGroupKey(key: string): { kind: string; path: string[] } {
  const parts = key.split('\u001F');
  return { kind: parts[0], path: parts.slice(1) };
}
