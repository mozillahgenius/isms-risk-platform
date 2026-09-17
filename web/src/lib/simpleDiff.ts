// 行単位の簡易差分。新規に diff ライブラリを入れない方針のため自前で持つ。
// LCS ベースで「変わっていない行」を最大化し、追加・削除だけを出す
// （並べ替えは検出しない。規程本文の版比較にはそれで十分）。

export type DiffLine = { kind: 'same' | 'added' | 'removed'; text: string };

export function lineDiff(before: string, after: string): DiffLine[] {
  const a = (before ?? '').split('\n');
  const b = (after ?? '').split('\n');
  const n = a.length;
  const m = b.length;
  // lcs[i][j] = a[i..] と b[j..] の最長共通部分列の長さ
  const lcs: number[][] = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  const out: DiffLine[] = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      out.push({ kind: 'same', text: a[i] });
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.push({ kind: 'removed', text: a[i] });
      i++;
    } else {
      out.push({ kind: 'added', text: b[j] });
      j++;
    }
  }
  while (i < n) {
    out.push({ kind: 'removed', text: a[i] });
    i++;
  }
  while (j < m) {
    out.push({ kind: 'added', text: b[j] });
    j++;
  }
  return out;
}

export function diffStats(lines: DiffLine[]): { added: number; removed: number } {
  return lines.reduce(
    (acc, l) => {
      if (l.kind === 'added') acc.added++;
      if (l.kind === 'removed') acc.removed++;
      return acc;
    },
    { added: 0, removed: 0 },
  );
}
