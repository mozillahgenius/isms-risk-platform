// 規程の本文が「実際に書かれているか」の判定。
//
// DOM 2026.1 の規程 12 本は、いまのところ見出しと「（標準本文）」の一言しか入っていない。
// これを本文として並べると、規程がもう在るように見える。実測すると本文は 19〜39 文字しかない。
// 中身が無いことを画面が言えるようにするための判定をここに置く（画面ごとに書かない）。

const PLACEHOLDER_MARK = '（標準本文';

/** 本文が仮置き（見出しだけ）なら true。 */
export function isPlaceholderBody(body: string): boolean {
  const text = body ?? '';
  // 見出し行（# …）を除いた実質の本文。
  const lines = text
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && !l.startsWith('#'));
  const rest = lines.join('');
  if (rest.length === 0) return true;
  if (rest.startsWith(PLACEHOLDER_MARK)) return true;
  // 括弧書きの注記しか無い場合も仮置きとみなす。
  return lines.every((l) => /^[（(].*[）)]$/.test(l));
}
