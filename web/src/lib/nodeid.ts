// Node IDs for the diagrams (graph, pyramid).
//
// Why not use the raw values directly:
//   Natural node keys contain ' / ', spaces, and full-width parentheses (e.g. a control theme
//   "Category / Subcategory / Item", a risk domain "Department (Phase1)" with full-width parentheses).
//   The diagram implementation just pushes `/n/<id>` on click, so a '/' in the ID
//   splits the path and jumps to a different route. So the ID side is fixed to a URL-safe form.
//
// Format: `<type>.<base64url(utf8(key))>`
//   - The base64url alphabet is only A-Z a-z 0-9 - _. It collides with neither path separators nor query syntax
//   - Reversible. The resolver can recover the original natural key (no separate lookup table needed)
//   - Types come from a fixed allowlist. Unknown types are rejected by decode

export const NODE_TYPES = [
  'dom', // The DOM edition itself
  'framework', // catalog.frameworks.key
  'control', // catalog.controls.id (uuid)
  'risk', // catalog.risk_scenario_templates.id (uuid)
  'policy', // catalog.policies_default.key
  'role', // catalog.roles_default.key
  'asset', // catalog.asset_classes_default.key
  'calendar', // catalog.calendar_events_default.key
  'frame', // Risk perspective (manageability / accuracy / speed)
  'group', // Intermediate node derived from a classification (not a DB row)
] as const;

export type NodeType = (typeof NODE_TYPES)[number];

// Maximum length of the whole ID. A gate so overly long input doesn't hit the router or DB.
//
// Measured (DOM 2026.1, 2026-08-13): the longest key is 231 bytes, in the risk measure group.
// base64url inflates 3 bytes -> 4 characters, so the ID is about 314 characters. 1024 accommodates keys up to about 760 bytes
// and still fits within the practical URL limit (roughly 2000 characters).
// **The generating side (encodeNodeId) also enforces this limit.** Applying it on only one side
// produces "nodes that can be created but return 404 when clicked".
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
  return out; // No '=' padding (because it goes into URLs)
}

function base64UrlToBytes(s: string): Uint8Array | null {
  const n = s.length;
  // base64 encodes 3 bytes per 4 characters. A remainder of 1 character is not valid base64.
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

/** Thrown when a key is found to be unencodable. A guard against silently producing broken IDs. */
export class UnencodableNodeKey extends Error {
  constructor(reason: string) {
    super(`ノード ID を作れません: ${reason}`);
    this.name = 'UnencodableNodeKey';
  }
}

// An unpaired surrogate. TextEncoder replaces it with U+FFFD,
// so different keys become the same bytes = the same ID, breaking link identity.
// It doesn't appear in values coming from PostgreSQL text, but we reject it explicitly as part of the generator's contract.
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

export function encodeNodeId(type: NodeType, key: string): string {
  if (key.length === 0) throw new UnencodableNodeKey('キーが空です');
  if (LONE_SURROGATE.test(key)) throw new UnencodableNodeKey('対になっていないサロゲートを含みます');
  const id = `${type}.${bytesToBase64Url(new TextEncoder().encode(key))}`;
  // If the limits differ between generator and decoder, you get "nodes that can be created but return 404 when clicked".
  // Over the limit, fail here instead of silently not creating it (so we notice the data is longer than expected).
  if (id.length > MAX_NODE_ID_LENGTH) {
    throw new UnencodableNodeKey(`ID が上限 ${MAX_NODE_ID_LENGTH} 文字を超えます（${id.length} 文字）`);
  }
  return id;
}

export type DecodedNodeId = { type: NodeType; key: string };

/** Invalid, unknown, or corrupt IDs return null. Callers translate this into a 404. */
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
    // Reject invalid UTF-8 instead of substituting replacement characters (it would pass as a different key).
    key = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
  if (key.length === 0) return null;
  // Reject non-canonical base64 (e.g. garbage in the trailing bits).
  // If multiple IDs exist for the same key, link identity breaks.
  //
  // encodeNodeId throws on unencodable keys. By this point length and UTF-8 have
  // already been checked, so it normally won't throw, but decoding is the entry point for user input, so
  // even if it throws, don't return 500; fall back to null as an "unreadable ID".
  try {
    if (encodeNodeId(type as NodeType, key) !== id) return null;
  } catch {
    return null;
  }
  return { type: type as NodeType, key };
}

// Note that decodeNodeId does not check the per-type shape of the key (whether it's a uuid, the literal form of a natural key, etc.).
// That is the job of the side that decides the destination (lib/nodeDestination.ts); the two-stage design is intentional.
// "Can it be read as an ID?" and "Is the target in a shape that could exist?" are separate judgments;
// the former is checked here, the latter when deciding the destination. Failing either results in a 404.

/**
 * Key for a derived intermediate node (not a DB row).
 * kind is the classification axis, path is the position within that axis. The joiner is U+001F (Unit Separator).
 * Theme paths contain ' / ' and spaces,
 * so using a visible character as the separator would split a theme like "Operations base / Governance design" in the middle into a different node.
 * A control character never appears in real data.
 */
export const GROUP_SEP = '\u001F';

export function groupKey(kind: string, path: string[]): string {
  const parts = [kind, ...path];
  // If a component contains the separator, re-splitting shifts the levels and produces a different grouping
  // (groupKey('a', ['b\u001Fc']) and groupKey('a', ['b','c']) would produce the same key).
  // Don't swallow it via escaping; fail it as an anomaly on the input side.
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
