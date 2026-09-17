// URL のクエリを、画面が期待する形に均す。
//
// Next の searchParams は同じ名前が複数回来ると **配列** になる（`?q=a&q=b`）。
// 文字列だと決め打ちすると、その時だけ `.trim is not a function` で 500 になる。
// 利用者が手で URL を書けば起きるので、入口で必ず均す。

export type RawParam = string | string[] | undefined;

/** 最初の 1 つだけ採る。無ければ空文字（「指定なし」と同じ扱い）。 */
export function firstParam(v: RawParam): string {
  if (Array.isArray(v)) return typeof v[0] === 'string' ? v[0] : '';
  return typeof v === 'string' ? v : '';
}

/** ページ番号。数でない・0 以下・巨大な値は 1 に倒す。 */
export function pageParam(v: RawParam): number {
  const n = Number.parseInt(firstParam(v), 10);
  if (!Number.isFinite(n) || n < 1) return 1;
  // 上限は「実在しうるページ数」より十分大きければよい。
  // 無制限にすると、巨大な値で毎回末尾ページを計算させられる。
  return Math.min(n, 100_000);
}
