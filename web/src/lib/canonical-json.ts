import 'server-only';

function sortedValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortedValue);
  if (value !== null && typeof value === 'object') {
    const object = value as Record<string, unknown>;
    return Object.fromEntries(
      Object.keys(object).sort().map((key) => [key, sortedValue(object[key])]),
    );
  }
  return value;
}

export function canonicalJson(value: unknown): Buffer {
  return Buffer.from(JSON.stringify(sortedValue(value)));
}
