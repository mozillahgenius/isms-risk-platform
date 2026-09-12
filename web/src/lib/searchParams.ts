// Normalize URL query parameters into the shape the screens expect.
//
// Next's searchParams become an **array** when the same name appears more than once (`?q=a&q=b`).
// Assuming a string means only that case fails with 500 due to `.trim is not a function`.
// It happens whenever a user writes the URL by hand, so always normalize at the entry point.

export type RawParam = string | string[] | undefined;

/** Take only the first one. If none, an empty string (same as "not specified"). */
export function firstParam(v: RawParam): string {
  if (Array.isArray(v)) return typeof v[0] === 'string' ? v[0] : '';
  return typeof v === 'string' ? v : '';
}

/** Page number. Non-numeric, 0 or less, or huge values fall back to 1. */
export function pageParam(v: RawParam): number {
  const n = Number.parseInt(firstParam(v), 10);
  if (!Number.isFinite(n) || n < 1) return 1;
  // The upper bound only needs to be well above any page count that could realistically exist.
  // Leaving it unbounded would let a huge value force computing the last page every time.
  return Math.min(n, 100_000);
}
