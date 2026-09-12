// Determines whether a policy body is "actually written".
//
// The 12 policies in DOM 2026.1 currently contain only a heading and the single phrase "(standard body)".
// Listing these as bodies makes it look as if the policies already exist. Measured, the bodies are only 19-39 characters.
// This decision lives here so screens can say there is no content (do not write it per screen).

const PLACEHOLDER_MARK = '（標準本文';

/** true if the body is a placeholder (heading only). */
export function isPlaceholderBody(body: string): boolean {
  const text = body ?? '';
  // The substantive body excluding heading lines (# ...).
  const lines = text
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && !l.startsWith('#'));
  const rest = lines.join('');
  if (rest.length === 0) return true;
  if (rest.startsWith(PLACEHOLDER_MARK)) return true;
  // Also treat it as a placeholder if it contains only parenthetical notes.
  return lines.every((l) => /^[（(].*[）)]$/.test(l));
}
